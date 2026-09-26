//! External-crate tests: use only APIs available to another application's Cargo dependency.
use fritz::{
    config::{Connection, ProviderKind, RegistryStore},
    local::{inference::Engine, models::ModelStore},
};

#[tokio::test]
async fn native_harness_uses_only_host_tools_and_refreshes_them_after_execution() {
    use fritz::harness_core::{Host, ToolCall, ToolDefinition, ToolResult};
    use serde_json::{Value, json};
    use std::{
        io::{Read, Write},
        sync::{
            Mutex,
            atomic::{AtomicUsize, Ordering},
        },
    };

    struct HostTools(AtomicUsize);
    impl Host for HostTools {
        fn tools(&self) -> anyhow::Result<Vec<ToolDefinition>> {
            Ok(if self.0.load(Ordering::SeqCst) == 0 {
                vec![ToolDefinition {
                    name: "host_lookup".into(),
                    description: "Host lookup".into(),
                    parameters: json!({"type":"object","properties":{}}),
                }]
            } else {
                vec![]
            })
        }
        async fn execute(&self, call: &ToolCall) -> anyhow::Result<ToolResult> {
            assert_eq!(call.name, "host_lookup");
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(ToolResult::json(json!({"number":7}), false))
        }
    }
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        for turn in 0..2 {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(std::time::Duration::from_secs(10)))
                .unwrap();
            let mut header = Vec::new();
            let mut byte = [0];
            while !header.ends_with(b"\r\n\r\n") {
                socket.read_exact(&mut byte).unwrap();
                header.push(byte[0]);
            }
            let header = String::from_utf8(header).unwrap().to_lowercase();
            let size: usize = header
                .lines()
                .find_map(|line| line.strip_prefix("content-length:"))
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            let mut body = vec![0; size];
            socket.read_exact(&mut body).unwrap();
            let request: Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(
                request["messages"][0]["content"],
                "Fixture host instructions"
            );
            let frame = if turn == 0 {
                assert_eq!(request["tools"].as_array().unwrap().len(), 1);
                assert_eq!(request["tools"][0]["function"]["name"], "host_lookup");
                json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"host-call","function":{"name":"host_lookup","arguments":"{}"}}]},"finish_reason":"tool_calls"}]})
            } else {
                assert!(request.get("tools").is_none());
                let result = request["messages"].as_array().unwrap().last().unwrap();
                assert_eq!(result["tool_call_id"], "host-call");
                assert_eq!(
                    serde_json::from_str::<Value>(result["content"].as_str().unwrap()).unwrap(),
                    json!({"number":7})
                );
                json!({"choices":[{"delta":{"content":"Host finished"},"finish_reason":"stop"}]})
            };
            let body = format!("data: {frame}\n\ndata: [DONE]\n\n");
            write!(socket, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
        }
    });
    let id = uuid::Uuid::new_v4();
    let host = HostTools(AtomicUsize::new(0));
    let events = Mutex::new(Vec::new());
    let missing = tempfile::tempdir().unwrap();
    fritz::harness::run_with_host(
        fritz::harness::Input {
            connection: Connection {
                id,
                name: "Fixture".into(),
                provider: ProviderKind::OpenaiCompatible,
                base_url: Some(format!("http://{address}/v1")),
                model_id: "fixture".into(),
            },
            request: fritz::provider::ChatRequest {
                connection_id: id.to_string(),
                model: "fixture".into(),
                messages: vec![fritz::provider::Message {
                    role: "user".into(),
                    content: "Look up the number".into(),
                }],
                effort: None,
                speed: None,
                project_path: Some(
                    missing
                        .path()
                        .join("must-not-open")
                        .to_str()
                        .unwrap()
                        .into(),
                ),
                max_turns: 3,
            },
            api_key: None,
        },
        "Fixture host instructions",
        &host,
        &|event| events.lock().unwrap().push(event),
    )
    .await
    .unwrap();
    server.join().unwrap();
    assert_eq!(host.0.load(Ordering::SeqCst), 1);
    assert!(
        events
            .lock()
            .unwrap()
            .iter()
            .any(|event| event["text"] == "Host finished")
    );
}

#[test]
fn host_registries_are_independent_without_global_environment_changes() {
    let root = tempfile::tempdir().unwrap();
    let first = RegistryStore::new(root.path().join("first"));
    let second = RegistryStore::new(root.path().join("second"));
    let id = uuid::Uuid::new_v4();
    first
        .update(|registry| {
            registry.connections.push(Connection {
                id,
                name: "Test".into(),
                provider: ProviderKind::Ollama,
                base_url: None,
                model_id: "test".into(),
            });
            registry.default_connection_id = Some(id);
            Ok(())
        })
        .unwrap();
    assert_eq!(first.load().unwrap().connections.len(), 1);
    assert!(second.load().unwrap().connections.is_empty());
    assert!(root.path().join("second/providers.sqlite").exists());
    assert!(
        first
            .update(|registry| {
                registry.connections.clear();
                anyhow::bail!("abort transaction")
            })
            .is_err()
    );
    assert_eq!(first.load().unwrap().connections.len(), 1);
}

#[tokio::test]
async fn explicit_model_store_never_downloads_during_inventory_or_engine_creation() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("host-data");
    let store = ModelStore::new(&directory);
    let catalog = fritz::local::models::catalog();
    assert!(!catalog.is_empty());
    let inventory = store.inventory().await.unwrap();
    assert_eq!(inventory["models"].as_array().unwrap().len(), catalog.len());
    assert!(
        inventory["models"]
            .as_array()
            .unwrap()
            .iter()
            .all(|m| m["installed"] == false)
    );
    assert!(Engine::installed_in(&store, &catalog[0].id).await.is_err());
    assert!(store.inventory_model("unknown").await.is_err());
    assert!(!directory.exists());
}

#[tokio::test]
async fn explicit_discovery_uses_the_supplied_key_without_a_registry_or_keychain() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .unwrap();
        let mut request = Vec::new();
        let mut byte = [0];
        while !request.ends_with(b"\r\n\r\n") {
            socket.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
        }
        let request = String::from_utf8(request).unwrap().to_lowercase();
        assert!(request.contains("authorization: bearer fixture-key"));
        let body = r#"{"data":[{"id":"library-test"}]}"#;
        write!(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
    });
    let models = fritz::provider::discover_with_key(
        &Connection {
            id: uuid::Uuid::new_v4(),
            name: "Fixture".into(),
            provider: ProviderKind::OpenaiCompatible,
            base_url: Some(format!("http://{address}/v1")),
            model_id: String::new(),
        },
        Some("fixture-key"),
    )
    .await
    .unwrap();
    server.join().unwrap();
    assert_eq!(models[0].id, "library-test");
}
