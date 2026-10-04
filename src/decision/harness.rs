//! Shared single-request decision child runtime. Hosts call this only in an owned child process.
//! It reads private stdin and writes one terminal event; native cancellation may exit the process.
use crate::{decision, harness_client};
use anyhow::{Context, Result};
use serde_json::{Value, json};
use std::io::Write;
use tokio::io::{AsyncReadExt, BufReader};

fn emit(event: Value) {
    let mut out = std::io::stdout().lock();
    if serde_json::to_writer(&mut out, &event).is_ok() {
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }
}

pub async fn run_stdio() -> Result<()> {
    let mut input = BufReader::new(harness_client::PrivateStdin::new()?);
    let line = harness_client::read_line(&mut input, 3_000_000)
        .await?
        .context("Missing decision request.")?;
    let config: decision::HarnessInput =
        serde_json::from_str(&line).context("Invalid decision request.")?;
    config.validate()?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut byte = [0u8; 1];
    let is_local = matches!(config.backend, decision::HarnessBackend::Ollaya);
    let evaluation = async {
        match config.backend {
            decision::HarnessBackend::Jev { endpoint } => {
                let key = config.api_key.context("Jev requires an API key.")?;
                let backend = match endpoint {
                    Some(endpoint) => decision::Jev::with_endpoint(key, &endpoint)?,
                    None => decision::Jev::new(key)?,
                };
                decision::evaluate(&backend, &config.request).await
            }
            decision::HarnessBackend::Ollaya => {
                anyhow::ensure!(
                    config.api_key.is_none(),
                    "Local decision models do not use an API key."
                );
                let store = decision::local::ModelStore::from_configuration(
                    config
                        .model_store
                        .context("Local decisions require an explicit modelStore.")?,
                )?;
                decision::evaluate(&decision::local::Ollaya::new(store), &config.request).await
            }
        }
    };
    let (terminal, interrupted) = tokio::select! {
        result=evaluation=>(match result {
            Ok(response)=>json!({"type":"result","result":response}),
            Err(error)=>json!({"type":"error","message":error.to_string()}),
        }, false),
        _=tokio::time::sleep(std::time::Duration::from_secs(120))=>(json!({"type":"error","message":"The decision request exceeded its 120-second limit."}), true),
        _=input.read(&mut byte)=>(json!({"type":"cancelled"}), true),
        _=interrupt.recv()=>(json!({"type":"cancelled"}), true),
        _=sigint.recv()=>(json!({"type":"cancelled"}), true),
    };
    emit(terminal);
    if is_local && interrupted {
        // The terminal event has been flushed. Native loading/inference may still be on
        // its worker thread: libc exit/return from main runs ONNX's C++ global destructors
        // concurrently with that worker and can segfault. This read-only, single-request
        // process owns no pending writes; let the OS reclaim it without running atexit.
        unsafe { libc::_exit(0) };
    }
    Ok(())
}
