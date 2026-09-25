use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use fritz::{decision, harness_client};
use serde_json::{Value, json};
use std::io::Write;
use tokio::io::{AsyncReadExt, BufReader};

#[derive(Parser)]
#[command(
    version,
    about = "Fritz decision harness. Private NDJSON input/output; no listener."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Evaluate typed questions. Keep stdin open; closing it cancels the request.
    Evaluate,
}

fn emit(event: Value) {
    let mut out = std::io::stdout().lock();
    if serde_json::to_writer(&mut out, &event).is_ok() {
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }
}

async fn run() -> Result<()> {
    let _cli = Cli::parse();
    let mut input = BufReader::new(harness_client::PrivateStdin::new()?);
    let line = harness_client::read_line(&mut input, 3_000_000)
        .await?
        .context("Missing decision request.")?;
    let config: decision::HarnessInput =
        serde_json::from_str(&line).context("Invalid decision request.")?;
    config.request.validate()?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut byte = [0u8; 1];
    let evaluation = async {
        let key = config.api_key.context("Jev requires an API key.")?;
        let backend = match config.backend {
            decision::HarnessBackend::Jev { endpoint: None } => decision::Jev::new(key)?,
            decision::HarnessBackend::Jev {
                endpoint: Some(endpoint),
            } => decision::Jev::with_endpoint(key, &endpoint)?,
        };
        decision::evaluate(&backend, &config.request).await
    };
    let terminal = tokio::select! {
        result=evaluation=>match result {
            Ok(response)=>json!({"type":"result","result":response}),
            Err(error)=>json!({"type":"error","message":error.to_string()}),
        },
        _=input.read(&mut byte)=>json!({"type":"cancelled"}),
        _=interrupt.recv()=>json!({"type":"cancelled"}),
        _=sigint.recv()=>json!({"type":"cancelled"}),
    };
    emit(terminal);
    Ok(())
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        emit(json!({"type":"error","message":error.to_string()}));
        std::process::exit(1);
    }
}
