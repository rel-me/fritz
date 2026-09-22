//! The app service owns credentials; each chat owns one isolated harness process.
//! Closing its private stdin cancels the run and tears down command process groups.
use crate::{
    config, harness,
    provider::{self, ChatRequest},
};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::process::Stdio;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader};

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
    let connection = config::find(Some(&request.connection_id))?;
    let api_key = if connection.provider == config::ProviderKind::Fritz {
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
    let reaper = tokio::spawn(async move { child.wait().await });
    let mut bytes = serde_json::to_vec(&input)?;
    bytes.push(b'\n');
    stdin.write_all(&bytes).await?;
    stdin.flush().await?;
    // Retain stdin for the entire run. Its drop signals Stop, service exit, or error.
    let mut reader = BufReader::new(stdout);
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
                terminal = Some(Err(anyhow::anyhow!("The coding run was cancelled.")));
                break;
            }
            Some("delta" | "usage" | "activity" | "tool_start" | "tool_end") => emit(event),
            _ => bail!("Unexpected harness event."),
        }
    }
    drop(stdin);
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

pub fn terminal(result: Result<()>) -> Value {
    match result {
        Ok(()) => json!({"type":"result","result":{}}),
        Err(error) => json!({"type":"error","message":error.to_string()}),
    }
}
