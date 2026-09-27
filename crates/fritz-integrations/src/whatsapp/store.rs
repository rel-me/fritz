// Adapted from whatsapp-rust's in-memory reference backend at 3a08e84e.
// Copyright (c) João Lucas de Oliveira Lopes. MIT; see THIRD_PARTY_LICENSE.txt.
// Protocol indexing/retention follows upstream. Mutations commit a candidate to
// macOS Keychain before publishing it, so a failed write never advances keys.
use hashbrown::hash_map::Entry;
use hashbrown::{Equivalent, HashMap as HbHashMap, HashSet as HbHashSet};
use std::collections::HashMap;
use std::collections::hash_map::RandomState;
use std::hash::Hash;
use std::sync::Arc;

use async_lock::Mutex;
use async_trait::async_trait;
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use whatsapp_rust::wacore::appstate::hash::HashState;
use whatsapp_rust::wacore::appstate::processor::AppStateMutationMAC;
use whatsapp_rust::wacore::store::Device;
use whatsapp_rust::wacore::store::error::{Result, StoreError};
use whatsapp_rust::wacore::store::traits::*;

/// Key for the sent-message store: `(chat_jid, message_id)`.
type SentMessageKey = (String, String);

/// Value stored alongside a sent message (includes timestamp for expiration).
#[derive(Clone, Serialize, Deserialize)]
struct SentMessageEntry {
    payload: Vec<u8>,
    timestamp: i64,
}

/// Key for pre-keys: `id`.
#[derive(Clone, Serialize, Deserialize)]
struct PreKeyEntry {
    record: Bytes,
}

/// Key for base-key collision detection: `(address, message_id)`.
type BaseKeyKey = (String, String);

/// Stored msg-secret value: `(secret_bytes, expires_at_secs, message_ts_secs)`.
type MsgSecretRow = (MessageSecret, i64, i64);

#[derive(Eq, Hash, PartialEq, Clone, Serialize, Deserialize)]
struct MsgSecretKey {
    chat: Arc<str>,
    sender: Arc<str>,
    msg_id: Arc<str>,
}

#[derive(Hash)]
struct MsgSecretKeyRef<'a> {
    chat: &'a str,
    sender: &'a str,
    msg_id: &'a str,
}

impl Equivalent<MsgSecretKey> for MsgSecretKeyRef<'_> {
    fn equivalent(&self, key: &MsgSecretKey) -> bool {
        self.chat == key.chat.as_ref()
            && self.sender == key.sender.as_ref()
            && self.msg_id == key.msg_id.as_ref()
    }
}

type MsgSecretMap = HbHashMap<MsgSecretKey, MsgSecretRow, RandomState>;

/// One logical secret, ignoring which sender alias a row was filed under.
/// Eviction groups by this so a message's aliases are kept or dropped together.
///
/// Only `msg_id` is hashed. A stanza id already names one message across the
/// account, so mixing `chat` into the hash buys no selectivity and doubles the
/// string hashing on a path that runs over every row of the cutoff's tie
/// bucket. `chat` still decides equality, so a collision stays correct.
#[derive(Eq, PartialEq)]
struct MsgGroupKey {
    chat: Arc<str>,
    msg_id: Arc<str>,
}

impl Hash for MsgGroupKey {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.msg_id.hash(state);
    }
}

struct MsgGroupKeyRef<'a> {
    chat: &'a str,
    msg_id: &'a str,
}

impl Hash for MsgGroupKeyRef<'_> {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.msg_id.hash(state);
    }
}

impl Equivalent<MsgGroupKey> for MsgGroupKeyRef<'_> {
    fn equivalent(&self, key: &MsgGroupKey) -> bool {
        self.chat == key.chat.as_ref() && self.msg_id == key.msg_id.as_ref()
    }
}

/// Inner state protected by the mutex.
#[derive(Default, Clone, Serialize, Deserialize)]
struct InMemoryState {
    // --- Signal ---
    identities: HashMap<String, [u8; 32]>,
    sessions: HashMap<String, Bytes>,
    prekeys: HashMap<u32, PreKeyEntry>,
    signed_prekeys: HashMap<u32, Vec<u8>>,
    sender_keys: HashMap<String, Vec<u8>>,

    // --- AppSync ---
    sync_keys: HashMap<Vec<u8>, AppStateSyncKey>,
    latest_sync_key_id: Option<Vec<u8>>,
    versions: HashMap<String, HashState>,
    /// `(collection_name, hex(index_mac))` -> `value_mac`
    mutation_macs: HashMap<(String, Vec<u8>), Vec<u8>>,

    // --- Protocol ---
    /// Unified per-device sender key tracking: group_jid -> (device_jid -> has_key)
    sender_key_devices: HashMap<String, HashMap<String, bool>>,
    lid_mappings: HashMap<String, LidPnMappingEntry>,
    /// Reverse index: phone_number -> lid
    pn_to_lid: HashMap<String, String>,
    /// `(base_key, created_at)`; the timestamp is what the retention sweep
    /// prunes on, mirroring the SQLite column.
    base_keys: HashMap<BaseKeyKey, (Vec<u8>, i64)>,
    /// Keyed by `Arc<str>`, shared with each record's own `user`.
    device_lists: HashMap<Arc<str>, DeviceListRecord>,
    group_metadata: HashMap<String, Vec<u8>>,
    tc_tokens: HashMap<String, TcTokenEntry>,
    sent_messages: HashMap<SentMessageKey, SentMessageEntry>,
    /// Pending inbound durability buffer: (chat, sender, id) -> (message, inserted_at).
    pending_inbound: HashMap<(String, String, String), (Vec<u8>, i64)>,

    // --- MsgSecret ---
    /// `expires_at = 0` means never expire; `message_ts = 0` means the parent
    /// event time is unknown. The keepalive cleanup prunes expired rows.
    msg_secrets: MsgSecretMap,
    /// Map length at which `trim_msg_secrets` is next allowed to do its O(n)
    /// evictable-row scan. Purely an optimisation: a stale value can only cause
    /// an extra scan, never a missed eviction.
    msg_secrets_rescan_at: usize,

    // --- Device ---
    #[serde(with = "device_json")]
    device: Option<Device>,
}

// Upstream Device's key-pair codec serializes bytes but deserializes Vec<u8>.
// JSON represents both as arrays; embedding it keeps the durable CBOR container
// compatible without changing or forking the upstream cryptographic types.
mod device_json {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        device: &Option<Device>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        device
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(serde::ser::Error::custom)?
            .serialize(serializer)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Option<Device>, D::Error> {
        Option::<String>::deserialize(deserializer)?
            .map(|json| serde_json::from_str(&json))
            .transpose()
            .map_err(serde::de::Error::custom)
    }
}

/// Hard cap on retained sent messages, bounding memory regardless of the
/// configured retention window. Time-based pruning is the client's keepalive
/// sweep (`delete_expired_sent_messages`, driven by
/// `CacheConfig::sent_message_ttl_secs`, the single source of truth for the
/// time window); this cap only guards against a burst between sweeps.
const MAX_SENT_MESSAGES: usize = 4096;

/// Hard cap on retained message secrets, the `msg_secrets` counterpart of
/// [`MAX_SENT_MESSAGES`] and there for the same reason: time-based pruning
/// (`delete_expired_msg_secrets`, driven by the client's keepalive sweep)
/// cannot reclaim anything inside a session, because the default `Managed`
/// policy dates every row 30-90 days out. Without a cap the map is one row per
/// message for the life of the process.
///
/// That is a footprint bug specifically on wasm32, where the allocator never
/// returns pages: the table doubles by reallocation, so the old and the new
/// table are briefly live together, and the ~1.5x spike stays committed in
/// linear memory even after the rows are dropped. A 30k-message session
/// reallocated this table to 4.56 MiB (65536 buckets x 73 B) and committed
/// ~7 MiB it never gave back.
///
/// Sized at 2x [`MAX_SENT_MESSAGES`] and 2x the client's message-secret
/// write-behind high-water mark, so a burst that fills both still fits.
const MAX_MSG_SECRETS: usize = 8192;

/// Serialized snapshots live exclusively in the worktree-specific macOS Keychain.
/// Failed writes leave the previously committed state intact.
pub struct KeychainBackend {
    state: Mutex<InMemoryState>,
    service: String,
    closed: std::sync::atomic::AtomicBool,
}

impl KeychainBackend {
    pub fn open(service: String) -> Result<Self> {
        let state =
            match security_framework::passwords::get_generic_password(&service, "session-v1") {
                Ok(bytes) => serde_cbor::from_slice(&bytes).map_err(|_| {
                    StoreError::Validation("Saved WhatsApp connection is invalid.".into())
                })?,
                Err(error) if error.code() == security_framework_sys::base::errSecItemNotFound => {
                    InMemoryState::default()
                }
                Err(_) => {
                    return Err(StoreError::Validation(
                        "Could not read WhatsApp connection from Keychain.".into(),
                    ));
                }
            };
        Ok(Self {
            state: Mutex::new(state),
            service,
            closed: std::sync::atomic::AtomicBool::new(false),
        })
    }

    pub async fn close(&self) {
        let _guard = self.state.lock().await;
        self.closed.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    async fn transact<T: Send>(
        &self,
        change: impl FnOnce(&mut InMemoryState) -> Result<T> + Send,
    ) -> Result<T> {
        let mut committed = self.state.lock().await;
        let mut candidate = committed.clone();
        let result = change(&mut candidate)?;
        self.persist(&candidate).await?;
        *committed = candidate;
        Ok(result)
    }

    async fn persist(&self, state: &InMemoryState) -> Result<()> {
        if self.closed.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(StoreError::Validation(
                "WhatsApp connection is closed.".into(),
            ));
        }
        let bytes = serde_cbor::to_vec(state)
            .map_err(|_| StoreError::Validation("Could not encode WhatsApp connection.".into()))?;
        if bytes.len() > 16 * 1024 * 1024 {
            return Err(StoreError::Validation(
                "WhatsApp connection exceeded its secure storage limit.".into(),
            ));
        }
        let service = self.service.clone();
        tokio::task::spawn_blocking(move || {
            security_framework::passwords::set_generic_password(&service, "session-v1", &bytes)
        })
        .await
        .map_err(|_| StoreError::Validation("WhatsApp secure storage task failed.".into()))?
        .map_err(|_| {
            StoreError::Validation("Could not save WhatsApp connection in Keychain.".into())
        })
    }
}

// ---------------------------------------------------------------------------
// SignalStore
// ---------------------------------------------------------------------------

#[cfg_attr(target_arch = "wasm32", async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait)]
impl SignalStore for KeychainBackend {
    async fn put_identity(&self, address: &str, key: [u8; 32]) -> Result<()> {
        self.transact(|candidate| {
            candidate.identities.insert(address.to_string(), key);
            Ok(())
        })
        .await
    }

    async fn load_identity(&self, address: &str) -> Result<Option<[u8; 32]>> {
        Ok(self.state.lock().await.identities.get(address).copied())
    }

    async fn delete_identity(&self, address: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.identities.remove(address);
            Ok(())
        })
        .await
    }

    async fn get_session(&self, address: &str) -> Result<Option<Bytes>> {
        Ok(self.state.lock().await.sessions.get(address).cloned())
    }

    /// One lock acquisition for the whole fan-out instead of one per device.
    /// Returns only the addresses that exist, like the default.
    async fn get_sessions_batch(&self, addresses: &[Arc<str>]) -> Result<Vec<(Arc<str>, Bytes)>> {
        let state = self.state.lock().await;
        let mut result = Vec::with_capacity(addresses.len());
        for address in addresses {
            if let Some(session) = state.sessions.get(address.as_ref()) {
                result.push((address.clone(), session.clone()));
            }
        }
        Ok(result)
    }

    async fn put_session(&self, address: &str, session: &[u8]) -> Result<()> {
        self.transact(|candidate| {
            candidate
                .sessions
                .insert(address.to_string(), Bytes::copy_from_slice(session));
            Ok(())
        })
        .await
    }

    async fn put_sessions_batch(&self, sessions: &[(Arc<str>, Bytes)]) -> Result<()> {
        self.transact(|candidate| {
            let state = &mut *candidate;
            state.sessions.reserve(sessions.len());
            for (index, (address, session)) in sessions.iter().enumerate() {
                if let Some(stored) = state.sessions.get_mut(address.as_ref()) {
                    *stored = session.clone();
                } else {
                    state.sessions.insert(address.to_string(), session.clone());
                }
                let _ = index;
            }
            Ok(())
        })
        .await
    }

    async fn has_session(&self, address: &str) -> Result<bool> {
        Ok(self.state.lock().await.sessions.contains_key(address))
    }

    async fn has_signal_state_for_user(&self, user: &str) -> Result<bool> {
        fn matches(addr: &str, user: &str) -> bool {
            addr.strip_prefix(user)
                .is_some_and(|rest| rest.starts_with('@') || rest.starts_with(':'))
        }
        let state = self.state.lock().await;
        Ok(state.sessions.keys().any(|k| matches(k, user))
            || state.identities.keys().any(|k| matches(k, user)))
    }

    async fn delete_session(&self, address: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.sessions.remove(address);
            Ok(())
        })
        .await
    }

    async fn store_prekey(&self, id: u32, record: &[u8], _uploaded: bool) -> Result<()> {
        self.transact(|candidate| {
            candidate.prekeys.insert(
                id,
                PreKeyEntry {
                    record: Bytes::copy_from_slice(record),
                },
            );
            Ok(())
        })
        .await
    }

    async fn mark_prekeys_uploaded(&self, _ids: &[u32]) -> Result<()> {
        // The in-memory store does not track the uploaded flag (see
        // store_prekey); the contract that matters is NOT resurrecting
        // deleted rows, which a no-op trivially satisfies.
        Ok(())
    }

    async fn store_prekeys_batch(&self, keys: &[(u32, Bytes)], _uploaded: bool) -> Result<()> {
        self.transact(|candidate| {
            let state = &mut *candidate;
            // Growing one insert at a time allocates and copies a whole table per
            // rehash, and a connect-sized batch arriving at an empty map crosses
            // the load factor eight times. The batch length is known, so the table
            // can reach its final size in one allocation instead.
            //
            // Two things stop that reservation from over-growing a table, because a
            // table grown for rows that were never added does not shrink back and
            // this is meant to cost no retained bytes:
            //
            // 1. Subtract the rows already stored. A batch may legally overwrite
            //    ids, and no batch can overwrite more rows than exist, so
            //    `keys.len() - len()` is the floor on how many ids must be new.
            // 2. Only reserve at all when the batch is strictly ascending, which
            //    proves its ids are distinct. Without that, 812 entries sharing one
            //    id would reserve a 1024-bucket table to hold a single row. Testing
            //    the order costs one pass of integer compares and no allocation;
            //    deduplicating properly would need a set, whose own allocation and
            //    812 hashes cost more than the eight allocations being saved.
            //
            // Both are one-sided: they can only under-reserve and fall back to
            // incremental growth, never inflate the resident table. The connect path
            // satisfies both — the map is empty and `upload_pre_keys_pass` emits
            // `gen_start + i`, so the whole batch is reserved and gets the full win.
            //
            // This does NOT shrink the table that stays resident: the final
            // capacity is the same either way, so it buys allocator traffic and
            // in-call headroom, not retained bytes.
            let ascending = keys.windows(2).all(|pair| pair[0].0 < pair[1].0);
            if ascending {
                let at_least_new = keys.len().saturating_sub(state.prekeys.len());
                state.prekeys.reserve(at_least_new);
            }
            for (id, record) in keys {
                state.prekeys.insert(
                    *id,
                    PreKeyEntry {
                        record: record.clone(),
                    },
                );
            }
            Ok(())
        })
        .await
    }

    async fn load_prekey(&self, id: u32) -> Result<Option<Bytes>> {
        Ok(self
            .state
            .lock()
            .await
            .prekeys
            .get(&id)
            .map(|e| e.record.clone()))
    }

    async fn load_prekeys_batch(&self, ids: &[u32]) -> Result<Vec<(u32, Bytes)>> {
        let state = self.state.lock().await;
        let mut result = Vec::with_capacity(ids.len());
        for &id in ids {
            if let Some(entry) = state.prekeys.get(&id) {
                result.push((id, entry.record.clone()));
            }
        }
        Ok(result)
    }

    async fn remove_prekey(&self, id: u32) -> Result<()> {
        self.transact(|candidate| {
            candidate.prekeys.remove(&id);
            Ok(())
        })
        .await
    }

    async fn get_max_prekey_id(&self) -> Result<u32> {
        Ok(self
            .state
            .lock()
            .await
            .prekeys
            .keys()
            .copied()
            .max()
            .unwrap_or(0))
    }

    async fn store_signed_prekey(&self, id: u32, record: &[u8]) -> Result<()> {
        self.transact(|candidate| {
            candidate.signed_prekeys.insert(id, record.to_vec());
            Ok(())
        })
        .await
    }

    async fn load_signed_prekey(&self, id: u32) -> Result<Option<Vec<u8>>> {
        Ok(self.state.lock().await.signed_prekeys.get(&id).cloned())
    }

    async fn load_all_signed_prekeys(&self) -> Result<Vec<(u32, Vec<u8>)>> {
        Ok(self
            .state
            .lock()
            .await
            .signed_prekeys
            .iter()
            .map(|(id, rec)| (*id, rec.clone()))
            .collect())
    }

    async fn remove_signed_prekey(&self, id: u32) -> Result<()> {
        self.transact(|candidate| {
            candidate.signed_prekeys.remove(&id);
            Ok(())
        })
        .await
    }

    async fn put_sender_key(&self, address: &str, record: &[u8]) -> Result<()> {
        self.transact(|candidate| {
            candidate
                .sender_keys
                .insert(address.to_string(), record.to_vec());
            Ok(())
        })
        .await
    }

    async fn put_sender_keys_batch(&self, sender_keys: &[(Arc<str>, Bytes)]) -> Result<()> {
        self.transact(|candidate| {
            let state = &mut *candidate;
            state.sender_keys.reserve(sender_keys.len());
            for (address, record) in sender_keys {
                if let Some(stored) = state.sender_keys.get_mut(address.as_ref()) {
                    stored.clear();
                    stored.extend_from_slice(record);
                } else {
                    state
                        .sender_keys
                        .insert(address.to_string(), record.to_vec());
                }
            }
            Ok(())
        })
        .await
    }

    async fn get_sender_key(&self, address: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.state.lock().await.sender_keys.get(address).cloned())
    }

    async fn delete_sender_key(&self, address: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.sender_keys.remove(address);
            Ok(())
        })
        .await
    }
}

// ---------------------------------------------------------------------------
// AppSyncStore
// ---------------------------------------------------------------------------

#[cfg_attr(target_arch = "wasm32", async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait)]
impl AppSyncStore for KeychainBackend {
    async fn get_sync_key(&self, key_id: &[u8]) -> Result<Option<AppStateSyncKey>> {
        Ok(self.state.lock().await.sync_keys.get(key_id).cloned())
    }

    async fn set_sync_key(&self, key_id: &[u8], key: AppStateSyncKey) -> Result<()> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            s.sync_keys.insert(key_id.to_vec(), key);
            s.latest_sync_key_id = Some(key_id.to_vec());
            Ok(())
        })
        .await
    }

    async fn get_version(&self, name: &str) -> Result<Option<HashState>> {
        Ok(self.state.lock().await.versions.get(name).cloned())
    }

    async fn delete_version(&self, name: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.versions.remove(name);
            Ok(())
        })
        .await
    }

    async fn set_version(&self, name: &str, state: HashState) -> Result<()> {
        self.transact(|candidate| {
            candidate.versions.insert(name.to_string(), state);
            Ok(())
        })
        .await
    }

    async fn put_mutation_macs(
        &self,
        name: &str,
        _version: u64,
        mutations: &[AppStateMutationMAC],
    ) -> Result<()> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            for m in mutations {
                s.mutation_macs
                    .insert((name.to_string(), m.index_mac.clone()), m.value_mac.clone());
            }
            Ok(())
        })
        .await
    }

    async fn get_mutation_mac(&self, name: &str, index_mac: &[u8]) -> Result<Option<Vec<u8>>> {
        Ok(self
            .state
            .lock()
            .await
            .mutation_macs
            .get(&(name.to_string(), index_mac.to_vec()))
            .cloned())
    }

    async fn delete_mutation_macs(&self, name: &str, index_macs: &[Vec<u8>]) -> Result<()> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            for im in index_macs {
                s.mutation_macs.remove(&(name.to_string(), im.clone()));
            }
            Ok(())
        })
        .await
    }

    async fn clear_mutation_macs(&self, name: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.mutation_macs.retain(|(n, _), _| n != name);
            Ok(())
        })
        .await
    }

    async fn get_latest_sync_key_id(&self) -> Result<Option<Vec<u8>>> {
        Ok(self.state.lock().await.latest_sync_key_id.clone())
    }
}

// ---------------------------------------------------------------------------
// ProtocolStore
// ---------------------------------------------------------------------------

#[cfg_attr(target_arch = "wasm32", async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait)]
impl ProtocolStore for KeychainBackend {
    // --- Per-Device Sender Key Tracking ---

    async fn get_sender_key_devices(&self, group_jid: &str) -> Result<Vec<(String, bool)>> {
        Ok(self
            .state
            .lock()
            .await
            .sender_key_devices
            .get(group_jid)
            .map(|map| map.iter().map(|(k, v)| (k.clone(), *v)).collect())
            .unwrap_or_default())
    }

    async fn set_sender_key_status(&self, group_jid: &str, entries: &[(&str, bool)]) -> Result<()> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            let map = s
                .sender_key_devices
                .entry(group_jid.to_string())
                .or_default();
            for (device_jid, has_key) in entries {
                map.insert(device_jid.to_string(), *has_key);
            }
            Ok(())
        })
        .await
    }

    async fn clear_sender_key_devices(&self, group_jid: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.sender_key_devices.remove(group_jid);
            Ok(())
        })
        .await
    }

    async fn clear_all_sender_key_devices(&self) -> Result<()> {
        self.transact(|candidate| {
            candidate.sender_key_devices.clear();
            Ok(())
        })
        .await
    }

    async fn delete_sender_key_device_rows(&self, device_jids: &[&str]) -> Result<()> {
        self.transact(|candidate| {
            if device_jids.is_empty() {
                return Ok(());
            }
            let state = &mut *candidate;
            for group_map in state.sender_key_devices.values_mut() {
                group_map.retain(|jid, _| !device_jids.contains(&jid.as_str()));
            }
            Ok(())
        })
        .await
    }

    // --- LID-PN Mapping ---

    async fn get_lid_mapping(&self, lid: &str) -> Result<Option<LidPnMappingEntry>> {
        Ok(self.state.lock().await.lid_mappings.get(lid).cloned())
    }

    async fn get_pn_mapping(&self, phone: &str) -> Result<Option<LidPnMappingEntry>> {
        let s = self.state.lock().await;
        let entry = s
            .pn_to_lid
            .get(phone)
            .and_then(|lid| s.lid_mappings.get(lid))
            .cloned();
        Ok(entry)
    }

    async fn put_lid_mapping(&self, entry: &LidPnMappingEntry) -> Result<()> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            // Remove stale reverse entry if the LID was previously mapped to a different phone number
            if let Some(old_phone) = s
                .lid_mappings
                .get(&entry.lid)
                .filter(|old| old.phone_number != entry.phone_number)
                .map(|old| old.phone_number.clone())
            {
                s.pn_to_lid.remove(&old_phone);
            }
            s.pn_to_lid
                .insert(entry.phone_number.clone(), entry.lid.clone());
            s.lid_mappings.insert(entry.lid.clone(), entry.clone());
            Ok(())
        })
        .await
    }

    async fn get_all_lid_mappings(&self) -> Result<Vec<LidPnMappingEntry>> {
        Ok(self
            .state
            .lock()
            .await
            .lid_mappings
            .values()
            .cloned()
            .collect())
    }

    // --- Base Key Collision Detection ---

    async fn save_base_key(&self, address: &str, message_id: &str, base_key: &[u8]) -> Result<()> {
        self.transact(|candidate| {
            candidate.base_keys.insert(
                (address.to_string(), message_id.to_string()),
                (base_key.to_vec(), whatsapp_rust::wacore::time::now_secs()),
            );
            Ok(())
        })
        .await
    }

    async fn has_same_base_key(
        &self,
        address: &str,
        message_id: &str,
        current_base_key: &[u8],
    ) -> Result<bool> {
        let s = self.state.lock().await;
        let same = s
            .base_keys
            .get(&(address.to_string(), message_id.to_string()))
            .is_some_and(|(stored, _)| stored == current_base_key);
        Ok(same)
    }

    async fn delete_base_key(&self, address: &str, message_id: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate
                .base_keys
                .remove(&(address.to_string(), message_id.to_string()));
            Ok(())
        })
        .await
    }

    async fn delete_expired_base_keys(&self, cutoff_timestamp: i64) -> Result<u32> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            let before = s.base_keys.len();
            s.base_keys
                .retain(|_, (_, created_at)| *created_at >= cutoff_timestamp);
            Ok((before - s.base_keys.len()) as u32)
        })
        .await
    }

    // --- Device Registry ---

    async fn update_device_list(&self, record: DeviceListRecord) -> Result<()> {
        self.transact(|candidate| {
            candidate
                .device_lists
                .insert(Arc::clone(&record.user), record);
            Ok(())
        })
        .await
    }

    async fn get_devices(&self, user: &str) -> Result<Option<DeviceListRecord>> {
        Ok(self.state.lock().await.device_lists.get(user).cloned())
    }

    async fn get_devices_batch(&self, users: &[&str]) -> Result<Vec<DeviceListRecord>> {
        let state = self.state.lock().await;
        Ok(users
            .iter()
            .filter_map(|user| state.device_lists.get(*user).cloned())
            .collect())
    }

    async fn delete_devices(&self, user: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.device_lists.remove(user);
            Ok(())
        })
        .await
    }

    async fn get_group_metadata(&self, group_jid: &str) -> Result<Option<Vec<u8>>> {
        Ok(self
            .state
            .lock()
            .await
            .group_metadata
            .get(group_jid)
            .cloned())
    }

    async fn put_group_metadata(&self, group_jid: &str, blob: &[u8]) -> Result<()> {
        self.transact(|candidate| {
            candidate
                .group_metadata
                .insert(group_jid.to_string(), blob.to_vec());
            Ok(())
        })
        .await
    }

    async fn delete_group_metadata(&self, group_jid: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.group_metadata.remove(group_jid);
            Ok(())
        })
        .await
    }

    // --- TcToken Storage ---

    async fn get_tc_token(&self, jid: &str) -> Result<Option<TcTokenEntry>> {
        Ok(self.state.lock().await.tc_tokens.get(jid).cloned())
    }

    async fn put_tc_token(&self, jid: &str, entry: &TcTokenEntry) -> Result<()> {
        self.transact(|candidate| {
            candidate.tc_tokens.insert(jid.to_string(), entry.clone());
            Ok(())
        })
        .await
    }

    async fn delete_tc_token(&self, jid: &str) -> Result<()> {
        self.transact(|candidate| {
            candidate.tc_tokens.remove(jid);
            Ok(())
        })
        .await
    }

    async fn get_all_tc_token_jids(&self) -> Result<Vec<String>> {
        Ok(self.state.lock().await.tc_tokens.keys().cloned().collect())
    }

    async fn delete_expired_tc_tokens(&self, token_cutoff: i64, sender_cutoff: i64) -> Result<u32> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            let before = s.tc_tokens.len();
            // Keep a row while either window is still live: the received token or the
            // sender bucket. A row is dropped only when both are stale.
            s.tc_tokens.retain(|_, entry| {
                let token_live = !entry.token.is_empty() && entry.token_timestamp >= token_cutoff;
                let sender_live = entry.sender_timestamp.is_some_and(|ts| ts >= sender_cutoff);
                token_live || sender_live
            });
            Ok((before - s.tc_tokens.len()) as u32)
        })
        .await
    }

    async fn touch_tc_token_sender_timestamp(
        &self,
        jid: &str,
        sender_timestamp: i64,
    ) -> Result<()> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            match s.tc_tokens.get_mut(jid) {
                Some(entry) => {
                    entry.sender_timestamp = Some(
                        entry
                            .sender_timestamp
                            .map_or(sender_timestamp, |e| e.max(sender_timestamp)),
                    );
                }
                None => {
                    s.tc_tokens.insert(
                        jid.to_string(),
                        TcTokenEntry {
                            token: Vec::new(),
                            token_timestamp: sender_timestamp,
                            sender_timestamp: Some(sender_timestamp),
                        },
                    );
                }
            }
            Ok(())
        })
        .await
    }

    async fn store_received_tc_token(
        &self,
        jid: &str,
        token: &[u8],
        token_timestamp: i64,
    ) -> Result<()> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            match s.tc_tokens.get_mut(jid) {
                Some(entry) => {
                    // Newer-wins (see the trait doc): don't let a stale write
                    // clobber a fresher token.
                    if entry.token.is_empty() || token_timestamp >= entry.token_timestamp {
                        entry.token = token.to_vec();
                        entry.token_timestamp = token_timestamp;
                        // sender_timestamp left untouched
                    }
                }
                None => {
                    s.tc_tokens.insert(
                        jid.to_string(),
                        TcTokenEntry {
                            token: token.to_vec(),
                            token_timestamp,
                            sender_timestamp: None,
                        },
                    );
                }
            }
            Ok(())
        })
        .await
    }

    // --- Sent Message Store ---

    async fn store_sent_message(
        &self,
        chat_jid: &str,
        message_id: &str,
        payload: &[u8],
    ) -> Result<()> {
        self.transact(|candidate| {
            let now = whatsapp_rust::wacore::time::now_secs();
            let s = &mut *candidate;

            // Memory bound only: when the map hits the cap, drop the oldest entries
            // (by timestamp) down to 3/4 of it so this scan amortizes across many
            // inserts. Time-based pruning is the caller's keepalive sweep.
            //
            // Only the timestamps are collected: cloning every key to sort them
            // allocated two Strings per retained entry on each eviction (4096 keys
            // per 1024 inserts under load) while holding the state lock, which
            // showed up both as per-message churn and as a latency spike.
            // `select_nth_unstable` finds the cutoff in O(n) without ordering the
            // rest, then two passes apply it: everything strictly older goes, and
            // the cutoff's own bucket tops the removal up to the exact count. The
            // split is what keeps the policy oldest-first, since map iteration
            // order is arbitrary and a single pass could evict an entry AT the
            // cutoff while keeping one below it. The exact count matters because a
            // flood puts every entry in the same second: with one bucket for the
            // whole map, dropping all of "timestamp <= cutoff" would clear it.
            if s.sent_messages.len() >= MAX_SENT_MESSAGES {
                let target = MAX_SENT_MESSAGES * 3 / 4;
                let drop_count = s.sent_messages.len().saturating_sub(target);
                if drop_count > 0 {
                    let mut ages: Vec<i64> =
                        s.sent_messages.values().map(|e| e.timestamp).collect();
                    let (_, &mut cutoff, _) = ages.select_nth_unstable(drop_count - 1);
                    let mut removed = 0usize;
                    s.sent_messages.retain(|_, e| {
                        if e.timestamp < cutoff {
                            removed += 1;
                            false
                        } else {
                            true
                        }
                    });
                    let mut remaining = drop_count.saturating_sub(removed);
                    if remaining > 0 {
                        s.sent_messages.retain(|_, e| {
                            if remaining > 0 && e.timestamp == cutoff {
                                remaining -= 1;
                                false
                            } else {
                                true
                            }
                        });
                    }
                }
            }

            s.sent_messages.insert(
                (chat_jid.to_string(), message_id.to_string()),
                SentMessageEntry {
                    payload: payload.to_vec(),
                    timestamp: now,
                },
            );
            Ok(())
        })
        .await
    }

    async fn get_sent_message(&self, chat_jid: &str, message_id: &str) -> Result<Option<Vec<u8>>> {
        Ok(self
            .state
            .lock()
            .await
            .sent_messages
            .get(&(chat_jid.to_string(), message_id.to_string()))
            .map(|e| e.payload.clone()))
    }

    async fn take_sent_message(&self, chat_jid: &str, message_id: &str) -> Result<Option<Vec<u8>>> {
        self.transact(|candidate| {
            Ok(candidate
                .sent_messages
                .remove(&(chat_jid.to_string(), message_id.to_string()))
                .map(|e| e.payload))
        })
        .await
    }

    async fn delete_expired_sent_messages(&self, cutoff_timestamp: i64) -> Result<u32> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            let before = s.sent_messages.len();
            s.sent_messages
                .retain(|_, entry| entry.timestamp >= cutoff_timestamp);
            Ok((before - s.sent_messages.len()) as u32)
        })
        .await
    }

    async fn store_pending_inbound(
        &self,
        chat: &str,
        sender: &str,
        id: &str,
        message: &[u8],
    ) -> Result<()> {
        self.transact(|candidate| {
            let now = whatsapp_rust::wacore::time::now_secs();
            candidate.pending_inbound.insert(
                (chat.to_string(), sender.to_string(), id.to_string()),
                (message.to_vec(), now),
            );
            Ok(())
        })
        .await
    }

    async fn get_pending_inbound(
        &self,
        chat: &str,
        sender: &str,
        id: &str,
    ) -> Result<Option<Vec<u8>>> {
        let key = (chat.to_string(), sender.to_string(), id.to_string());
        Ok(self
            .state
            .lock()
            .await
            .pending_inbound
            .get(&key)
            .map(|(bytes, _)| bytes.clone()))
    }

    async fn delete_pending_inbound(&self, chat: &str, sender: &str, id: &str) -> Result<()> {
        self.transact(|candidate| {
            let key = (chat.to_string(), sender.to_string(), id.to_string());
            candidate.pending_inbound.remove(&key);
            Ok(())
        })
        .await
    }

    async fn delete_expired_pending_inbound(&self, cutoff_timestamp: i64) -> Result<u32> {
        self.transact(|candidate| {
            let s = &mut *candidate;
            let before = s.pending_inbound.len();
            s.pending_inbound
                .retain(|_, (_, inserted_at)| *inserted_at >= cutoff_timestamp);
            Ok((before - s.pending_inbound.len()) as u32)
        })
        .await
    }
}

// ---------------------------------------------------------------------------
// MsgSecretStore
// ---------------------------------------------------------------------------

#[cfg_attr(target_arch = "wasm32", async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait)]
impl MsgSecretStore for KeychainBackend {
    async fn put_msg_secrets(&self, mut entries: Vec<MsgSecretEntry>) -> Result<usize> {
        self.transact(|candidate| {
            use whatsapp_rust::wacore::store::traits::{
                merge_msg_secret_expiry, merge_msg_secret_message_ts,
            };
            let stored = entries.len();
            // Only a batch long enough to be chunked below can have a chunk boundary
            // fall inside a message, and only then does the order matter. Sorting
            // groups a message's sender alias rows together so the boundary check
            // can see them: the client's write-behind buffer snapshots its pending
            // set from a `HashMap`, so the aliases it queued back to back reach the
            // store scattered. In place, so this costs no allocation on the one
            // path -- a history-sync seed -- that is ever long enough to reach it.
            if stored > MAX_MSG_SECRETS / 4 {
                entries.sort_unstable_by(|a, b| {
                    (a.chat.as_ref(), a.msg_id.as_ref()).cmp(&(b.chat.as_ref(), b.msg_id.as_ref()))
                });
            }
            let state = &mut *candidate;
            // Initial history batches are overwhelmingly new rows, so reserve
            // once. Once populated, a batch may be mostly overwrites; reserving its
            // full length then would grow the table without adding any rows.
            // Clamped to the cap: a seed batch larger than it would otherwise size
            // the table for rows this store is about to evict anyway.
            if state.msg_secrets.is_empty() {
                state.msg_secrets.reserve(stored.min(MAX_MSG_SECRETS));
            }
            // Evict between chunks rather than once at the end. A batch bigger than
            // the cap -- a history-sync seed goes straight to the backend, skipping
            // the write-behind buffer's own high-water mark -- would otherwise be
            // inserted whole, and by the time the eviction ran the table would
            // already have doubled past the bound. `retain` frees rows but not the
            // allocation, and on wasm32 that allocation is never returned, so the
            // footprint bound has to hold going up, not just coming down.
            let mut entries = entries.into_iter().peekable();
            loop {
                let mut inserted = 0usize;
                while let Some(entry) = entries.next() {
                    inserted += 1;
                    // The chunk boundary must not fall between a message's sender
                    // alias rows. Eviction runs as soon as the chunk closes, and it
                    // would see the first alias with the second not yet inserted --
                    // free to drop the one it can see, after which the other lands
                    // and survives alone. That is the identity-dependent decryption
                    // failure the grouping in `trim_msg_secrets` exists to prevent,
                    // reintroduced one level up. The sort above put a message's rows
                    // next to each other, so holding the chunk open while the next
                    // entry names the same message is enough.
                    let boundary_group = (inserted >= MAX_MSG_SECRETS / 4)
                        .then(|| (Arc::clone(&entry.chat), Arc::clone(&entry.msg_id)));
                    let key = MsgSecretKey {
                        chat: entry.chat,
                        sender: entry.sender,
                        msg_id: entry.msg_id,
                    };
                    match state.msg_secrets.entry(key) {
                        Entry::Occupied(mut occupied) => {
                            let (secret, expires_at, message_ts) = occupied.get_mut();
                            *secret = entry.secret;
                            *expires_at = merge_msg_secret_expiry(*expires_at, entry.expires_at);
                            *message_ts =
                                merge_msg_secret_message_ts(*message_ts, entry.message_ts);
                        }
                        Entry::Vacant(vacant) => {
                            vacant.insert((entry.secret, entry.expires_at, entry.message_ts));
                        }
                    }
                    if let Some((chat, msg_id)) = boundary_group
                        && !entries
                            .peek()
                            .is_some_and(|next| next.chat == chat && next.msg_id == msg_id)
                    {
                        break;
                    }
                }
                if inserted == 0 {
                    break;
                }
                let state = &mut *state;
                trim_msg_secrets(&mut state.msg_secrets, &mut state.msg_secrets_rescan_at);
            }
            Ok(stored)
        })
        .await
    }

    async fn get_msg_secret(
        &self,
        chat: &str,
        sender: &str,
        msg_id: &str,
    ) -> Result<Option<Vec<u8>>> {
        Ok(self
            .get_msg_secret_with_ts(chat, sender, msg_id)
            .await?
            .map(|(secret, _)| secret))
    }

    async fn get_msg_secret_with_ts(
        &self,
        chat: &str,
        sender: &str,
        msg_id: &str,
    ) -> Result<Option<(Vec<u8>, i64)>> {
        Ok(self
            .state
            .lock()
            .await
            .msg_secrets
            .get(&MsgSecretKeyRef {
                chat,
                sender,
                msg_id,
            })
            .map(|(secret, _, message_ts)| (secret.to_vec(), *message_ts)))
    }

    async fn delete_expired_msg_secrets(&self, cutoff_timestamp: i64) -> Result<u32> {
        self.transact(|candidate| {
            let state = &mut *candidate;
            let before = state.msg_secrets.len();
            // Keep rows with no deadline (0 = never) or a deadline still in the future.
            state
                .msg_secrets
                .retain(|_, (_, expires_at, _)| *expires_at == 0 || *expires_at > cutoff_timestamp);
            Ok((before - state.msg_secrets.len()) as u32)
        })
        .await
    }
}

// ---------------------------------------------------------------------------
// DeviceStore
// ---------------------------------------------------------------------------

#[cfg_attr(target_arch = "wasm32", async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait)]
impl DeviceStore for KeychainBackend {
    async fn save(&self, device: &Device) -> Result<()> {
        self.transact(|candidate| {
            candidate.device = Some(device.clone());
            Ok(())
        })
        .await
    }

    async fn load(&self) -> Result<Option<Device>> {
        Ok(self.state.lock().await.device.clone())
    }

    async fn exists(&self) -> Result<bool> {
        Ok(self.state.lock().await.device.is_some())
    }

    async fn create(&self) -> Result<i32> {
        self.transact(|candidate| {
            let id = 1;
            // Materialize a default Device so that `exists()` returns true after `create()`.
            let state = &mut *candidate;
            if state.device.is_none() {
                state.device = Some(Device::new());
            }
            Ok(id)
        })
        .await
    }
}

/// Drop the soonest-to-expire secrets once the map exceeds
/// [`MAX_MSG_SECRETS`], down to 3/4 of the cap so the scan amortizes across
/// many inserts (same shape as `store_sent_message`'s eviction).
///
/// Ordering by `expires_at` rather than by insertion evicts the row closest to
/// being pruned anyway, which also keeps the longer horizons: a poll/event
/// secret (90 days) outlives a text secret (30 days) of the same age.
///
/// Rows with no deadline are what `MsgSecretPolicy::Full` writes, and its
/// documented contract is unbounded retention, so they are never candidates.
/// A store holding nothing but those still grows without bound -- that is the
/// policy the caller asked for.
///
/// For the same reason the cap is measured against the evictable rows alone,
/// not the map length. Counting the never-expire rows toward it would make a
/// store that holds many of them (a backend reused across a `Full` -> `Managed`
/// switch) evict every finite row it has and still not reach the bound.
///
/// # Where the alias grouping stops
///
/// A message's sender alias rows are kept together at the cutoff, which is
/// where an arbitrary choice would otherwise be made. Rows *below* the cutoff
/// go individually. Those two rows are separate keys, so nothing merges their
/// deadlines, and a write that dated one of them differently -- a later capture
/// under another retention class -- can leave a pair straddling the cutoff and
/// split it.
///
/// That gap is deliberate. Closing it means grouping every evictable row, not
/// just the cutoff's tie bucket, and the index that needs costs about 1.0 MiB
/// of committed linear memory on wasm32 and roughly half again the eviction's
/// CPU (measured, 30k sends: 5.88 -> 6.88 MiB). Linear memory is never returned
/// there, so the fix permanently spends an eighth of what this cap is here to
/// reclaim, against a split that needs one message's aliases to be written at
/// different times under different classes. If that trade ever stops holding --
/// a producer that routinely dates aliases apart -- the group index is the
/// answer, and it belongs in the eviction, not in another guard above it.
fn trim_msg_secrets(map: &mut MsgSecretMap, rescan_at: &mut usize) {
    // Evictable rows are a subset of the map, so this O(1) test is a sound
    // early-out for the O(n) one below and keeps the common insert allocation-
    // free.
    //
    // `rescan_at` is the second guard, and it is what keeps a `Full`-policy
    // store off the O(n) path. There `map.len()` sits above the cap forever
    // while nothing is ever evictable, so the length test alone would scan the
    // whole map on every single write -- O(n) per insert, O(n^2) over a
    // session, all under the state lock.
    if map.len() <= MAX_MSG_SECRETS || map.len() < *rescan_at {
        return;
    }
    // Only the deadlines are collected: cloning every key to sort them would
    // allocate three `Arc<str>` bumps per retained row on each eviction while
    // holding the state lock. `select_nth_unstable` finds the cutoff in O(n)
    // without ordering the rest.
    let mut deadlines: Vec<i64> = map
        .values()
        .filter(|(_, expires_at, _)| *expires_at != 0)
        .map(|(_, expires_at, _)| *expires_at)
        .collect();
    if deadlines.len() <= MAX_MSG_SECRETS {
        // Nothing to evict yet. Every row added between now and the next scan
        // adds at most one evictable row, so the cap cannot be reached before
        // that many more arrive -- exact, not a heuristic.
        *rescan_at = map.len() + (MAX_MSG_SECRETS - deadlines.len()) + 1;
        return;
    }
    *rescan_at = 0;
    let drop_count = deadlines.len() - MAX_MSG_SECRETS * 3 / 4;
    let (_, &mut cutoff, _) = deadlines.select_nth_unstable(drop_count - 1);
    // Two passes apply the cutoff, because map iteration order is arbitrary and
    // a single pass could evict a row AT the cutoff while keeping one below it.
    // `cutoff` is never 0, so the never-expire rows stay out of both passes.
    let mut removed = 0usize;
    map.retain(|_, (_, expires_at, _)| {
        if *expires_at != 0 && *expires_at < cutoff {
            removed += 1;
            false
        } else {
            true
        }
    });
    let mut remaining = drop_count.saturating_sub(removed);
    if remaining == 0 {
        return;
    }
    // The rows sitting exactly on the cutoff. One message can own two of them:
    // history seeding and inbound bot capture persist a secret under two sender
    // aliases (`MAX_HISTORY_SECRET_SENDERS`), and those rows carry the same
    // deadline because it is derived from the same parent event. The pair
    // exists so a lookup succeeds under either identity, so dropping an
    // arbitrary subset of the bucket -- keeping one alias, losing the other --
    // would make decryption depend on which identity the later stanza happens
    // to carry. Choose whole messages instead of whole rows.
    //
    // Each group is counted in full before anything is committed to. Charging
    // the budget per visited row instead would undercount every group whose
    // partner iteration had not reached yet -- and since a message's two rows
    // hash independently, most of them -- so a 2049-row budget could remove
    // close to 4098 rows and leave the store at half the target. That is not a
    // bound being overshot, it is thousands of retainable secrets thrown away.
    let mut bucket: HbHashMap<MsgGroupKey, usize, RandomState> = HbHashMap::default();
    for (key, (_, expires_at, _)) in map.iter() {
        if *expires_at != cutoff {
            continue;
        }
        if let Some(rows) = bucket.get_mut(&MsgGroupKeyRef {
            chat: &key.chat,
            msg_id: &key.msg_id,
        }) {
            *rows += 1;
        } else {
            bucket.insert(
                MsgGroupKey {
                    chat: Arc::clone(&key.chat),
                    msg_id: Arc::clone(&key.msg_id),
                },
                1,
            );
        }
    }
    // Skipping a group that does not fit rather than stopping outright lets a
    // smaller one still use the remainder. Falling a row or two short of the
    // target is fine: the next insert re-enters through the length guard.
    let mut doomed: HbHashSet<MsgGroupKey, RandomState> = HbHashSet::default();
    for (group, rows) in bucket {
        if remaining == 0 {
            break;
        }
        if rows <= remaining {
            remaining -= rows;
            doomed.insert(group);
        }
    }
    map.retain(|key, (_, expires_at, _)| {
        *expires_at != cutoff
            || !doomed.contains(&MsgGroupKeyRef {
                chat: &key.chat,
                msg_id: &key.msg_id,
            })
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    // Only synthetic keys in a unique test namespace, never an app account.
    struct Fixture(String);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = security_framework::passwords::delete_generic_password(&self.0, "session-v1");
        }
    }
    #[test]
    fn keychain_round_trip_and_failed_write_does_not_advance_state() {
        let fixture = Fixture(format!("dev.fritz.whatsapp.tests.{}", uuid::Uuid::new_v4()));
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let store = KeychainBackend::open(fixture.0.clone()).unwrap();
            let mut device = Device::new();
            device.push_name = "Synthetic Fritz test".into();
            store.save(&device).await.unwrap();
            store.put_identity("test:1", [7; 32]).await.unwrap();
            store
                .put_session("test:1", b"synthetic session")
                .await
                .unwrap();
            store
                .put_sender_key("group:test", b"synthetic sender key")
                .await
                .unwrap();
            store
                .store_prekeys_batch(&[(3, Bytes::from_static(b"synthetic prekey"))], false)
                .await
                .unwrap();
            store
                .put_msg_secrets(vec![MsgSecretEntry {
                    chat: "group".into(),
                    sender: "test".into(),
                    msg_id: "message".into(),
                    secret: [9; 32],
                    expires_at: 0,
                    message_ts: 1,
                }])
                .await
                .unwrap();
            drop(store);
            let restored = KeychainBackend::open(fixture.0.clone()).unwrap();
            assert_eq!(
                restored.load().await.unwrap().unwrap().push_name,
                "Synthetic Fritz test"
            );
            assert_eq!(
                restored.load_identity("test:1").await.unwrap(),
                Some([7; 32])
            );
            assert_eq!(
                restored.get_session("test:1").await.unwrap(),
                Some(Bytes::from_static(b"synthetic session"))
            );
            assert_eq!(
                restored.get_sender_key("group:test").await.unwrap(),
                Some(b"synthetic sender key".to_vec())
            );
            assert_eq!(
                restored.load_prekey(3).await.unwrap(),
                Some(Bytes::from_static(b"synthetic prekey"))
            );
            assert_eq!(
                restored
                    .get_msg_secret("group", "test", "message")
                    .await
                    .unwrap(),
                Some(vec![9; 32])
            );
            assert!(
                restored
                    .put_session("oversized", &vec![0; 16 * 1024 * 1024])
                    .await
                    .is_err()
            );
            assert_eq!(restored.get_session("oversized").await.unwrap(), None);
            restored.close().await;
            assert!(restored.put_identity("test:1", [8; 32]).await.is_err());
            assert_eq!(
                restored.load_identity("test:1").await.unwrap(),
                Some([7; 32])
            );
            let disk = KeychainBackend::open(fixture.0.clone()).unwrap();
            assert_eq!(disk.load_identity("test:1").await.unwrap(), Some([7; 32]));
        });
    }
    #[test]
    #[ignore = "Connects to WhatsApp to verify the native Keychain pairing path"]
    fn live_pairing_challenge_with_keychain_backend() {
        let fixture = Fixture(format!("dev.fritz.whatsapp.tests.{}", uuid::Uuid::new_v4()));
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let backend = Arc::new(KeychainBackend::open(fixture.0.clone()).unwrap());
            let (tx, mut rx) = tokio::sync::mpsc::channel(1);
            let bot = whatsapp_rust::prelude::Bot::builder()
                .with_backend_arc(backend.clone())
                .on_qr_code(move |code, _| {
                    let tx = tx.clone();
                    async move {
                        let _ = tx.send(!code.is_empty()).await;
                    }
                })
                .build()
                .await
                .unwrap();
            let handle = bot.spawn();
            let challenge =
                tokio::time::timeout(std::time::Duration::from_secs(45), rx.recv()).await;
            tokio::time::timeout(std::time::Duration::from_secs(10), handle.shutdown())
                .await
                .unwrap();
            backend.close().await;
            assert_eq!(challenge.unwrap(), Some(true));
        });
    }
}
