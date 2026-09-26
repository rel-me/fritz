//! Run typed decision requests in a separate child process over private pipes.

use crate::{
    decision::{DecisionResponse, HarnessInput},
    harness_client::read_line,
};
use anyhow::{Context, Result, bail};
use serde_json::Value;
use std::{path::Path, process::Stdio};
use tokio::io::{AsyncWriteExt, BufReader};

pub async fn evaluate_with_input(
    executable: &Path,
    input: HarnessInput,
) -> Result<DecisionResponse> {
    input.request.validate()?;
    let request = input.request.clone();
    let mut child = tokio::process::Command::new(executable)
        .arg("evaluate")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("Could not start fritz-decision-harness.")?;
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let reaper = tokio::spawn(async move { child.wait().await });
    let mut bytes = serde_json::to_vec(&input)?;
    bytes.push(b'\n');
    stdin.write_all(&bytes).await?;
    stdin.flush().await?;
    let mut reader = BufReader::new(stdout);
    let line = read_line(&mut reader, 2_000_000).await?;
    drop(stdin);
    let status = reaper.await??;
    let line = line.context("The decision harness disconnected before answering.")?;
    let event: Value = serde_json::from_str(&line).context("Invalid decision harness event.")?;
    match event["type"].as_str() {
        Some("result") if status.success() => {
            let response: DecisionResponse = serde_json::from_value(event["result"].clone())?;
            response.validate_for(&request)?;
            Ok(response)
        }
        Some("error") => bail!(
            "{}",
            event["message"]
                .as_str()
                .unwrap_or("The decision harness failed.")
        ),
        Some("cancelled") => bail!("The decision request was cancelled."),
        _ => bail!("The decision harness returned an unexpected event."),
    }
}
