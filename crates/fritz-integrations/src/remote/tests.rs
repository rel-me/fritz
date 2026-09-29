use super::*;
use std::env;
struct TestHost;
impl RemoteHost for TestHost {
    fn asset(&self, _: &str) -> Option<Asset> {
        None
    }
    fn validate_action(&self, _: &Value) -> Result<(), Error> {
        Ok(())
    }
    fn run_action(&self, _: &Value) -> Result<Value, Error> {
        Ok(json!({"status":"ok"}))
    }
    fn read(&self, _: &str) -> Option<Result<Value, Error>> {
        None
    }
}
fn identity() -> Identity {
    Identity {
        cookie_name: "__Host-fritz".into(),
        request_header: "x-fritz-request".into(),
    }
}

fn shared() -> Arc<Shared> {
    Arc::new(Shared {
        host: Arc::new(TestHost),
        identity: identity(),
        enabled: AtomicBool::new(true),
        origin: "https://fritz.test:17443".into(),
        authority: "fritz.test:17443".into(),
        state: Mutex::new(State::default()),
    })
}
fn request(method: &str, path: &str, body: Value) -> Request {
    Request {
        method: method.into(),
        path: path.into(),
        headers: HashMap::from([
            ("host".into(), "fritz.test:17443".into()),
            ("origin".into(), "https://fritz.test:17443".into()),
            ("x-fritz-request".into(), "1".into()),
        ]),
        body: body.to_string().into_bytes(),
    }
}
fn pair(s: &Arc<Shared>) -> String {
    state(s).unwrap().pairing = Some((
        hash("fixture-code"),
        Instant::now() + Duration::from_secs(60),
    ));
    let reply = respond(
        &request(
            "POST",
            "/v1/remote/pair",
            json!({"code":"fixture-code","name":"Laptop"}),
        ),
        s,
    )
    .unwrap();
    assert_eq!(reply.code, 200);
    assert!(reply.headers.contains("Secure; HttpOnly; SameSite=Strict"));
    reply
        .headers
        .strip_prefix("Set-Cookie: ")
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .into()
}
#[test]
fn pairing_is_single_use_expires_and_is_rate_limited() {
    let s = shared();
    let _cookie = pair(&s);
    let r = request("POST", "/v1/remote/pair", json!({"code":"fixture-code"}));
    assert_eq!(respond(&r, &s).unwrap().code, 401);
    state(&s).unwrap().pairing = Some((
        hash("fixture-code"),
        Instant::now() - Duration::from_secs(1),
    ));
    assert_eq!(respond(&r, &s).unwrap().code, 401);
    for _ in 0..7 {
        assert_eq!(respond(&r, &s).unwrap().code, 401);
    }
    assert_eq!(respond(&r, &s).unwrap().code, 429);
}
#[test]
fn browser_sessions_expire_and_revoke() {
    let s = shared();
    let cookie = pair(&s);
    let mut r = request("GET", "/v1/remote/jobs", Value::Null);
    assert_eq!(respond(&r, &s).unwrap().code, 401);
    r.headers.insert("cookie".into(), cookie.clone());
    assert_eq!(respond(&r, &s).unwrap().code, 200);
    state(&s).unwrap().devices[0].expires = Instant::now() - Duration::from_secs(1);
    assert_eq!(respond(&r, &s).unwrap().code, 401);
    r.headers.insert("cookie".into(), pair(&s));
    state(&s).unwrap().devices.clear();
    assert_eq!(respond(&r, &s).unwrap().code, 401);
}
#[test]
fn csrf_host_and_disabled_service_are_enforced() {
    let s = shared();
    let mut r = request("POST", "/v1/remote/pair", json!({}));
    r.headers.remove("origin");
    assert_eq!(respond(&r, &s).unwrap().code, 403);
    r.headers
        .insert("origin".into(), "https://evil.test".into());
    assert_eq!(respond(&r, &s).unwrap().code, 403);
    r.headers.insert("host".into(), "evil.test".into());
    assert_eq!(respond(&r, &s).unwrap().code, 421);
    s.enabled.store(false, Ordering::Release);
    assert_eq!(respond(&r, &s).unwrap().code, 503);
}
#[test]
fn retries_are_idempotent_scoped_to_device_and_reject_changed_input() {
    let s = shared();
    let cookie = pair(&s);
    let device = state(&s).unwrap().devices[0].id.clone();
    let body = json!({"key":"same-key","action":"example-action","body":{"name":"Example"}});
    state(&s).unwrap().jobs.push(Job {
        id: "job-id".into(),
        device,
        key: "same-key".into(),
        request: body.clone(),
        result: Some(json!({"status":"ok"})),
    });
    let mut r = request("POST", "/v1/remote/jobs", body.clone());
    r.headers.insert("cookie".into(), cookie);
    assert_eq!(respond(&r, &s).unwrap().code, 202);
    assert_eq!(state(&s).unwrap().jobs.len(), 1);
    r.body = json!({"key":"same-key","action":"example-action","body":{"name":"Different"}})
        .to_string()
        .into_bytes();
    assert_eq!(respond(&r, &s).unwrap().code, 409);
    r = request("GET", "/v1/remote/jobs", Value::Null);
    r.headers.insert("cookie".into(), pair(&s));
    let reply = respond(&r, &s).unwrap();
    assert_eq!(
        serde_json::from_slice::<Value>(&reply.body).unwrap()["jobs"],
        json!([])
    );
}
#[test]
fn http_framing_rejects_duplicates_chunking_and_oversize_bodies() {
    for input in [
        "POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 65537\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "GET / HTTP/1.1\n\n",
    ] {
        assert!(read_request(&mut io::Cursor::new(input)).is_err());
    }
    assert!(
        read_request(&mut io::Cursor::new(
            "GET / HTTP/1.1\r\nHost: fritz.test\r\n\r\n"
        ))
        .is_ok()
    );
    assert!(
        read_request(&mut io::Cursor::new(format!(
            "GET / HTTP/1.1\r\nX-Padding: {}\r\n\r\n",
            "a".repeat(17000)
        )))
        .is_err()
    );
}
#[test]
fn configuration_requires_exact_https_origin_and_matching_port() {
    let mut c = Config {
        bind: "127.0.0.1:17443".into(),
        origin: "https://fritz.test:17443".into(),
        certificate: String::new(),
        private_key: String::new(),
    };
    assert!(validate_config(&c).is_ok());
    for origin in [
        "http://fritz.test:17443",
        "https://fritz.test",
        "https://fritz.test:17443/path",
        "https://fritz.test:17443/",
        "https://user@fritz.test:17443",
    ] {
        c.origin = origin.into();
        assert!(validate_config(&c).is_err());
    }
}

#[test]
fn https_listener_completes_tls_and_rejects_unauthenticated_requests() {
    // Generate a disposable certificate; never alter system trust or disable verification.
    let directory = env::temp_dir().join(format!("fritz-remote-tls-{}", Uuid::new_v4()));
    fs::create_dir(&directory).unwrap();
    let cert = directory.join("certificate.pem");
    let key = directory.join("key.pem");
    let generated = std::process::Command::new("openssl")
        .args([
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=DNS:localhost",
            "-addext",
            "basicConstraints=critical,CA:FALSE",
            "-keyout",
        ])
        .arg(&key)
        .arg("-out")
        .arg(&cert)
        .output()
        .unwrap();
    assert!(
        generated.status.success(),
        "Could not generate test TLS certificate"
    );
    let socket = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = socket.local_addr().unwrap();
    drop(socket);
    let service = start(
        Config {
            bind: address.to_string(),
            origin: format!("https://localhost:{}", address.port()),
            certificate: cert.display().to_string(),
            private_key: key.display().to_string(),
        },
        Arc::new(TestHost),
        identity(),
    )
    .unwrap();
    let mut roots = rustls::RootCertStore::empty();
    for certificate in rustls_pemfile::certs(&mut BufReader::new(fs::File::open(&cert).unwrap())) {
        roots.add(certificate.unwrap()).unwrap();
    }
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_root_certificates(roots)
    .with_no_client_auth();
    let connection =
        rustls::ClientConnection::new(Arc::new(config), "localhost".try_into().unwrap()).unwrap();
    let socket = TcpStream::connect(address).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut stream = StreamOwned::new(connection, socket);
    write!(
        stream,
        "GET /v1/remote/jobs HTTP/1.1\r\nHost: localhost:{}\r\n\r\n",
        address.port()
    )
    .unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    service.shared.enabled.store(false, Ordering::Release);
    service.listener.join().unwrap();
    fs::remove_dir_all(directory).unwrap();
    assert!(response.starts_with("HTTP/1.1 401"), "{response}");
    assert!(response.contains("Cache-Control: no-store"));
    assert!(response.contains("Pair this browser"));
}

#[test]
fn host_cookie_identity_starts_with_remote_access_disabled() {
    let service = RemoteAccessService::new(Arc::new(TestHost), identity())
        .expect("valid host cookie identity");
    let status = service
        .manage(&crate::Request {
            method: "GET".into(),
            path: "/v1/remote-access".into(),
            body: vec![],
        })
        .unwrap();
    assert_eq!(status, json!({"enabled": false, "devices": []}));
    for cookie_name in [
        "fritz",
        "__Host-",
        "__Host-fritz; other=value",
        "__Host-fritz\r\n",
    ] {
        assert!(
            RemoteAccessService::new(
                Arc::new(TestHost),
                Identity {
                    cookie_name: cookie_name.into(),
                    request_header: "x-fritz-request".into(),
                }
            )
            .is_err()
        );
    }
}

#[test]
fn management_preserves_missing_certificate_io_errors() {
    let service = RemoteAccessService::new(Arc::new(TestHost), identity()).unwrap();
    let missing = env::temp_dir().join(format!("fritz-missing-certificate-{}", Uuid::new_v4()));
    let error = service
        .manage(&crate::Request {
            method: "POST".into(),
            path: "/v1/remote-access/enable".into(),
            body: json!({"bind":"127.0.0.1:17443", "origin":"https://localhost:17443",
            "certificate":missing, "private_key":missing})
            .to_string()
            .into_bytes(),
        })
        .unwrap_err();
    assert!(matches!(error, Error::Io(ref error) if error.kind() == io::ErrorKind::NotFound));
}
