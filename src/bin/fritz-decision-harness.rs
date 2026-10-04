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
}

#[tokio::main]
async fn main() {
    let _cli = Cli::parse();
    if let Err(error) = fritz::decision::harness::run_stdio().await {
        println!(
            "{}",
            serde_json::json!({"type":"error","message":error.to_string()})
        );
        std::process::exit(1);
    }
}
