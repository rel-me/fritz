#[path = "../entrypoints/decision.rs"]
mod entrypoint;

#[tokio::main]
async fn main() {
    entrypoint::run_main().await;
}
