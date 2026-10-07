//! Native linked-device WhatsApp connection owned by the Rust agent.
use crate::{Error, Request as AgentHttpRequest};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;
use whatsapp_rust::prelude::{Bot, BotHandle, Event, EventKind, MessageBuilderExt};
use whatsapp_rust::wacore::store::DevicePropsOverride;
use whatsapp_rust::wacore::store::traits::DeviceStore;
use whatsapp_rust::waproto::whatsapp::device_props::PlatformType;

mod remote;
mod store;

#[derive(Clone, Default, serde::Serialize, serde::Deserialize)]
struct Destination {
    id: String,
    name: String,
}
#[derive(Clone, serde::Serialize)]
struct Status {
    phase: String,
    saved: bool,
    enabled: bool,
    qr: Option<String>,
    expires_at: Option<u64>,
    message: Option<String>,
    destination: Option<Destination>,
    remote_enabled: bool,
    remote_epoch: String,
    #[serde(skip)]
    remote: remote::Inbox,
    #[serde(skip)]
    command_prefix: String,
    #[serde(skip)]
    reply_name: String,
}
impl Default for Status {
    fn default() -> Self {
        Self {
            phase: "disconnected".into(),
            saved: false,
            enabled: true,
            qr: None,
            expires_at: None,
            message: None,
            destination: None,
            remote_enabled: false,
            remote_epoch: Uuid::new_v4().to_string(),
            remote: remote::Inbox::default(),
            command_prefix: "/fritz".into(),
            reply_name: "Fritz".into(),
        }
    }
}
struct Service {
    runtime: tokio::runtime::Runtime,
    status: Arc<Mutex<Status>>,
    handle: Option<BotHandle>,
    keychain_service: String,
    app_name: String,
    groups: Vec<Destination>,
    backend: Option<Arc<store::KeychainBackend>>,
    started_at: Arc<std::sync::atomic::AtomicU64>,
}
/// The host chooses an existing, isolated credential namespace and command prefix.
#[derive(Clone)]
pub struct Config {
    pub keychain_service: String,
    pub app_name: String,
    pub reply_name: String,
    pub command_prefix: String,
}
pub struct WhatsAppService {
    config: Config,
    service: Mutex<Option<Service>>,
}
impl WhatsAppService {
    pub fn new(config: Config) -> Result<Self, Error> {
        if config.keychain_service.trim().is_empty()
            || config.app_name.trim().is_empty()
            || config.reply_name.trim().is_empty()
            || !config.command_prefix.starts_with('/')
            || config.command_prefix.len() < 2
            || config.command_prefix.chars().any(char::is_whitespace)
        {
            return Err(Error::usage(
                "Provide an app name, credential namespace, and slash command prefix.",
            ));
        }
        Ok(Self {
            config,
            service: Mutex::new(None),
        })
    }
    pub fn request(&self, request: &AgentHttpRequest) -> Result<Value, Error> {
        request_result(self, request)
    }
}

fn failure(message: &str) -> Error {
    Error::capture(message)
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn request_result(owner: &WhatsAppService, request: &AgentHttpRequest) -> Result<Value, Error> {
    let (path, query) = request
        .path
        .split_once('?')
        .map_or((request.path.as_str(), None), |(path, query)| {
            (path, Some(query))
        });
    if query.is_some()
        || request.body.len()
            > if matches!(path, "/v1/whatsapp/send" | "/v1/whatsapp/remote/reply") {
                32 * 1024
            } else {
                4096
            }
    {
        return Err(Error::usage("Invalid WhatsApp request."));
    }
    let mut guard = owner
        .service
        .lock()
        .map_err(|_| failure("WhatsApp service is unavailable."))?;
    // Removal must work even when an unreadable saved snapshot prevents startup.
    if request.method == "DELETE" && path == "/v1/whatsapp/connection" && guard.is_none() {
        remove_saved_connection(&owner.config.keychain_service)?;
        return Ok(json!({"connection": Status::default()}));
    }
    if guard.is_none() {
        *guard = Some(Service::with_config(owner.config.clone())?);
    }
    let service = guard.as_mut().unwrap();
    match (request.method.as_str(), path) {
        ("GET", "/v1/whatsapp") => service.snapshot(),
        (_, path) if path.starts_with("/v1/whatsapp/remote/") => {
            remote::route(service, request, path)
        }
        ("POST", "/v1/whatsapp/send") => service.send(&request.body),
        ("POST", "/v1/whatsapp/connect") => {
            if !service.status.lock().unwrap().enabled {
                return Err(Error::usage("Enable WhatsApp before connecting."));
            }
            if let Err(error) = service.start() {
                let mut status = service.status.lock().unwrap();
                status.phase = "error".into();
                status.message = Some("Could not connect WhatsApp. Check your network and unlock Keychain, then try again.".into());
                return Err(error);
            }
            service.snapshot()
        }
        ("POST", "/v1/whatsapp/enabled") => {
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Preference {
                enabled: bool,
            }
            let preference: Preference = serde_json::from_slice(&request.body)
                .map_err(|_| Error::usage("Provide an enabled boolean."))?;
            service.set_enabled(preference.enabled)?;
            service.snapshot()
        }
        ("DELETE", "/v1/whatsapp/connection") => {
            service.forget()?;
            service.snapshot()
        }
        ("GET", "/v1/whatsapp/groups") => {
            let client = service.connected_client()?;
            let groups = service
                .runtime
                .block_on(async {
                    tokio::time::timeout(
                        Duration::from_secs(20),
                        client.groups().get_participating(),
                    )
                    .await
                })
                .map_err(|_| failure("Group refresh timed out. Try again."))?
                .map_err(|_| failure("Could not load WhatsApp groups. Try again."))?;
            service.groups = groups
                .into_values()
                .map(|g| Destination {
                    id: g.id.to_string(),
                    name: g.subject,
                })
                .collect();
            service
                .groups
                .sort_by(|a, b| a.name.cmp(&b.name).then(a.id.cmp(&b.id)));
            Ok(json!({"groups": service.groups}))
        }
        ("POST", "/v1/whatsapp/destination") => {
            service.connected_client()?;
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Selection {
                id: String,
            }
            let selection: Selection = serde_json::from_slice(&request.body)
                .map_err(|_| Error::usage("Choose a WhatsApp group."))?;
            let destination = service
                .groups
                .iter()
                .find(|g| g.id == selection.id)
                .cloned()
                .ok_or_else(|| Error::usage("Refresh groups and choose a listed group."))?;
            let bytes = serde_json::to_vec(&destination)
                .map_err(|_| failure("Could not encode the group selection."))?;
            security_framework::passwords::set_generic_password(
                &service.keychain_service,
                "destination-v1",
                &bytes,
            )
            .map_err(|_| failure("Could not save the group selection in Keychain."))?;
            let mut status = service.status.lock().unwrap();
            status.destination = Some(destination);
            remote::invalidate(&mut status);
            drop(status);
            service.snapshot()
        }
        _ => Err(Error::usage("Unknown WhatsApp route or method.")),
    }
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct SendRequest {
    text: String,
}

fn prepare_send(status: &Status, body: &[u8]) -> Result<(whatsapp_rust::Jid, String), Error> {
    let request: SendRequest =
        serde_json::from_slice(body).map_err(|_| Error::usage("Provide WhatsApp message text."))?;
    if request.text.trim().is_empty() || request.text.chars().count() > 4096 {
        return Err(Error::usage(
            "WhatsApp messages must contain 1–4096 characters.",
        ));
    }
    if request
        .text
        .strip_prefix(&status.command_prefix)
        .is_some_and(|tail| tail.is_empty() || tail.starts_with(char::is_whitespace))
    {
        return Err(Error::usage(
            "WhatsApp output cannot start with the reserved command prefix. Add a descriptive heading.",
        ));
    }
    if !status.enabled {
        return Err(Error::usage(
            "WhatsApp is disabled. Enable it in Settings → WhatsApp.",
        ));
    }
    if !status.saved {
        return Err(Error::usage(
            "Connect an account in Settings → WhatsApp before sending.",
        ));
    }
    let destination = status
        .destination
        .as_ref()
        .ok_or_else(|| Error::usage("Choose a notification group in Settings → WhatsApp."))?;
    let jid: whatsapp_rust::Jid = destination.id.parse().map_err(|_| {
        Error::usage("The saved WhatsApp group is invalid. Choose it again in Settings → WhatsApp.")
    })?;
    if jid.server != whatsapp_rust::Server::Group || jid.user.is_empty() {
        return Err(Error::usage(
            "Choose a WhatsApp group in Settings → WhatsApp.",
        ));
    }
    Ok((jid, request.text))
}

impl Service {
    fn send(&mut self, body: &[u8]) -> Result<Value, Error> {
        let (destination, text) = prepare_send(&self.status.lock().unwrap(), body)?;
        self.start()?;
        let client = self
            .handle
            .as_ref()
            .ok_or_else(|| failure("WhatsApp is disconnected. Reconnect in Settings → WhatsApp."))?
            .client();
        self.runtime.block_on(async {
            client.wait_for_connected(Duration::from_secs(20)).await
                .map_err(|_| failure("WhatsApp could not connect. Check Settings → WhatsApp and your network."))?;
            let sent = tokio::time::timeout(
                Duration::from_secs(20),
                client.send_message(destination, whatsapp_rust::waproto::whatsapp::Message::text(text)),
            ).await
                .map_err(|_| failure("WhatsApp sending timed out. Delivery is uncertain; check the group before retrying."))?
                .map_err(|_| failure("WhatsApp sending failed. Check the group and connection before retrying."))?;
            Ok(json!({"message_id": sent.message_id, "destination_id": sent.to.to_string()}))
        })
    }
    fn with_config(config: Config) -> Result<Self, Error> {
        let keychain_service = config.keychain_service;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|_| failure("Could not start WhatsApp."))?;
        let mut status = Status {
            command_prefix: config.command_prefix,
            reply_name: config.reply_name,
            ..Status::default()
        };
        match security_framework::passwords::get_generic_password(&keychain_service, "enabled-v1") {
            Ok(bytes) => {
                status.enabled = serde_json::from_slice(&bytes)
                    .map_err(|_| failure("Saved WhatsApp enabled preference is invalid."))?;
            }
            Err(e) if e.code() == security_framework_sys::base::errSecItemNotFound => {}
            Err(_) => return Err(failure("Could not read WhatsApp settings from Keychain.")),
        }
        if !status.enabled {
            status.phase = "disabled".into();
        }
        match security_framework::passwords::get_generic_password(
            &keychain_service,
            "destination-v1",
        ) {
            Ok(bytes) => {
                status.destination = Some(
                    serde_json::from_slice(&bytes)
                        .map_err(|_| failure("Saved WhatsApp group is invalid."))?,
                )
            }
            Err(e) if e.code() == security_framework_sys::base::errSecItemNotFound => {}
            Err(_) => return Err(failure("Could not read WhatsApp settings from Keychain.")),
        }
        status.remote_enabled = remote::load_enabled(&keychain_service)?;
        let backend = store::KeychainBackend::open(keychain_service.clone())
            .map_err(|_| failure("Could not read WhatsApp connection from Keychain."))?;
        status.saved = runtime
            .block_on(backend.load())
            .map_err(|_| failure("Could not read WhatsApp connection."))?
            .is_some_and(|d| d.pn.is_some());
        let should_start = status.saved && status.enabled;
        let mut service = Self {
            runtime,
            status: Arc::new(Mutex::new(status)),
            handle: None,
            keychain_service,
            app_name: config.app_name,
            groups: Vec::new(),
            backend: None,
            started_at: Arc::new(std::sync::atomic::AtomicU64::new(0)),
        };
        if should_start {
            service.start()?;
        }
        Ok(service)
    }
    fn snapshot(&self) -> Result<Value, Error> {
        let mut status = self
            .status
            .lock()
            .map_err(|_| failure("WhatsApp status is unavailable."))?;
        if status.expires_at.is_some_and(|t| t <= now()) {
            status.qr = None;
            status.expires_at = None;
        }
        if let Some(handle) = &self.handle
            && status.phase == "connected"
            && !handle.client().is_connected()
        {
            status.phase = "connecting".into();
            self.started_at
                .store(now(), std::sync::atomic::Ordering::Relaxed);
        }
        if status.phase == "connecting"
            && now().saturating_sub(self.started_at.load(std::sync::atomic::Ordering::Relaxed)) > 60
        {
            status.phase = "error".into();
            status.message =
                Some("WhatsApp has not connected. Check your network and try again.".into());
        }
        Ok(json!({"connection": &*status}))
    }
    fn set_enabled(&mut self, enabled: bool) -> Result<(), Error> {
        if enabled && self.status.lock().unwrap().enabled {
            return Ok(());
        }
        // Persist before changing runtime state. Failure leaves the current preference intact.
        security_framework::passwords::set_generic_password(
            &self.keychain_service,
            "enabled-v1",
            if enabled { b"true" } else { b"false" },
        )
        .map_err(|_| failure("Could not save the WhatsApp enabled preference in Keychain."))?;
        {
            let mut status = self.status.lock().unwrap();
            status.enabled = enabled;
            remote::invalidate(&mut status);
            status.qr = None;
            status.expires_at = None;
            status.message = None;
            status.phase = if enabled { "disconnected" } else { "disabled" }.into();
        }
        if enabled {
            if self.status.lock().unwrap().saved {
                self.start()?;
            }
        } else {
            self.stop()?;
        }
        Ok(())
    }
    fn start(&mut self) -> Result<(), Error> {
        if !self.status.lock().unwrap().enabled {
            return Err(Error::usage("Enable WhatsApp before connecting."));
        }
        let app_name = self.app_name.clone();
        let phase = self.status.lock().unwrap().phase.clone();
        if self.handle.is_some() && ["connecting", "pairing", "connected"].contains(&phase.as_str())
        {
            return Ok(());
        }
        self.stop()?;
        let backend = store::KeychainBackend::open(self.keychain_service.clone())
            .map_err(|_| failure("Could not read WhatsApp connection from Keychain."))?;
        {
            let mut s = self.status.lock().unwrap();
            s.phase = "connecting".into();
            s.qr = None;
            s.message = None;
            s.expires_at = None;
        }
        self.started_at
            .store(now(), std::sync::atomic::Ordering::Relaxed);
        let message_status = self.status.clone();
        let qr_status = self.status.clone();
        let connected_status = self.status.clone();
        let event_status = self.status.clone();
        let reconnect_started = self.started_at.clone();
        let backend = Arc::new(backend);
        self.backend = Some(backend.clone());
        let builder = Bot::builder().with_backend_arc(backend)
            // WhatsApp uses the desktop OS label as the linked-device name at pairing.
            .with_device_props(DevicePropsOverride::new().with_os(app_name).with_platform_type(PlatformType::DESKTOP))
            .on_message(move |context| {
                let status = message_status.clone();
                async move { remote::receive(&mut status.lock().unwrap(), &context); }
            })
            .on_qr_code(move |code, validity| {
                let status = qr_status.clone();
                async move { let mut s = status.lock().unwrap(); if !s.enabled { return; } s.phase = "pairing".into(); s.qr = Some(code); s.expires_at = Some(now() + validity.as_secs()); s.message = None; }
            })
            .on_connected(move |_| {
                let status = connected_status.clone();
                async move { let mut s = status.lock().unwrap(); if !s.enabled { return; } s.phase = "connected".into(); s.saved = true; s.qr = None; s.expires_at = None; s.message = None; }
            })
            .on_event_for(&[EventKind::LoggedOut, EventKind::PairError, EventKind::PairingQrCodesExhausted, EventKind::Disconnected], move |event, _| {
                let status = event_status.clone();
                let reconnect_started = reconnect_started.clone();
                async move {
                    let mut s = status.lock().unwrap();
                    if !s.enabled { return; }
                    match &*event {
                        Event::Disconnected(_) if s.phase == "connected" => { s.phase = "connecting".into(); reconnect_started.store(now(), std::sync::atomic::Ordering::Relaxed); },
                        Event::PairingQrCodesExhausted(_) => { s.phase = "expired".into(); s.qr = None; s.expires_at = None; s.message = Some("Pairing expired. Request a new QR code.".into()); },
                        Event::LoggedOut(_) => { s.phase = "error".into(); s.qr = None; s.expires_at = None; s.message = Some("This device was unlinked. Remove the saved connection and pair again.".into()); },
                        Event::PairError(_) => { s.phase = "error".into(); s.qr = None; s.expires_at = None; s.message = Some("Pairing failed. Try again.".into()); },
                        _ => {},
                    }
                }
            });
        let bot = self.runtime.block_on(builder.build()).map_err(|_| {
            failure("Could not initialize WhatsApp. Check that Keychain is unlocked.")
        })?;
        let _entered = self.runtime.enter();
        self.handle = Some(bot.spawn());
        Ok(())
    }
    fn connected_client(&self) -> Result<Arc<whatsapp_rust::Client>, Error> {
        self.handle
            .as_ref()
            .map(|h| h.client())
            .filter(|c| c.is_connected() && self.status.lock().unwrap().phase == "connected")
            .ok_or_else(|| failure("Connect WhatsApp before choosing a group."))
    }
    fn stop(&mut self) -> Result<(), Error> {
        if let Some(handle) = &self.handle {
            let client = handle.client();
            self.runtime
                .block_on(async {
                    tokio::time::timeout(Duration::from_secs(10), client.disconnect()).await
                })
                .map_err(|_| failure("WhatsApp is still stopping. Try again."))?;
        }
        if let Some(backend) = &self.backend {
            self.runtime.block_on(backend.close());
        }
        if let Some(handle) = self.handle.take() {
            handle.abort();
        }
        self.backend = None;
        Ok(())
    }
    fn forget(&mut self) -> Result<(), Error> {
        remote::invalidate(&mut self.status.lock().unwrap());
        self.stop()?;
        if let Err(error) = remove_saved_connection(&self.keychain_service) {
            let mut status = self.status.lock().unwrap();
            status.phase = "error".into();
            status.qr = None;
            status.message = Some(
                "Could not remove the saved connection. Unlock Keychain and try again.".into(),
            );
            return Err(error);
        }
        let mut status = self.status.lock().unwrap();
        *status = Status {
            command_prefix: status.command_prefix.clone(),
            reply_name: status.reply_name.clone(),
            ..Status::default()
        };
        drop(status);
        self.groups.clear();
        Ok(())
    }
}

fn remove_saved_connection(service: &str) -> Result<(), Error> {
    for account in [
        "session-v1",
        "destination-v1",
        "enabled-v1",
        "remote-enabled-v1",
    ] {
        match security_framework::passwords::delete_generic_password(service, account) {
            Ok(()) => {}
            Err(e) if e.code() == security_framework_sys::base::errSecItemNotFound => {}
            Err(_) => {
                return Err(failure(
                    "Could not remove the WhatsApp connection from Keychain.",
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture(String);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = remove_saved_connection(&self.0);
        }
    }

    #[test]
    fn disabling_preserves_pairing_and_group_across_restart() {
        let fixture = Fixture(format!("dev.fritz.whatsapp.tests.{}", uuid::Uuid::new_v4()));
        let mut service = Service::with_config(Config {
            keychain_service: fixture.0.clone(),
            app_name: "Fritz".into(),
            reply_name: "Fritz".into(),
            command_prefix: "/fritz".into(),
        })
        .unwrap();
        let backend = store::KeychainBackend::open(fixture.0.clone()).unwrap();
        let mut device = whatsapp_rust::wacore::store::Device::new();
        device.pn = Some("12345@s.whatsapp.net".parse().unwrap());
        service.runtime.block_on(backend.save(&device)).unwrap();
        let destination = br#"{"id":"fixture@g.us","name":"Fritz"}"#;
        security_framework::passwords::set_generic_password(
            &fixture.0,
            "destination-v1",
            destination,
        )
        .unwrap();
        security_framework::passwords::set_generic_password(
            &fixture.0,
            "remote-enabled-v1",
            b"true",
        )
        .unwrap();
        let original =
            security_framework::passwords::get_generic_password(&fixture.0, "session-v1").unwrap();
        service.set_enabled(false).unwrap();
        assert!(service.start().is_err());
        assert!(service.handle.is_none());
        drop(service);

        let mut restored = Service::with_config(Config {
            keychain_service: fixture.0.clone(),
            app_name: "Fritz".into(),
            reply_name: "Fritz".into(),
            command_prefix: "/fritz".into(),
        })
        .unwrap();
        let snapshot = restored.snapshot().unwrap();
        assert_eq!(snapshot["connection"]["enabled"], false);
        assert_eq!(snapshot["connection"]["remote_enabled"], true);
        assert_eq!(snapshot["connection"]["phase"], "disabled");
        assert_eq!(snapshot["connection"]["saved"], true);
        assert_eq!(snapshot["connection"]["destination"]["id"], "fixture@g.us");
        assert!(restored.handle.is_none());
        assert_eq!(
            security_framework::passwords::get_generic_password(&fixture.0, "session-v1").unwrap(),
            original
        );
        restored.forget().unwrap();
        let fresh = Service::with_config(Config {
            keychain_service: fixture.0.clone(),
            app_name: "Fritz".into(),
            reply_name: "Fritz".into(),
            command_prefix: "/fritz".into(),
        })
        .unwrap();
        assert_eq!(fresh.snapshot().unwrap()["connection"]["enabled"], true);
        assert_eq!(fresh.snapshot().unwrap()["connection"]["saved"], false);
        assert_eq!(
            fresh.snapshot().unwrap()["connection"]["remote_enabled"],
            false
        );
    }

    #[test]
    fn sending_uses_only_the_saved_group_and_preserves_text() {
        let mut status = Status {
            saved: true,
            destination: Some(Destination {
                id: "123456@g.us".into(),
                name: "Fritz".into(),
            }),
            ..Status::default()
        };
        let (jid, text) =
            prepare_send(&status, br#"{"text":"Final response\nSecond line"}"#).unwrap();
        assert_eq!(jid.to_string(), "123456@g.us");
        assert_eq!(text, "Final response\nSecond line");
        for body in [
            br#"{"text":" "}"#.as_slice(),
            br#"{"text":"Hi","to":"other@g.us"}"#,
            br#"{"text":"/fritz example command"}"#,
            br#"{}"#,
        ] {
            assert!(prepare_send(&status, body).is_err());
        }
        let limit = serde_json::to_vec(&json!({"text": "é".repeat(4096)})).unwrap();
        assert!(prepare_send(&status, &limit).is_ok());
        let over_limit = serde_json::to_vec(&json!({"text": "é".repeat(4097)})).unwrap();
        assert!(prepare_send(&status, &over_limit).is_err());
        let body = br#"{"text":"Final response"}"#;
        status.enabled = false;
        assert!(prepare_send(&status, body).is_err());
        status.enabled = true;
        status.saved = false;
        assert!(prepare_send(&status, body).is_err());
        status.saved = true;
        status.destination.as_mut().unwrap().id = "123@s.whatsapp.net".into();
        assert!(prepare_send(&status, body).is_err());
        status.destination = None;
        assert!(prepare_send(&status, body).is_err());
    }

    #[test]
    fn disabled_sending_does_not_start_a_client() {
        let fixture = Fixture(format!("dev.fritz.whatsapp.tests.{}", uuid::Uuid::new_v4()));
        let mut service = Service::with_config(Config {
            keychain_service: fixture.0.clone(),
            app_name: "Fritz".into(),
            reply_name: "Fritz".into(),
            command_prefix: "/fritz".into(),
        })
        .unwrap();
        service.set_enabled(false).unwrap();
        assert!(service.send(br#"{"text":"Final response"}"#).is_err());
        assert!(service.handle.is_none());
    }

    #[test]
    fn enabled_preference_round_trips_without_creating_a_connection() {
        let fixture = Fixture(format!("dev.fritz.whatsapp.tests.{}", uuid::Uuid::new_v4()));
        let mut service = Service::with_config(Config {
            keychain_service: fixture.0.clone(),
            app_name: "Fritz".into(),
            reply_name: "Fritz".into(),
            command_prefix: "/fritz".into(),
        })
        .unwrap();
        service.set_enabled(false).unwrap();
        service.set_enabled(true).unwrap();
        service.set_enabled(true).unwrap();
        drop(service);
        let restored = Service::with_config(Config {
            keychain_service: fixture.0.clone(),
            app_name: "Fritz".into(),
            reply_name: "Fritz".into(),
            command_prefix: "/fritz".into(),
        })
        .unwrap();
        assert_eq!(restored.snapshot().unwrap()["connection"]["enabled"], true);
        assert_eq!(
            restored.snapshot().unwrap()["connection"]["phase"],
            "disconnected"
        );
        assert!(restored.handle.is_none());
    }
}
