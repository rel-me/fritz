use anyhow::{Context, Result, bail, ensure};
use fritz_provider::{ProviderApi, chat_completions_payload, chat_endpoint, responses_payload};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{ffi::c_void, slice, time::Duration};

const SYSTEM: &str = "You are Fritz, a personal assistant in a native iPhone app. Help the user answer questions, think through everyday tasks, organize ideas, and draft text. Be clear and accurate. You have no access to personal data beyond what the user shares in this conversation. No tools are available.";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    api: ProviderApi,
    base_url: String,
    #[serde(flatten)]
    operation: Operation,
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase")]
enum Operation {
    Discover,
    Chat {
        model: String,
        messages: Vec<Message>,
    },
}

#[derive(Deserialize, Serialize)]
struct Message {
    role: Role,
    content: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Role {
    User,
    Assistant,
}

type Emit = extern "C" fn(*mut c_void, *const u8, usize);
type Cancelled = extern "C" fn(*mut c_void) -> bool;

async fn run(request: Request, key: Option<&str>, emit: impl Fn(Value)) -> Result<()> {
    let url = Url::parse(&request.base_url).context("Enter a valid endpoint URL.")?;
    let simulator_loopback = cfg!(target_abi = "sim")
        && url.scheme() == "http"
        && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
        && key.is_none();
    ensure!(
        (url.scheme() == "https" || simulator_loopback)
            && url.host().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        "Use an HTTPS endpoint without credentials, a query, or a fragment."
    );
    ensure!(
        matches!(request.api, ProviderApi::Openai | ProviderApi::Compatible),
        "Unsupported iPhone provider."
    );
    if request.api == ProviderApi::Openai && key.is_none() {
        bail!("Enter an OpenAI API key in Providers.");
    }
    let base_url = url.as_str().trim_end_matches('/');
    match request.operation {
        Operation::Discover => {
            let models = fritz_provider::discover(request.api, base_url, key).await?;
            emit(json!({"type":"models","models":models}));
        }
        Operation::Chat { model, messages } => {
            ensure!(!model.trim().is_empty(), "Choose a model before sending.");
            ensure!(
                !messages.is_empty()
                    && messages.len() <= 1000
                    && messages.iter().map(|m| m.content.len()).sum::<usize>() <= 2_000_000,
                "This conversation is too large. Start a new chat."
            );
            let messages = messages
                .iter()
                .map(serde_json::to_value)
                .collect::<serde_json::Result<Vec<_>>>()?;
            let (suffix, body) = if request.api == ProviderApi::Openai {
                ("responses", responses_payload(&model, SYSTEM, messages))
            } else {
                (
                    "chat/completions",
                    chat_completions_payload(&model, SYSTEM, &messages),
                )
            };
            let url = chat_endpoint(request.api, base_url, &model, suffix)?;
            fritz_provider::stream_body(request.api, url, key, &body, emit, |_| Ok(())).await?;
        }
    }
    Ok(())
}

/// Run one request synchronously. Returning releases every borrowed pointer.
///
/// # Safety
/// All nonempty buffers must be valid for reads for the duration of this call.
/// The caller must keep the context and callbacks valid until the call returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fritz_ios_request(
    input: *const u8,
    input_len: usize,
    key: *const u8,
    key_len: usize,
    context: *mut c_void,
    on_event: Emit,
    is_cancelled: Cancelled,
) {
    let emit = |event: Value| {
        if !is_cancelled(context) {
            let bytes = event.to_string();
            on_event(context, bytes.as_ptr(), bytes.len());
        }
    };
    let result = (|| {
        ensure!(
            !input.is_null() && input_len != 0,
            "Provider request is empty."
        );
        let input = unsafe { slice::from_raw_parts(input, input_len) };
        let request =
            serde_json::from_slice(input).context("Could not encode the provider request.")?;
        let key = if key_len == 0 {
            None
        } else {
            Some(std::str::from_utf8(unsafe {
                slice::from_raw_parts(key, key_len)
            })?)
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        runtime.block_on(async {
            let mut poll = tokio::time::interval(Duration::from_millis(50));
            tokio::select! {
                biased;
                _ = async { while !is_cancelled(context) { poll.tick().await; } } => Ok(()),
                result = run(request, key, emit) => result,
            }
        })
    })();
    if let Err(error) = result {
        // Network and decoding errors can include URL paths or response fragments.
        let message = if error.downcast_ref::<reqwest::Error>().is_some() {
            "Could not complete the provider request. Check the endpoint and connection.".into()
        } else {
            error.to_string()
        };
        emit(json!({"type":"error","message":message}));
    }
}
