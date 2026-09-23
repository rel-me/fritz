//! External-crate tests: use only APIs available to another application's Cargo dependency.
use fritz::{
    config::{Connection, ProviderKind, RegistryStore},
    local::{inference::Engine, models::ModelStore},
};

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
