use fritz::state::rusqlite::Connection;
use fritz::{config::RegistryStore, state::Database};

const INITIAL: &str = "CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT NOT NULL);";
const SCHEMA: &[(&str, &[&str])] = &[("records", &["id", "value"])];

#[test]
fn migrations_are_atomic_and_newer_schemas_are_preserved() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state.sqlite");
    let database = Database::open(&path, &[INITIAL], SCHEMA).unwrap();
    database
        .connection()
        .execute("INSERT INTO records VALUES (1, ?1)", ["private ' 🦊"])
        .unwrap();
    assert!(
        Database::open(
            &path,
            &[
                INITIAL,
                "ALTER TABLE records ADD COLUMN extra TEXT; INSERT INTO missing VALUES (1);"
            ],
            SCHEMA
        )
        .is_err()
    );
    let version: u32 = database
        .connection()
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 1);
    let upgraded = Database::open(
        &path,
        &[INITIAL, "ALTER TABLE records ADD COLUMN extra TEXT;"],
        &[("records", &["id", "value", "extra"])],
    )
    .unwrap();
    assert!(Database::open(&path, &[INITIAL], SCHEMA).is_err());
    let value: String = upgraded
        .connection()
        .query_row("SELECT value FROM records", [], |r| r.get(0))
        .unwrap();
    assert_eq!(value, "private ' 🦊");
}

#[test]
fn failed_transaction_and_invalid_schema_do_not_reset_state() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state.sqlite");
    let mut database = Database::open(&path, &[INITIAL], SCHEMA).unwrap();
    let result: anyhow::Result<()> = database.transaction(|transaction| {
        transaction.execute("INSERT INTO records VALUES (1, 'test')", [])?;
        anyhow::bail!("abort")
    });
    assert!(result.is_err());
    let count: usize = database
        .connection()
        .query_row("SELECT count(*) FROM records", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
    database
        .connection()
        .execute("DROP TABLE records", [])
        .unwrap();
    assert!(Database::open(&path, &[INITIAL], SCHEMA).is_err());
}

#[test]
fn registry_ignores_legacy_files_and_serializes_concurrent_updates() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("providers.json"), "old invalid state").unwrap();
    let store = RegistryStore::new(dir.path());
    assert!(store.load().unwrap().connections.is_empty());
    let threads: Vec<_> = (0..8)
        .map(|index| {
            let store = store.clone();
            std::thread::spawn(move || {
                store
                    .update(|registry| {
                        registry.connections.push(fritz::config::Connection {
                            id: uuid::Uuid::new_v4(),
                            name: format!("Provider {index}"),
                            provider: fritz::config::ProviderKind::Ollama,
                            base_url: None,
                            model_id: String::new(),
                        });
                        Ok(())
                    })
                    .unwrap()
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    assert_eq!(store.load().unwrap().connections.len(), 8);
    assert!(
        store
            .update(|registry| {
                registry.default_connection_id = Some(uuid::Uuid::new_v4());
                Ok(())
            })
            .is_err()
    );
    assert_eq!(store.load().unwrap().connections.len(), 8);
    let connection = Connection::open(dir.path().join("providers.sqlite")).unwrap();
    assert_eq!(
        connection
            .query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
            .unwrap(),
        1
    );
}

#[test]
fn concurrent_first_opens_preserve_every_update() {
    for _ in 0..32 {
        let dir = tempfile::tempdir().unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let threads: Vec<_> = (0..8)
            .map(|index| {
                let path = dir.path().join("state.sqlite");
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    let mut database = Database::open(&path, &[INITIAL], SCHEMA).unwrap();
                    database
                        .transaction(|tx| {
                            tx.execute("INSERT INTO records VALUES (?1, 'value')", [index])?;
                            Ok(())
                        })
                        .unwrap();
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        let database =
            Database::open(&dir.path().join("state.sqlite"), &[INITIAL], SCHEMA).unwrap();
        assert_eq!(
            database
                .connection()
                .query_row("SELECT count(*) FROM records", [], |row| row
                    .get::<_, usize>(0))
                .unwrap(),
            8
        );
    }
}
