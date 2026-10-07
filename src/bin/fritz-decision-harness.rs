use clap::{Parser, Subcommand};

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
    /// Keep one local ONNX engine resident. Versioned, serial private requests only.
    Resident,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let result = match cli.command {
        Command::Evaluate => fritz::decision::harness::run_stdio().await,
        Command::Resident => fritz::decision::harness::run_resident_stdio().await,
    };
    if let Err(error) = result {
        println!(
            "{}",
            serde_json::json!({"type":"error","message":error.to_string()})
        );
        std::process::exit(1);
    }
}
