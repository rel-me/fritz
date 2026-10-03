//! One-time, restart-safe import from a host application's former provider storage.
//! Only credential references cross the app protocol. Rust performs Keychain copies.

use super::*;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialSource {
    pub service: String,
    pub account: Uuid,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationItem {
    pub connection: Connection,
    pub credential_source: Option<CredentialSource>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationRequest {
    pub migration_id: String,
    pub providers: Vec<MigrationItem>,
    pub default_connection_id: Option<Uuid>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationResult {
    pub connection_ids: HashMap<Uuid, Uuid>,
}

impl RegistryStore {
    /// Retrieve the committed mapping without reopening the former storage.
    pub fn migration_result(&self, migration_id: &str) -> Result<Option<MigrationResult>> {
        validate_identity(migration_id)?;
        self.transaction(|transaction| read_migration(transaction, migration_id))
    }
    /// Preserves configured destination connections and credentials. Metadata and
    /// completion commit together. A failed Keychain copy leaves the source intact
    /// and can be retried; already copied destination keys are never overwritten.
    #[cfg(target_os = "macos")]
    pub fn migrate(
        &self,
        request: MigrationRequest,
        credentials: &CredentialStore,
    ) -> Result<MigrationResult> {
        self.migrate_with(request, |source, target| {
            if credentials.key(target)?.is_none()
                && let Some(key) = CredentialStore::new(&source.service)?.key(source.account)?
            {
                credentials.set_key(target, &key)?;
            }
            Ok(())
        })
    }

    fn migrate_with(
        &self,
        request: MigrationRequest,
        mut copy_credential: impl FnMut(&CredentialSource, Uuid) -> Result<()>,
    ) -> Result<MigrationResult> {
        validate_identity(&request.migration_id)?;
        self.transaction(|transaction| {
            if let Some(completed) = read_migration(transaction, &request.migration_id)? {
                return Ok(completed);
            }
            let mut registry = read_registry(transaction)?;
            let existing_ids: HashSet<_> = registry.connections.iter().map(|c| c.id).collect();
            let mut identities = HashSet::new();
            let mut connection_ids = HashMap::new();
            // Plan and validate all entries before any credential or registry write.
            for item in &request.providers {
                let connection = &item.connection;
                connection.validate()?;
                if !identities.insert(connection.id) {
                    bail!("Duplicate provider identity in migration.");
                }
                if let Some(source) = &item.credential_source
                    && (connection.provider.is_native() || source.service.is_empty()
                        || source.service.len() > 200
                        || !source.service.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-'))) {
                        bail!("Invalid provider credential reference.");
                }
                let target = if let Some(existing) = registry.connections.iter().find(|c| c.id == connection.id) {
                    if !existing.has_same_target(connection) {
                        bail!("A migrated provider identity is already used by a different endpoint.");
                    }
                    existing.id
                } else if let Some(existing) = registry.connections.iter().find(|c| c.has_same_target(connection)) {
                    existing.id
                } else {
                    if registry.connections.iter().any(|c| c.name.eq_ignore_ascii_case(&connection.name)) {
                        bail!("A different provider named {} already exists. Rename it before migrating.", connection.name);
                    }
                    registry.connections.push(connection.clone());
                    connection.id
                };
                connection_ids.insert(connection.id, target);
            }
            if let Some(default) = request.default_connection_id {
                let target = connection_ids.get(&default).context("The migration default provider is missing.")?;
                if !registry.connections.iter().any(|c| c.id == *target && c.provider.category() == ModelCategory::Llm) {
                    bail!("Only an LLM provider can be the migrated default.");
                }
                if registry.default_connection_id.is_none() {
                    registry.default_connection_id = Some(*target);
                    // Former stores may have one record per model at the same
                    // endpoint. Preserve the selected model when consolidating
                    // those records, without changing an existing connection.
                    if !existing_ids.contains(target) {
                        let preferred = &request.providers.iter().find(|item| item.connection.id == default).unwrap().connection;
                        registry.connections.iter_mut().find(|c| c.id == *target).unwrap().model_id = preferred.model_id.clone();
                    }
                }
            }
            if registry.default_connection_id.is_none() {
                registry.default_connection_id = registry.connections.iter().find(|c| c.provider.category() == ModelCategory::Llm).map(|c| c.id);
            }
            for item in &request.providers {
                if let Some(source) = &item.credential_source {
                    copy_credential(source, connection_ids[&item.connection.id])?;
                }
            }
            write_registry(transaction, &registry)?;
            let result = MigrationResult { connection_ids };
            transaction.execute("INSERT INTO provider_migrations VALUES (?1, ?2)", params![request.migration_id, serde_json::to_string(&result)?])?;
            Ok(result)
        })
    }
}

fn validate_identity(id: &str) -> Result<()> {
    if id.trim().is_empty() || id.len() > 200 {
        bail!("A migration identity of at most 200 bytes is required.");
    }
    Ok(())
}

fn read_migration(database: &rusqlite::Connection, id: &str) -> Result<Option<MigrationResult>> {
    use rusqlite::OptionalExtension;
    let payload: Option<String> = database
        .query_row(
            "SELECT payload FROM provider_migrations WHERE id = ?1",
            [id],
            |row| row.get(0),
        )
        .optional()?;
    payload
        .map(|value| {
            serde_json::from_str(&value).context("Could not read the provider migration mapping.")
        })
        .transpose()
}

#[cfg(target_os = "macos")]
pub fn migrate(request: MigrationRequest) -> Result<MigrationResult> {
    RegistryStore::new(data_dir()).migrate(request, &CredentialStore::new(keychain_service())?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_failure_rolls_back_records_and_completion_then_allows_retry() {
        let directory = tempfile::tempdir().unwrap();
        let store = RegistryStore::new(directory.path());
        let providers: Vec<_> = (0..2)
            .map(|index| {
                let id = Uuid::new_v4();
                MigrationItem {
                    connection: Connection {
                        id,
                        name: format!("Test {index}"),
                        provider: ProviderKind::OpenaiCompatible,
                        base_url: Some(format!("http://localhost:{}/v1", 1234 + index)),
                        model_id: "fixture".into(),
                    },
                    credential_source: Some(CredentialSource {
                        service: "test.credentials".into(),
                        account: id,
                    }),
                }
            })
            .collect();
        let request = MigrationRequest {
            migration_id: "retry-fixture".into(),
            default_connection_id: Some(providers[1].connection.id),
            providers,
        };
        let mut copies = 0;
        assert!(
            store
                .migrate_with(request.clone(), |_, _| {
                    copies += 1;
                    if copies == 2 {
                        bail!("Synthetic credential storage failure");
                    }
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(copies, 2);
        assert!(store.load().unwrap().connections.is_empty());
        let database = provider_database(directory.path()).unwrap();
        assert_eq!(
            database
                .connection()
                .query_row("SELECT count(*) FROM provider_migrations", [], |row| row
                    .get::<_, usize>(
                    0
                ))
                .unwrap(),
            0
        );
        let result = store.migrate_with(request.clone(), |_, _| Ok(())).unwrap();
        assert_eq!(
            store.load().unwrap().default_connection_id,
            request.default_connection_id
        );
        assert_eq!(store.load().unwrap().connections.len(), 2);
        // Completed migrations no longer touch credentials, even after reopening.
        let reopened = RegistryStore::new(directory.path());
        let repeated = reopened
            .migrate_with(request, |_, _| bail!("Must not read source again"))
            .unwrap();
        assert_eq!(repeated.connection_ids, result.connection_ids);
    }
}
