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
    // Read the private pipe through readiness, not Tokio's blocking stdin adapter:
    // a completed run must exit while its supervisor still holds stdin open.
    use std::os::fd::{AsRawFd, FromRawFd};
    // SAFETY: fd 0 is valid and exclusively owned here; no other stdin reader exists.
    let stdin = unsafe { std::fs::File::from_raw_fd(0) };
    // SAFETY: F_GETFL/F_SETFL operate on our owned fd and do not retain pointers.
    let flags = unsafe { libc::fcntl(stdin.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(stdin.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    let mut input = BufReader::new(PipeReader(tokio::io::unix::AsyncFd::new(stdin)?));
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
struct PipeReader(tokio::io::unix::AsyncFd<std::fs::File>);
impl tokio::io::AsyncRead for PipeReader {
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
#[tokio::main]
async fn main() {
    let result = run().await;
    local::shutdown().await;
    if let Err(error) = result {
        emit(harness_client::terminal(Err(error)));
        std::process::exit(1);
    }
}
