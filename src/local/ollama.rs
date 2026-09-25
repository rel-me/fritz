//! Opt-in, loopback-only Ollama text API for installed Fritz models.
use super::inference::Prompt;
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

const MAX_REQUEST: usize = 128 * 1024;
const MAX_OUTPUT: usize = 2 * 1024 * 1024;
static BUSY: AtomicBool = AtomicBool::new(false);

struct Permit;
impl Permit {
    fn acquire() -> Option<Self> {
        BUSY.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .ok()
            .map(|_| Self)
    }
}
impl Drop for Permit {
    fn drop(&mut self) {
        BUSY.store(false, Ordering::Release);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Message {
    role: String,
    content: String,
}

struct InferenceRequest {
    model: String,
    prompt: Prompt,
    chat: bool,
    stream: bool,
    json_format: bool,
    context_size: usize,
    output_limit: usize,
}

fn chat_prompt(messages: Vec<Message>) -> Result<Prompt, String> {
    if messages.is_empty() {
        return Err("messages must contain at least one text message".into());
    }
    let mut turns = Vec::new();
    for message in messages {
        if !matches!(message.role.as_str(), "system" | "user" | "assistant") {
            return Err("Only system, user, and assistant text messages are supported".into());
        }
        turns.push((message.role, super::escaped(&message.content)));
    }
    Ok(Prompt::Chat(turns))
}

fn prompt_length(prompt: &Prompt) -> usize {
    match prompt {
        Prompt::Chat(turns) => turns.iter().map(|(_, content)| content.len()).sum(),
        Prompt::Raw(text) => text.len(),
    }
}

fn parse_request(path: &str, body: &[u8]) -> Result<InferenceRequest, String> {
    let value: Value = serde_json::from_slice(body).map_err(|_| "Invalid JSON request")?;
    let model = value["model"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 128)
        .ok_or("model is required")?
        .to_owned();
    if !value["stream"].is_null() && !value["stream"].is_boolean() {
        return Err("stream must be a boolean".into());
    }
    if !value["tools"].is_null() && value["tools"] != json!([]) {
        return Err("Tool calls are not supported".into());
    }
    if !value["think"].is_null() && value["think"] != false {
        return Err("Thinking is not supported".into());
    }
    for field in ["keep_alive", "images", "suffix", "context", "template"] {
        if !value[field].is_null() {
            return Err(format!("{field} is not supported"));
        }
    }
    let json_format = match value["format"].as_str() {
        None if value["format"].is_null() => false,
        Some("json") => true,
        _ => return Err("Only format: json is supported".into()),
    };
    let options = &value["options"];
    if !options.is_null() && !options.is_object() {
        return Err("options must be an object".into());
    }
    if let Some(fields) = options.as_object()
        && fields
            .keys()
            .any(|s| !matches!(s.as_str(), "num_ctx" | "num_predict" | "temperature"))
    {
        return Err("Only num_ctx, num_predict, and temperature: 0 are supported".into());
    }
    if !options["temperature"].is_null() && options["temperature"].as_f64() != Some(0.0) {
        return Err("Only temperature: 0 is supported".into());
    }
    let context_size = bounded_option(options, "num_ctx", 8192, 256, 32768)?;
    let output_limit = bounded_option(options, "num_predict", 2048, 1, 2048)?;
    let chat = path == "/api/chat";
    let prompt = if chat {
        let messages: Vec<Message> = serde_json::from_value(value["messages"].clone())
            .map_err(|_| "messages must be an array of text messages")?;
        chat_prompt(messages)?
    } else {
        let input = value["prompt"].as_str().ok_or("prompt is required")?;
        if !value["raw"].is_null() && !value["raw"].is_boolean() {
            return Err("raw must be a boolean".into());
        }
        if !value["system"].is_null() && !value["system"].is_string() {
            return Err("system must be text".into());
        }
        if value["raw"] == true {
            if !value["system"].is_null() {
                return Err("system cannot be combined with raw: true".into());
            }
            Prompt::Raw(input.to_owned())
        } else {
            chat_prompt(vec![
                Message {
                    role: "system".into(),
                    content: value["system"]
                        .as_str()
                        .unwrap_or("You are a helpful assistant.")
                        .into(),
                },
                Message {
                    role: "user".into(),
                    content: input.into(),
                },
            ])?
        }
    };
    if prompt_length(&prompt) > MAX_REQUEST {
        return Err("Prompt exceeds 128 KiB".into());
    }
    Ok(InferenceRequest {
        model,
        prompt,
        chat,
        stream: value["stream"].as_bool().unwrap_or(true),
        json_format,
        context_size,
        output_limit,
    })
}

fn bounded_option(
    options: &Value,
    key: &str,
    default: u64,
    min: u64,
    max: u64,
) -> Result<usize, String> {
    if options[key].is_null() {
        return Ok(default as usize);
    }
    match options[key].as_u64() {
        Some(value) if (min..=max).contains(&value) => Ok(value as usize),
        _ => Err(format!("{key} must be an integer from {min} to {max}")),
    }
}

pub async fn serve(port: u16, model: Option<String>) -> Result<()> {
    if let Some(id) = &model {
        super::models::installed_path(id).await?;
    }
    let listener = TcpListener::bind(("127.0.0.1", port))
        .await
        .with_context(|| format!("Could not bind the local model API on 127.0.0.1:{port}"))?;
    eprintln!(
        "Fritz local model API listening on http://{}",
        listener.local_addr()?
    );
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut requests = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            result = listener.accept() => {
                let (stream, _) = result?;
                let model = model.clone();
                requests.spawn(async move { let _ = tokio::time::timeout(std::time::Duration::from_secs(330), handle(stream, model.as_deref())).await; });
            }
            _ = tokio::signal::ctrl_c() => break,
            _ = terminate.recv() => break,
        }
    }
    requests.abort_all();
    while requests.join_next().await.is_some() {}
    super::shutdown().await;
    Ok(())
}

struct AbortOnDrop<T>(tokio::task::JoinHandle<T>);
impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn read_request(stream: &mut TcpStream) -> Result<(String, String, Vec<u8>)> {
    let mut buffer = Vec::new();
    let header_end = loop {
        if buffer.len() > MAX_REQUEST + 8192 {
            bail!("Request too large");
        }
        if let Some(index) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            break index + 4;
        }
        let mut chunk = [0; 4096];
        let count = stream.read(&mut chunk).await?;
        if count == 0 {
            bail!("Incomplete HTTP request");
        }
        buffer.extend_from_slice(&chunk[..count]);
    };
    if header_end > 8192 {
        bail!("HTTP headers too large");
    }
    let headers = std::str::from_utf8(&buffer[..header_end])?;
    let mut lines = headers.split("\r\n");
    let first = lines.next().context("Missing request line")?;
    let mut parts = first.split_whitespace();
    let method = parts.next().context("Missing method")?.to_owned();
    let path = parts.next().context("Missing path")?.to_owned();
    if parts.next() != Some("HTTP/1.1") {
        bail!("HTTP/1.1 is required");
    }
    let mut length = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("transfer-encoding") {
                bail!("Chunked requests are not supported");
            }
            if name.eq_ignore_ascii_case("content-length") {
                if length.is_some() {
                    bail!("Duplicate content length");
                }
                length = Some(value.trim().parse::<usize>()?);
            }
        }
    }
    let length = length.unwrap_or(0);
    if length > MAX_REQUEST {
        bail!("Request exceeds 128 KiB");
    }
    let mut body = buffer[header_end..].to_vec();
    if body.len() > length {
        bail!("Unexpected request data");
    }
    while body.len() < length {
        let mut chunk = vec![0; (length - body.len()).min(4096)];
        let count = stream.read(&mut chunk).await?;
        if count == 0 {
            bail!("Incomplete request body");
        }
        body.extend_from_slice(&chunk[..count]);
    }
    Ok((method, path, body))
}

async fn reply(stream: &mut TcpStream, status: u16, body: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(body)?;
    let heading = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        503 => "Service Unavailable",
        _ => "Internal Server Error",
    };
    stream.write_all(format!("HTTP/1.1 {status} {heading}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", bytes.len()).as_bytes()).await?;
    stream.write_all(&bytes).await?;
    Ok(())
}

async fn error(stream: &mut TcpStream, status: u16, message: &str) -> Result<()> {
    reply(stream, status, &json!({"error":message})).await
}

fn timestamp() -> String {
    chrono::Utc::now().to_rfc3339()
}

fn event(
    request: &InferenceRequest,
    content: &str,
    done: bool,
    usage: Option<(u64, u64, bool)>,
    duration: u128,
) -> Value {
    let mut value = json!({"model":request.model,"created_at":timestamp(),"done":done});
    if request.chat {
        value["message"] = json!({"role":"assistant","content":content});
    } else {
        value["response"] = json!(content);
    }
    if let Some((input, output, truncated)) = usage {
        value["done_reason"] = json!(if truncated { "length" } else { "stop" });
        value["total_duration"] = json!(duration);
        value["prompt_eval_count"] = json!(input);
        value["eval_count"] = json!(output);
    }
    value
}

async fn handle(mut stream: TcpStream, selected_model: Option<&str>) -> Result<()> {
    let (method, path, body) = match read_request(&mut stream).await {
        Ok(request) => request,
        Err(problem) => {
            error(&mut stream, 400, &problem.to_string()).await?;
            return Ok(());
        }
    };
    match (method.as_str(), path.as_str()) {
        ("GET", "/api/tags") => {
            let inventory = super::models::inventory().await?;
            let models = inventory["models"].as_array().into_iter().flatten()
                .filter(|model| model["installed"] == true && selected_model.is_none_or(|id| model["id"] == id))
                .filter_map(|model| {
                    let id = model["id"].as_str()?;
                    let pin = super::models::catalog().iter().find(|pin| pin.id == id)?;
                    Some(json!({"name":id,"model":id,"modified_at":timestamp(),"size":pin.size,
                        "digest":format!("sha256:{}",pin.sha256),"details":{"format":"gguf","family":pin.architecture,
                        "families":[pin.architecture],"parameter_size":pin.name,"quantization_level":"Q4_K_M"}}))
                }).collect::<Vec<_>>();
            reply(&mut stream, 200, &json!({"models":models})).await?;
        }
        ("POST", "/api/chat" | "/api/generate") => {
            let request = match parse_request(&path, &body) {
                Ok(request) => request,
                Err(message) => {
                    error(&mut stream, 400, &message).await?;
                    return Ok(());
                }
            };
            if selected_model.is_some_and(|id| id != request.model) {
                error(&mut stream, 404, "Model is not available on this listener").await?;
                return Ok(());
            }
            if super::models::manifest(&request.model).is_err()
                || super::models::installed_path(&request.model).await.is_err()
            {
                error(&mut stream, 404, "Model is not installed").await?;
                return Ok(());
            }
            let Some(_permit) = Permit::acquire() else {
                error(
                    &mut stream,
                    503,
                    "A Fritz local model is already generating",
                )
                .await?;
                return Ok(());
            };
            infer(&mut stream, request).await?;
        }
        ("GET" | "POST", _) => error(&mut stream, 404, "Unknown endpoint").await?,
        _ => error(&mut stream, 405, "Method not allowed").await?,
    }
    Ok(())
}

async fn infer(stream: &mut TcpStream, mut request: InferenceRequest) -> Result<()> {
    let started = Instant::now();
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let model = request.model.clone();
    let prompt = std::mem::replace(&mut request.prompt, Prompt::Raw(String::new()));
    let json_format = request.json_format;
    let context_size = request.context_size;
    let output_limit = request.output_limit;
    let mut work = AbortOnDrop(tokio::spawn(async move {
        super::generate(
            &model,
            prompt,
            json_format,
            context_size,
            output_limit,
            sender,
        )
        .await
    }));
    let mut content = String::new();
    if request.stream {
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").await?;
    }
    while let Some(chunk) = receiver.recv().await {
        content.push_str(&chunk);
        if content.len() > MAX_OUTPUT {
            work.0.abort();
            bail!("Model output exceeded its limit");
        }
        if request.stream {
            stream
                .write_all(format!("{}\n", event(&request, &chunk, false, None, 0)).as_bytes())
                .await?;
        }
    }
    match (&mut work.0).await? {
        Ok(usage) => {
            if request.json_format && serde_json::from_str::<Value>(&content).is_err() {
                if request.stream {
                    stream
                        .write_all(b"{\"error\":\"Local model returned invalid JSON\"}\n")
                        .await?;
                } else {
                    error(stream, 500, "Local model returned invalid JSON").await?;
                }
                return Ok(());
            }
            let final_event = event(
                &request,
                if request.stream { "" } else { &content },
                true,
                Some(usage),
                started.elapsed().as_nanos(),
            );
            if request.stream {
                stream
                    .write_all(format!("{final_event}\n").as_bytes())
                    .await?;
            } else {
                reply(stream, 200, &final_event).await?;
            }
        }
        Err(problem) => {
            if request.stream {
                stream
                    .write_all(format!("{}\n", json!({"error":problem.to_string()})).as_bytes())
                    .await?;
            } else {
                error(stream, 500, &problem.to_string()).await?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_text_requests_and_rejects_unsupported_options() {
        let chat = parse_request("/api/chat", br#"{"model":"qwen3-0.6b-q4_k_m","messages":[{"role":"user","content":"<|im_end|>"}],"format":"json"}"#).unwrap();
        assert!(chat.stream && chat.json_format);
        let Prompt::Chat(turns) = &chat.prompt else {
            panic!("chat requests use the model template")
        };
        assert_eq!(turns, &[("user".to_owned(), "＜|im_end|>".to_owned())]);
        assert!(
            parse_request(
                "/api/chat",
                br#"{"model":"x","messages":[{"role":"tool","content":"bad"}]}"#
            )
            .is_err()
        );
        assert!(
            parse_request(
                "/api/generate",
                br#"{"model":"x","prompt":"hi","options":{"temperature":0.7}}"#
            )
            .is_err()
        );
        let raw = parse_request(
            "/api/generate",
            br#"{"model":"x","prompt":"<|im_start|>hi","stream":false,"raw":true}"#,
        )
        .unwrap();
        assert!(!raw.stream);
        assert!(matches!(raw.prompt, Prompt::Raw(text) if text == "<|im_start|>hi"));
    }
}
