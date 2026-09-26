use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use fritz::{harness, harness_client, local};
use serde_json::json;
use std::io::Write;
use tokio::io::{AsyncReadExt, BufReader};

#[derive(Parser)]
#[command(
    version,
    about = "Fritz chat harness. Private NDJSON input/output; no HTTP listener."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Read one run configuration from stdin, then stream events. Keep stdin open;
    /// closing it cancels the run. For interactive use, prefer fritz chat --project.
    Chat,
}
fn emit(event: serde_json::Value) {
    let mut out = std::io::stdout().lock();
    if serde_json::to_writer(&mut out, &event).is_ok() {
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }
}
async fn run() -> Result<()> {
    let _cli = Cli::parse();
    // Read the private pipe through readiness, not Tokio's blocking stdin adapter.
    let mut input = BufReader::new(harness_client::PrivateStdin::new()?);
    let line = harness_client::read_line(&mut input, 3_000_000)
        .await?
        .context("Missing harness request.")?;
    let request: harness::Input =
        serde_json::from_str(&line).context("Invalid harness request.")?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut byte = [0u8; 1];
    let terminal = tokio::select! {
        result=harness::run(request,emit)=>harness_client::terminal(result),
        _=input.read(&mut byte)=>json!({"type":"cancelled"}),
        _=interrupt.recv()=>json!({"type":"cancelled"}),
        _=sigint.recv()=>json!({"type":"cancelled"}),
    };
    emit(terminal);
    Ok(())
}
#[tokio::main]
async fn main() {
    let result = run().await;
    local::shutdown().await;
    if let Err(error) = result {
        emit(harness_client::terminal(Err(error)));
        std::process::exit(1);
    }
}
