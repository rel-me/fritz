//! The app service owns credentials; each chat owns one isolated harness process.
//! Closing its private stdin cancels the run and tears down command process groups.
mod memory;

use crate::{
    config, harness,
    provider::{self, ChatRequest},
};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::os::fd::{AsRawFd, FromRawFd};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWriteExt, BufReader};

/// Nonblocking private stdin for supervised harnesses and the local model service.
pub struct PrivateStdin(tokio::io::unix::AsyncFd<std::fs::File>);

impl PrivateStdin {
    pub fn new() -> Result<Self> {
        // SAFETY: fd 0 is valid and exclusively owned by this supervised process.
        let stdin = unsafe { std::fs::File::from_raw_fd(0) };
        // SAFETY: F_GETFL/F_SETFL operate on the owned fd and retain no pointers.
        let flags = unsafe { libc::fcntl(stdin.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(stdin.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        // SAFETY: AsyncFd owns the File and its descriptor for the registration lifetime.
        Ok(Self(unsafe { tokio::io::unix::AsyncFd::register(stdin) }?))
    }
}

impl AsyncRead for PrivateStdin {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        loop {
            let mut guard = std::task::ready!(self.0.poll_read_ready(cx))?;
            match guard.try_io(|inner| {
                let mut fd = inner.get_ref();
                std::io::Read::read(&mut fd, buf.initialize_unfilled())
            }) {
                Ok(Ok(n)) => {
                    buf.advance(n);
                    return std::task::Poll::Ready(Ok(()));
                }
                Ok(Err(e)) => return std::task::Poll::Ready(Err(e)),
                Err(_) => continue,
            }
        }
    }
}

pub async fn read_line(
    reader: &mut (impl AsyncBufRead + Unpin),
    limit: usize,
) -> Result<Option<String>> {
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if line.is_empty() {
                Ok(None)
            } else {
                bail!("Protocol ended in an incomplete line.")
            };
        }
        let n = available
            .iter()
            .position(|b| *b == b'\n')
            .map_or(available.len(), |i| i + 1);
        if line.len() + n > limit {
            bail!("Protocol line exceeded its size limit.");
        }
        let done = available[n - 1] == b'\n';
        line.extend_from_slice(&available[..n]);
        reader.consume(n);
        if done {
            return Ok(Some(String::from_utf8(line)?));
        }
    }
}

pub async fn chat(request: ChatRequest, emit: impl Fn(Value)) -> Result<()> {
    chat_with_context(request, None, emit).await
}

#[doc(hidden)]
pub async fn chat_with_context(
    request: ChatRequest,
    context: Option<harness::ContextSettings>,
    emit: impl Fn(Value),
) -> Result<()> {
    let connection = config::find(Some(&request.connection_id))?;
    if connection.provider.category() != config::ModelCategory::Llm {
        bail!("Choose an LLM provider for chat.");
    }
    let api_key = if connection.provider.is_native() {
        None
    } else {
        provider::credential(&connection, None)?
    };
    let input = harness::Input {
        request,
        connection,
        api_key,
    };
    let executable = std::env::current_exe()?
        .parent()
        .context("Missing executable directory")?
        .join("fritz-harness");
    chat_process(&executable, harness::ContextInput { input, context }, emit).await
}

/// Runs a host-selected harness with explicit input over private pipes.
/// Dropping the future closes stdin and lets the child tear down its command groups.
pub async fn chat_with_input(
    executable: &std::path::Path,
    input: harness::Input,
    emit: impl Fn(Value),
) -> Result<()> {
    chat_process(
        executable,
        harness::ContextInput {
            input,
            context: None,
        },
        emit,
    )
    .await
}

async fn chat_process(
    executable: &std::path::Path,
    input: harness::ContextInput,
    emit: impl Fn(Value),
) -> Result<()> {
    let initial = if input.input.connection.provider == config::ProviderKind::Fritz {
        let sample = memory::Sample::read()?;
        sample.ensure_start()?;
        Some(sample)
    } else {
        None
    };
    // Budgeted local chats emit their actual context once the model is ready.
    let starting = AtomicBool::new(initial.is_some() && input.context.is_some());
    supervise_harness(
        executable,
        input,
        |event| {
            if event["type"] == "activity" && event["contextTokens"].is_u64() {
                starting.store(false, Ordering::Relaxed);
            }
            emit(event);
        },
        memory::Sample::watch(initial, &starting),
    )
    .await
}

async fn supervise_harness(
    executable: &std::path::Path,
    input: harness::ContextInput,
    emit: impl Fn(Value),
    memory_alarm: impl Future<Output = anyhow::Error>,
) -> Result<()> {
    let mut child = tokio::process::Command::new(executable)
        .arg("chat")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("Could not start fritz-harness. Build both binaries with make build.")?;
    // Do not SIGKILL the harness on drop: EOF gives it a chance to drop/kill
    // command groups. A reaper task owns the child through cancellation.
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (memory_stop, stop_requested) = tokio::sync::oneshot::channel();
    let reaper = tokio::spawn(async move {
        tokio::select! {
            status = child.wait() => status,
            Ok(()) = stop_requested => {
                // EOF lets the harness cancel inference and tear down any tools.
                // Force release if the native worker is still holding model memory.
                match tokio::time::timeout(std::time::Duration::from_secs(3), child.wait()).await {
                    Ok(status) => status,
                    Err(_) => {
                        child.kill().await?;
                        child.wait().await
                    }
                }
            }
        }
    });
    // Retain stdin for the entire run. Its drop signals Stop, service exit, or error.
    let exchange = async {
        let mut bytes = serde_json::to_vec(&input)?;
        bytes.push(b'\n');
        stdin.write_all(&bytes).await?;
        stdin.flush().await?;
        read_events(BufReader::new(stdout), emit).await
    };
    let (terminal, memory_error) = tokio::select! {
        biased;
        error = memory_alarm => (None, Some(error)),
        terminal = exchange => (terminal?, None),
    };
    drop(stdin);
    if let Some(error) = memory_error {
        let _ = memory_stop.send(());
        reaper.await??;
        return Err(error);
    }
    let status = reaper.await??;
    if !status.success() && terminal.as_ref().is_none_or(|result| result.is_ok()) {
        bail!("fritz-harness exited unexpectedly.");
    }
    terminal.unwrap_or_else(|| {
        Err(anyhow::anyhow!(
            "The harness disconnected before completing the response."
        ))
    })
}

async fn read_events(
    mut reader: impl AsyncBufRead + Unpin,
    emit: impl Fn(Value),
) -> Result<Option<Result<()>>> {
    let mut terminal = None;
    while let Some(line) = read_line(&mut reader, 1_000_000).await? {
        let event: Value = serde_json::from_str(&line).context("Invalid harness event.")?;
        match event["type"].as_str() {
            Some("result") => {
                terminal = Some(Ok(()));
                break;
            }
            Some("error") => {
                terminal = Some(Err(anyhow::anyhow!(
                    event["message"]
                        .as_str()
                        .unwrap_or("The harness failed.")
                        .to_owned()
                )));
                break;
            }
            Some("cancelled") => {
                terminal = Some(Err(anyhow::anyhow!("The run was cancelled.")));
                break;
            }
            Some(
                "delta" | "usage" | "activity" | "model_loading" | "tool_start" | "tool_end"
                | "context_compacted",
            ) => emit(event),
            _ => bail!("Unexpected harness event."),
        }
    }
    Ok(terminal)
}

pub fn terminal(result: Result<()>) -> Value {
    match result {
        Ok(()) => json!({"type":"result","result":{}}),
        Err(error) => json!({"type":"error","message":error.to_string()}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{os::unix::fs::PermissionsExt, time::Duration};

    #[tokio::test]
    async fn startup_progress_reaches_the_client_before_chat_output() -> Result<()> {
        let wire = b"{\"type\":\"model_loading\",\"progress\":0.42}\n\
                     {\"type\":\"activity\",\"contextTokens\":8192}\n\
                     {\"type\":\"delta\",\"text\":\"Ready\"}\n\
                     {\"type\":\"result\",\"result\":{}}\n";
        let received = std::cell::RefCell::new(Vec::new());
        read_events(BufReader::new(&wire[..]), |event| {
            received.borrow_mut().push(event);
        })
        .await?
        .context("Missing terminal event")??;
        assert_eq!(
            received.into_inner(),
            [
                json!({"type":"model_loading","progress":0.42}),
                json!({"type":"activity","contextTokens":8192}),
                json!({"type":"delta","text":"Ready"}),
            ]
        );
        Ok(())
    }

    #[tokio::test]
    async fn memory_alarm_closes_active_harness_and_surfaces_the_reason() -> Result<()> {
        let fixture = tempfile::tempdir()?;
        let executable = fixture.path().join("harness");
        std::fs::write(
            &executable,
            r#"#!/bin/sh
read -r request || exit 1
printf '%s\n' '{"type":"delta","text":"Partial answer"}'
if read -r extra; then exit 2; fi
touch "$0.closed"
"#,
        )?;
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700))?;
        let id = "575ee27d-72b4-4a1f-8eb7-e215b7af6736";
        let input = serde_json::from_value(json!({
            "request": {"connectionId":id,"model":"fixture","messages":[]},
            "connection": {"id":id,"name":"Fixture","provider":"fritz","modelId":"fixture"}
        }))?;
        let (alarm, observed_delta) = tokio::sync::oneshot::channel();
        let alarm = std::cell::Cell::new(Some(alarm));
        let result = tokio::time::timeout(
            Duration::from_secs(8),
            supervise_harness(
                &executable,
                input,
                |event| {
                    assert_eq!(event["text"], "Partial answer");
                    alarm.take().unwrap().send(()).unwrap();
                },
                async {
                    observed_delta.await.unwrap();
                    anyhow::anyhow!("Synthetic memory pressure")
                },
            ),
        )
        .await?;
        assert_eq!(result.unwrap_err().to_string(), "Synthetic memory pressure");
        assert!(executable.with_extension("closed").exists());
        Ok(())
    }
}
