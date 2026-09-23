//! Host-owned SQLite connections and ordered, transactional schema migrations.
//! Adapted from REL's agent/database.rs and agent/migrations.rs.
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, TransactionBehavior};
use std::{
    collections::HashSet,
    fs,
    path::Path,
    time::{Duration, Instant},
};

pub use rusqlite;

pub struct Database {
    connection: Connection,
}

impl Database {
    /// Opens a host-selected file. Migration index + 1 is its SQLite user_version.
    /// Unknown/newer schemas and failed upgrades are preserved, never reset.
    pub fn open(path: &Path, migrations: &[&str], schema: &[(&str, &[&str])]) -> Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)?;
        }
        let mut options = fs::OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(path)?;
        private_permissions(path)?;
        let mut connection = Connection::open(path).context("Could not open state database.")?;
        enable_wal(&connection)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL; PRAGMA wal_autocheckpoint = 1000; PRAGMA journal_size_limit = 67108864;")?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let version: usize = transaction.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version > migrations.len() {
            bail!("State database is newer than this build supports.");
        }
        if version == 0 && !tables(&transaction)?.is_empty() {
            bail!("Unversioned state database is not supported.");
        }
        for (index, migration) in migrations.iter().enumerate().skip(version) {
            transaction.execute_batch(migration)?;
            transaction.pragma_update(None, "user_version", index + 1)?;
        }
        validate(&transaction, schema)?;
        transaction.commit()?;
        for suffix in ["-wal", "-shm"] {
            let mut sidecar = path.as_os_str().to_owned();
            sidecar.push(suffix);
            let sidecar = Path::new(&sidecar);
            if sidecar.exists() {
                private_permissions(sidecar)?;
            }
        }
        Ok(Self { connection })
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub fn transaction<T>(
        &mut self,
        body: impl FnOnce(&rusqlite::Transaction<'_>) -> Result<T>,
    ) -> Result<T> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let value = body(&transaction)?;
        transaction.commit()?;
        Ok(value)
    }
}

fn enable_wal(connection: &Connection) -> Result<()> {
    // SQLite may skip its busy handler during a journal-mode lock upgrade.
    // Retry only this idempotent statement, dropping each failed statement.
    connection.busy_timeout(Duration::ZERO)?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match connection.query_row("PRAGMA journal_mode = WAL", [], |row| {
            row.get::<_, String>(0)
        }) {
            Ok(mode) if mode.eq_ignore_ascii_case("wal") => return Ok(()),
            Ok(_) => bail!("Could not enable state database WAL mode."),
            Err(error)
                if error.sqlite_error_code() == Some(rusqlite::ErrorCode::DatabaseBusy)
                    && Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn private_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn tables(connection: &Connection) -> Result<HashSet<String>> {
    Ok(connection
        .prepare(
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )?
        .query_map([], |row| row.get(0))?
        .collect::<rusqlite::Result<_>>()?)
}

fn validate(connection: &Connection, schema: &[(&str, &[&str])]) -> Result<()> {
    let expected: HashSet<String> = schema.iter().map(|(name, _)| (*name).into()).collect();
    if tables(connection)? != expected {
        bail!("State database contains missing or unsupported tables.");
    }
    for (name, required) in schema {
        let columns: HashSet<String> = connection
            .prepare("SELECT name FROM pragma_table_info(?1)")?
            .query_map([name], |row| row.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        if required.iter().any(|column| !columns.contains(*column)) {
            bail!("State database is missing required columns in {name}.");
        }
    }
    if connection
        .prepare("PRAGMA foreign_key_check")?
        .query([])?
        .next()?
        .is_some()
    {
        bail!("State database contains invalid references.");
    }
    let check: String = connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if check != "ok" {
        bail!("State database failed its integrity check.");
    }
    Ok(())
}
