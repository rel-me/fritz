//! Opt-in HTTPS dashboard. Never forward arbitrary paths, headers, or credentials.
use crate::{Error, Request as AgentHttpRequest};
use base64::Engine;
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs,
    io::{self, BufRead, BufReader, Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

const SESSION_SECONDS: u64 = 7 * 24 * 3600;
const MAX_JOBS: usize = 64;
/// Assets and command policy belong to the host; the service never forwards arbitrary paths.
pub trait RemoteHost: Send + Sync {
    fn asset(&self, path: &str) -> Option<Asset>;
    fn validate_action(&self, request: &Value) -> Result<(), Error>;
    fn run_action(&self, request: &Value) -> Result<Value, Error>;
    fn read(&self, path: &str) -> Option<Result<Value, Error>>;
}
pub struct Asset {
    pub content_type: &'static str,
    pub body: &'static str,
}
#[derive(Clone)]
pub struct Identity {
    pub cookie_name: String,
    pub request_header: String,
}
pub struct RemoteAccessService {
    service: Mutex<Option<Service>>,
    host: Arc<dyn RemoteHost>,
    identity: Identity,
}
impl RemoteAccessService {
    pub fn new(host: Arc<dyn RemoteHost>, identity: Identity) -> Result<Self, Error> {
        let valid_cookie = identity
            .cookie_name
            .strip_prefix("__Host-")
            .is_some_and(|name| {
                !name.is_empty()
                    && name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
            });
        if !valid_cookie
            || identity.request_header.is_empty()
            || !identity
                .request_header
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        {
            return Err(Error::usage(
                "Provide a __Host- cookie name and lowercase request header.",
            ));
        }
        Ok(Self {
            service: Mutex::new(None),
            host,
            identity,
        })
    }
    /// Call only through the host's authenticated local control transport.
    pub fn manage(&self, request: &AgentHttpRequest) -> Result<Value, Error> {
        manage(self, request)
    }
}
impl Drop for RemoteAccessService {
    fn drop(&mut self) {
        if let Ok(service) = self.service.get_mut()
            && let Some(service) = service.take()
        {
            service.shared.enabled.store(false, Ordering::Release);
            let _ = service.listener.join();
        }
    }
}

struct Service {
    shared: Arc<Shared>,
    listener: thread::JoinHandle<()>,
}
struct Shared {
    host: Arc<dyn RemoteHost>,
    identity: Identity,
    enabled: AtomicBool,
    origin: String,
    authority: String,
    state: Mutex<State>,
}
#[derive(Default)]
struct State {
    pairing: Option<([u8; 32], Instant)>,
    attempts: Vec<Instant>,
    devices: Vec<Device>,
    jobs: Vec<Job>,
}
struct Device {
    id: String,
    name: String,
    hash: [u8; 32],
    expires: Instant,
}
struct Job {
    id: String,
    device: String,
    key: String,
    request: Value,
    result: Option<Value>,
}
fn secret() -> Result<String, Error> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes)
        .map_err(|_| Error::capture("Secure random generation failed"))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}
fn hash(value: &str) -> [u8; 32] {
    Sha256::digest(value.as_bytes()).into()
}
fn state(shared: &Shared) -> Result<std::sync::MutexGuard<'_, State>, Error> {
    shared
        .state
        .lock()
        .map_err(|_| Error::capture("Remote access state unavailable"))
}
fn status(shared: &Shared) -> Result<Value, Error> {
    let mut state = state(shared)?;
    state.devices.retain(|d| d.expires > Instant::now());
    Ok(
        json!({"enabled": true, "origin": shared.origin, "devices": state.devices.iter().map(|d| json!({"id":d.id,"name":d.name})).collect::<Vec<_>>()}),
    )
}

fn manage(owner: &RemoteAccessService, request: &AgentHttpRequest) -> Result<Value, Error> {
    let mut service = owner
        .service
        .lock()
        .map_err(|_| Error::capture("Remote access service unavailable"))?;
    match (request.method.as_str(), request.path.as_str()) {
        ("GET", "/v1/remote-access") => match service.as_ref() {
            Some(s) => status(&s.shared),
            None => Ok(json!({"enabled":false,"devices":[]})),
        },
        ("POST", "/v1/remote-access/enable") => {
            if service.is_some() {
                return Err(Error::usage(
                    "Disable remote access before changing its configuration.",
                ));
            }
            let config: Config =
                serde_json::from_slice(&request.body).map_err(|e| Error::usage(e.to_string()))?;
            let next = start(config, owner.host.clone(), owner.identity.clone())?;
            let result = status(&next.shared);
            *service = Some(next);
            result
        }
        ("POST", "/v1/remote-access/disable") => {
            if let Some(s) = service.take() {
                s.shared.enabled.store(false, Ordering::Release);
                let mut state = state(&s.shared)?;
                state.devices.clear();
                state.pairing = None;
                drop(state);
                let _ = s.listener.join();
            }
            Ok(json!({"enabled":false,"devices":[]}))
        }
        ("POST", "/v1/remote-access/pair") => {
            let s = service
                .as_ref()
                .ok_or_else(|| Error::usage("Enable remote access first."))?;
            let code = secret()?;
            state(&s.shared)?.pairing =
                Some((hash(&code), Instant::now() + Duration::from_secs(300)));
            Ok(json!({"code":code,"expires_in":300}))
        }
        ("POST", "/v1/remote-access/revoke") => {
            let body: Value =
                serde_json::from_slice(&request.body).map_err(|e| Error::usage(e.to_string()))?;
            let id = body["id"]
                .as_str()
                .ok_or_else(|| Error::usage("Device ID is required."))?;
            let s = service
                .as_ref()
                .ok_or_else(|| Error::usage("Remote access is disabled."))?;
            state(&s.shared)?.devices.retain(|d| d.id != id);
            status(&s.shared)
        }
        _ => Err(Error::usage("Unknown remote access operation.")),
    }
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    bind: String,
    origin: String,
    certificate: String,
    private_key: String,
}
fn validate_config(config: &Config) -> Result<(SocketAddr, String), Error> {
    let address: SocketAddr = config
        .bind
        .parse()
        .map_err(|_| Error::usage("Enter an IP address and port for the listener."))?;
    if address.port() == 0 {
        return Err(Error::usage("Remote access needs a fixed port."));
    }
    let url =
        url::Url::parse(&config.origin).map_err(|_| Error::usage("Enter an HTTPS origin."))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(address.port())
        || config.origin != url.origin().ascii_serialization()
    {
        return Err(Error::usage(
            "Origin must be https://hostname:port, with no path, matching the listener port.",
        ));
    }
    Ok((
        address,
        config.origin.trim_start_matches("https://").to_string(),
    ))
}
fn start(config: Config, host: Arc<dyn RemoteHost>, identity: Identity) -> Result<Service, Error> {
    let (address, authority) = validate_config(&config)?;
    let certificates =
        rustls_pemfile::certs(&mut BufReader::new(fs::File::open(&config.certificate)?))
            .collect::<Result<Vec<_>, _>>()?;
    let key =
        rustls_pemfile::private_key(&mut BufReader::new(fs::File::open(&config.private_key)?))?
            .ok_or_else(|| Error::usage("The PEM file contains no private key."))?;
    let tls =
        ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map_err(|e| Error::capture(e.to_string()))?
            .with_no_client_auth()
            .with_single_cert(certificates, key)
            .map_err(|e| Error::usage(e.to_string()))?;
    let tls = Arc::new(tls);
    let listener = TcpListener::bind(address)?;
    listener.set_nonblocking(true)?;
    let shared = Arc::new(Shared {
        host,
        identity,
        enabled: AtomicBool::new(true),
        origin: config.origin,
        authority,
        state: Mutex::new(State::default()),
    });
    let worker = shared.clone();
    let handle = thread::Builder::new()
        .name("fritz-remote".into())
        .spawn(move || {
            let active = Arc::new(AtomicUsize::new(0));
            while worker.enabled.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((socket, _)) => {
                        if active
                            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                                (n < 16).then_some(n + 1)
                            })
                            .is_err()
                        {
                            continue;
                        }
                        let shared = worker.clone();
                        let tls = tls.clone();
                        let active = active.clone();
                        let permit = ConnectionPermit(active);
                        let _ = thread::Builder::new()
                            .name("fritz-remote-http".into())
                            .spawn(move || {
                                let _permit = permit;
                                let _ = serve(socket, tls, shared);
                            });
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(25))
                    }
                    Err(_) => {
                        worker.enabled.store(false, Ordering::Release);
                        break;
                    }
                }
            }
        })?;
    Ok(Service {
        shared,
        listener: handle,
    })
}
struct ConnectionPermit(Arc<AtomicUsize>);
impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
struct Request {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}
// One request per TLS connection, strict framing, and finite total header/body budgets.
fn read_request(reader: &mut impl BufRead) -> Result<Request, Error> {
    let mut budget = 16 * 1024;
    let mut line = String::new();
    read_line(reader, &mut line, &mut budget)?;
    let parts: Vec<_> = line.split_whitespace().collect();
    if parts.len() != 3 || parts[2] != "HTTP/1.1" || !parts[1].starts_with('/') {
        return Err(Error::usage("Invalid HTTP request."));
    }
    let method = parts[0].to_string();
    let path = parts[1].to_string();
    let mut headers = HashMap::new();
    loop {
        line.clear();
        read_line(reader, &mut line, &mut budget)?;
        if line == "\r\n" {
            break;
        }
        let (name, value) = line
            .trim_end_matches("\r\n")
            .split_once(':')
            .ok_or_else(|| Error::usage("Invalid header."))?;
        if name.is_empty()
            || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            || value.contains(['\r', '\n'])
            || headers
                .insert(name.to_ascii_lowercase(), value.trim().to_string())
                .is_some()
        {
            return Err(Error::usage("Invalid or duplicate header."));
        }
    }
    if headers.contains_key("transfer-encoding") || headers.contains_key("expect") {
        return Err(Error::usage("Unsupported request framing."));
    }
    let length = match headers.get("content-length") {
        Some(s) => s
            .parse::<usize>()
            .map_err(|_| Error::usage("Invalid length."))?,
        None => 0,
    };
    if length > 64 * 1024 {
        return Err(Error::usage("Request too large."));
    }
    if method != "GET"
        && headers.get("content-type").map(String::as_str) != Some("application/json")
    {
        return Err(Error::usage("JSON content type required."));
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    Ok(Request {
        method,
        path,
        headers,
        body,
    })
}
fn read_line(
    reader: &mut impl BufRead,
    line: &mut String,
    budget: &mut usize,
) -> Result<(), Error> {
    let n = reader.take(*budget as u64).read_line(line)?;
    *budget -= n;
    if !line.ends_with("\r\n") {
        return Err(Error::usage("Invalid or oversized HTTP headers."));
    }
    Ok(())
}
struct DeadlineSocket {
    socket: TcpStream,
    deadline: Instant,
}
impl Read for DeadlineSocket {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let remaining = self
            .deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "Request deadline exceeded"))?;
        self.socket.set_read_timeout(Some(remaining))?;
        self.socket.read(buffer)
    }
}
impl Write for DeadlineSocket {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.socket.write(buffer)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.socket.flush()
    }
}
fn serve(socket: TcpStream, tls: Arc<ServerConfig>, shared: Arc<Shared>) -> Result<(), Error> {
    // macOS accepted sockets inherit the nonblocking listener flag.
    socket.set_nonblocking(false)?;
    socket.set_write_timeout(Some(Duration::from_secs(5)))?;
    let connection = ServerConnection::new(tls).map_err(|e| Error::capture(e.to_string()))?;
    let mut stream = StreamOwned::new(
        connection,
        DeadlineSocket {
            socket,
            deadline: Instant::now() + Duration::from_secs(5),
        },
    );
    let request = read_request(&mut BufReader::new(&mut stream));
    let response = match request {
        Ok(r) => {
            respond(&r, &shared).unwrap_or_else(|_| Reply::error(500, "Remote request failed."))
        }
        Err(_) => Reply::error(400, "Invalid request."),
    };
    let mut writer = stream;
    write!(
        writer,
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n{}\r\n",
        response.code,
        if response.code < 400 { "OK" } else { "Error" },
        response.kind,
        response.body.len(),
        response.headers
    )?;
    writer.write_all(&response.body)?;
    writer.conn.send_close_notify();
    writer.flush()?;
    Ok(())
}
struct Reply {
    code: u16,
    kind: &'static str,
    body: Vec<u8>,
    headers: String,
}
impl Reply {
    fn json(code: u16, value: Value) -> Self {
        Self {
            code,
            kind: "application/json",
            body: value.to_string().into_bytes(),
            headers: String::new(),
        }
    }
    fn error(code: u16, message: &str) -> Self {
        Self::json(code, json!({"error":message}))
    }
    fn asset(kind: &'static str, body: &str) -> Self {
        Self {
            code: 200,
            kind,
            body: body.as_bytes().to_vec(),
            headers: String::new(),
        }
    }
}
fn authorized_device(request: &Request, s: &mut State, cookie_name: &str) -> Option<String> {
    s.devices.retain(|d| d.expires > Instant::now());
    let tokens: Vec<_> = request
        .headers
        .get("cookie")?
        .split(';')
        .filter_map(|c| {
            c.trim()
                .strip_prefix(cookie_name)
                .and_then(|value| value.strip_prefix('='))
        })
        .collect();
    if tokens.len() != 1 {
        return None;
    }
    let digest = hash(tokens[0]);
    s.devices
        .iter()
        .find(|d| d.hash == digest)
        .map(|d| d.id.clone())
}
fn respond(r: &Request, shared: &Arc<Shared>) -> Result<Reply, Error> {
    if !shared.enabled.load(Ordering::Acquire) {
        return Ok(Reply::error(503, "Remote access disabled."));
    }
    if r.headers.get("host") != Some(&shared.authority) {
        return Ok(Reply::error(421, "Unexpected host."));
    }
    if r.method != "GET"
        && (r.headers.get("origin") != Some(&shared.origin)
            || r.headers
                .get(&shared.identity.request_header)
                .map(String::as_str)
                != Some("1"))
    {
        return Ok(Reply::error(403, "Same-origin request required."));
    }
    if r.method == "GET"
        && let Some(asset) = shared.host.asset(&r.path)
    {
        return Ok(Reply::asset(asset.content_type, asset.body));
    }
    if r.method == "POST" && r.path == "/v1/remote/pair" {
        let mut s = state(shared)?;
        let now = Instant::now();
        s.attempts
            .retain(|t| now.duration_since(*t) < Duration::from_secs(60));
        if s.attempts.len() >= 10 {
            return Ok(Reply::error(
                429,
                "Too many pairing attempts. Wait one minute.",
            ));
        }
        s.attempts.push(now);
        let body: Value = serde_json::from_slice(&r.body).unwrap_or(Value::Null);
        let code = body["code"].as_str().unwrap_or("");
        if !s
            .pairing
            .as_ref()
            .is_some_and(|(digest, expiry)| *expiry > now && *digest == hash(code))
        {
            return Ok(Reply::error(401, "Invalid or expired pairing code."));
        }
        s.devices.retain(|d| d.expires > now);
        if s.devices.len() >= 16 {
            return Ok(Reply::error(409, "Revoke a device before pairing another."));
        }
        let token = secret()?;
        s.pairing = None;
        s.devices.push(Device {
            id: Uuid::new_v4().to_string(),
            name: body["name"]
                .as_str()
                .unwrap_or("Web browser")
                .chars()
                .take(80)
                .collect(),
            hash: hash(&token),
            expires: now + Duration::from_secs(SESSION_SECONDS),
        });
        let mut reply = Reply::json(200, json!({"paired":true}));
        reply.headers = format!(
            "Set-Cookie: {}={token}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age={SESSION_SECONDS}\r\n",
            shared.identity.cookie_name
        );
        return Ok(reply);
    }
    let mut s = state(shared)?;
    let Some(device) = authorized_device(r, &mut s, &shared.identity.cookie_name) else {
        return Ok(Reply::error(
            401,
            "Pair this browser from the app Settings.",
        ));
    };
    if r.method == "POST" && r.path == "/v1/remote/logout" {
        s.devices.retain(|d| d.id != device);
        let mut reply = Reply::json(200, json!({"paired":false}));
        reply.headers = format!(
            "Set-Cookie: {}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0\r\n",
            shared.identity.cookie_name
        );
        return Ok(reply);
    }
    if r.method == "GET" && r.path == "/v1/remote/jobs" {
        return Ok(Reply::json(
            200,
            json!({"jobs":s.jobs.iter().filter(|j|j.device==device).map(|j|json!({"id":j.id,"request":j.request,"state":if j.result.is_some(){"finished"}else{"running"},"failed":j.result.as_ref().is_some_and(|r| r.get("error").is_some() || r["status"] == "error")})).collect::<Vec<_>>()}),
        ));
    }
    if r.method == "GET" && r.path.starts_with("/v1/remote/jobs/") {
        let id = r.path.trim_start_matches("/v1/remote/jobs/");
        return Ok(
            match s.jobs.iter().find(|j| j.id == id && j.device == device) {
                Some(job) => Reply::json(200, json!({"result":job.result})),
                None => Reply::error(404, "Unknown job."),
            },
        );
    }
    if r.method == "POST" && r.path == "/v1/remote/jobs" {
        let request: Value = match serde_json::from_slice(&r.body) {
            Ok(v) => v,
            Err(_) => return Ok(Reply::error(400, "Invalid JSON.")),
        };
        let Some(key) = request["key"]
            .as_str()
            .filter(|k| !k.is_empty() && k.len() <= 80)
        else {
            return Ok(Reply::error(400, "An action key is required."));
        };
        if let Some(job) = s.jobs.iter().find(|j| j.device == device && j.key == key) {
            return Ok(if job.request == request {
                Reply::json(202, json!({"id":job.id}))
            } else {
                Reply::error(409, "Action key already used with different input.")
            });
        }
        if s.jobs.len() >= MAX_JOBS || s.jobs.iter().filter(|j| j.result.is_none()).count() >= 4 {
            return Ok(Reply::error(
                429,
                "Action capacity reached. Restart remote access after current jobs finish to clear history.",
            ));
        }
        if let Err(error) = shared.host.validate_action(&request) {
            return Ok(Reply::error(400, &error.render_for_stderr()));
        }
        let action = request.clone();
        let id = Uuid::new_v4().to_string();
        s.jobs.push(Job {
            id: id.clone(),
            device: device.clone(),
            key: key.to_string(),
            request,
            result: None,
        });
        let shared = shared.clone();
        let job_id = id.clone();
        let spawn=thread::Builder::new().name("fritz-remote-job".into()).spawn(move || {
            let allowed=shared.enabled.load(Ordering::Acquire) && state(&shared).is_ok_and(|s|s.devices.iter().any(|d|d.id==device && d.expires>Instant::now()));
            let result=if allowed {shared.host.run_action(&action).unwrap_or_else(|_|json!({"error":"Action failed; inspect the app on the Mac before retrying."}))}else{json!({"error":"Access revoked before execution."})};
            if let Ok(mut s)=state(&shared)&& let Some(job)=s.jobs.iter_mut().find(|j|j.id==job_id) {job.result=Some(result);}
        });
        if spawn.is_err() {
            s.jobs.last_mut().unwrap().result = Some(json!({"error":"Could not start action."}));
        }
        return Ok(Reply::json(202, json!({"id":id})));
    }
    drop(s);
    if r.method == "GET"
        && let Some(result) = shared.host.read(&r.path)
    {
        return Ok(Reply::json(200, result?));
    }
    Ok(Reply::error(404, "Unknown dashboard operation."))
}

#[cfg(test)]
mod tests;
