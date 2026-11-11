//! Serialized ownership and cancellation for the bundled llama.cpp C++ boundary.
use anyhow::{Context, Result, bail};
use serde_json::Value;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    path::Path,
    ptr::NonNull,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::sync::mpsc;

#[cfg(test)]
pub(crate) const REVISION: &str = "7c2653acc749258dc62067da62d07024d971ccd2";

unsafe extern "C" {
    fn fl_model_load(
        path: *const c_char,
        context: i32,
        chat: bool,
        cancel: extern "C" fn(*mut c_void) -> bool,
        data: *mut c_void,
        error: *mut *mut c_char,
    ) -> *mut c_void;
    fn fl_model_free(model: *mut c_void);
    fn fl_string_free(value: *mut c_char);
    fn fl_tokenize(model: *mut c_void, text: *const c_char, special: bool) -> *mut c_char;
    fn fl_logits(
        model: *mut c_void,
        ids: *const u32,
        n: usize,
        first: u32,
        count: usize,
        cancel: extern "C" fn(*mut c_void) -> bool,
        data: *mut c_void,
    ) -> *mut c_char;
    fn fl_chat(
        model: *mut c_void,
        request: *const c_char,
        cancel: extern "C" fn(*mut c_void) -> bool,
        data: *mut c_void,
        emit: extern "C" fn(*mut c_void, *const c_char) -> bool,
        output: *mut c_void,
    ) -> *mut c_char;
}
struct Handle(NonNull<c_void>);
// A handle moves between workers only while protected by Model's mutex.
// Native operations and destruction never run concurrently for one handle.
unsafe impl Send for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { fl_model_free(self.0.as_ptr()) }
    }
}
pub(crate) struct Model {
    inner: Mutex<Handle>,
}

struct Cancellation(Arc<AtomicBool>);
impl Drop for Cancellation {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
extern "C" fn cancelled(data: *mut c_void) -> bool {
    // Native code borrows the flag only for the duration of its synchronous call.
    unsafe { (&*data.cast::<AtomicBool>()).load(Ordering::Acquire) }
}
fn flag_pointer(flag: &AtomicBool) -> *mut c_void {
    (flag as *const AtomicBool).cast_mut().cast()
}
fn text(value: *mut c_char) -> Result<String> {
    if value.is_null() {
        bail!("The local runtime returned no response.");
    }
    let result = unsafe { CStr::from_ptr(value) }.to_str().map(str::to_owned);
    unsafe { fl_string_free(value) };
    result.context("The local runtime returned invalid UTF-8")
}
fn response(value: *mut c_char) -> Result<Value> {
    let value: Value =
        serde_json::from_str(&text(value)?).context("Invalid local runtime response")?;
    if let Some(error) = value["error"].as_str() {
        bail!("{error}");
    }
    Ok(value)
}
async fn worker<T: Send + 'static>(
    action: impl FnOnce(&AtomicBool) -> Result<T> + Send + 'static,
) -> Result<T> {
    let cancellation = Cancellation(Arc::new(AtomicBool::new(false)));
    let flag = cancellation.0.clone();
    let result = tokio::task::spawn_blocking(move || action(&flag))
        .await
        .context("The local inference worker failed")?;
    drop(cancellation);
    result
}
enum Message {
    Event(Value),
    Done(Result<Value>),
}
extern "C" fn event(data: *mut c_void, payload: *const c_char) -> bool {
    std::panic::catch_unwind(|| {
        let output = unsafe { &*data.cast::<mpsc::UnboundedSender<Message>>() };
        let bytes = unsafe { CStr::from_ptr(payload) }.to_bytes();
        serde_json::from_slice(bytes).is_ok_and(|value| output.send(Message::Event(value)).is_ok())
    })
    .unwrap_or(false)
}
impl Model {
    pub(crate) async fn load(path: &Path, context: usize, chat: bool) -> Result<Arc<Self>> {
        let path = CString::new(path.as_os_str().as_encoded_bytes())?;
        let context = i32::try_from(context).context("Invalid local context size")?;
        anyhow::ensure!(context > 0, "Invalid local context size");
        worker(move |flag| {
            let mut error = std::ptr::null_mut();
            let value = unsafe {
                fl_model_load(
                    path.as_ptr(),
                    context,
                    chat,
                    cancelled,
                    flag_pointer(flag),
                    &mut error,
                )
            };
            let Some(value) = NonNull::new(value) else {
                bail!(
                    "{}",
                    text(error).unwrap_or_else(|_| "Local model loading failed".into())
                );
            };
            Ok(Arc::new(Self {
                inner: Mutex::new(Handle(value)),
            }))
        })
        .await
    }
    pub(crate) async fn tokenize(
        self: &Arc<Self>,
        input: String,
        special: bool,
    ) -> Result<Vec<u32>> {
        let model = self.clone();
        let input = CString::new(input)?;
        worker(move |flag| {
            let handle = model
                .inner
                .lock()
                .map_err(|_| anyhow::anyhow!("Local model lock failed"))?;
            if flag.load(Ordering::Acquire) {
                bail!("Local inference cancelled");
            }
            let result =
                response(unsafe { fl_tokenize(handle.0.as_ptr(), input.as_ptr(), special) })?;
            Ok(serde_json::from_value(result["tokens"].clone())?)
        })
        .await
    }
    pub(crate) async fn logits(
        self: &Arc<Self>,
        tokens: Vec<u32>,
        first: u32,
        count: usize,
    ) -> Result<Vec<f32>> {
        let model = self.clone();
        worker(move |flag| {
            let handle = model
                .inner
                .lock()
                .map_err(|_| anyhow::anyhow!("Local model lock failed"))?;
            let result = response(unsafe {
                fl_logits(
                    handle.0.as_ptr(),
                    tokens.as_ptr(),
                    tokens.len(),
                    first,
                    count,
                    cancelled,
                    flag_pointer(flag),
                )
            })?;
            Ok(serde_json::from_value(result["logits"].clone())?)
        })
        .await
    }
    pub(crate) async fn chat(
        self: &Arc<Self>,
        request: Value,
        emit: &(impl Fn(Value) + Sync),
    ) -> Result<Value> {
        let cancellation = Cancellation(Arc::new(AtomicBool::new(false)));
        let flag = cancellation.0.clone();
        let model = self.clone();
        let input = CString::new(serde_json::to_vec(&request)?)?;
        let (output, mut events) = mpsc::unbounded_channel();
        tokio::task::spawn_blocking(move || {
            let result = (|| {
                let handle = model
                    .inner
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Local model lock failed"))?;
                response(unsafe {
                    fl_chat(
                        handle.0.as_ptr(),
                        input.as_ptr(),
                        cancelled,
                        flag_pointer(&flag),
                        event,
                        (&output as *const mpsc::UnboundedSender<Message>)
                            .cast_mut()
                            .cast(),
                    )
                })
            })();
            let _ = output.send(Message::Done(result));
        });
        while let Some(message) = events.recv().await {
            match message {
                Message::Event(value) => emit(value),
                Message::Done(result) => return result,
            }
        }
        bail!("The local inference worker disconnected")
    }
}
