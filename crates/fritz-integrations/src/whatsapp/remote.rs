//! Owner-only remote control. Queue claims are at-most-once, never replayed after restart.
use super::*;
use std::collections::VecDeque;

#[derive(Clone, serde::Serialize)]
struct Command {
    id: String,
    text: String,
    timestamp: u64,
}

#[derive(Clone)]
pub(super) struct Inbox {
    since: u64,
    pending: VecDeque<Command>,
    seen: VecDeque<(String, u64)>,
    active: Option<String>,
}

impl Default for Inbox {
    fn default() -> Self {
        Self {
            since: now(),
            pending: VecDeque::new(),
            seen: VecDeque::new(),
            active: None,
        }
    }
}

pub(super) fn invalidate(status: &mut Status) {
    status.remote_epoch = Uuid::new_v4().to_string();
    status.remote = Inbox::default();
}

pub(super) fn load_enabled(service: &str) -> Result<bool, Error> {
    match security_framework::passwords::get_generic_password(service, "remote-enabled-v1") {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|_| failure("Saved remote control preference is invalid.")),
        Err(e) if e.code() == security_framework_sys::base::errSecItemNotFound => Ok(false),
        Err(_) => Err(failure(
            "Could not read remote control preference from Keychain.",
        )),
    }
}

pub(super) fn receive(status: &mut Status, context: &whatsapp_rust::bot::MessageContext) {
    // Accept only plain text, never captions, edits, quoted text or history wrappers.
    let text = context.message.conversation.as_deref().or_else(|| {
        context
            .message
            .extended_text_message
            .as_option()
            .and_then(|m| m.text.as_deref())
    });
    let Some(text) = text else { return };
    accept(
        status,
        context.info.id.as_ref(),
        &context.info.source.chat.to_string(),
        context.info.source.is_from_me,
        context.info.timestamp.timestamp().max(0) as u64,
        text,
        now(),
    );
}

fn accept(
    status: &mut Status,
    id: &str,
    group: &str,
    from_me: bool,
    timestamp: u64,
    text: &str,
    time: u64,
) {
    if !status.enabled
        || status.phase != "connected"
        || !status.remote_enabled
        || !from_me
        || status.destination.as_ref().is_none_or(|d| d.id != group)
        || timestamp <= status.remote.since
        || timestamp > time
        || time.saturating_sub(timestamp) > 300
        || id.is_empty()
        || text.chars().count() > 4096
    {
        return;
    }
    let Some(command) = text.strip_prefix(&status.command_prefix) else {
        return;
    };
    if !command.is_empty() && !command.starts_with(char::is_whitespace) {
        return;
    }
    if command.trim() == "cancel" {
        invalidate(status);
        status.remote.pending.push_back(Command {
            id: id.into(),
            text: "cancel".into(),
            timestamp,
        });
        return;
    }
    let inbox = &mut status.remote;
    inbox.seen.retain(|(_, t)| time.saturating_sub(*t) <= 300);
    if inbox.seen.iter().any(|(seen, _)| seen == id) || inbox.seen.len() >= 4096 {
        return;
    }
    inbox.seen.push_back((id.into(), timestamp));
    if inbox.pending.len() >= 16 {
        status.message = Some(
            "Remote command queue is full. Wait for results before sending another command.".into(),
        );
        return;
    }
    inbox.pending.push_back(Command {
        id: id.into(),
        text: command.trim().into(),
        timestamp,
    });
}

pub(super) fn route(
    service: &mut Service,
    request: &AgentHttpRequest,
    path: &str,
) -> Result<Value, Error> {
    match (request.method.as_str(), path) {
        ("POST", "/v1/whatsapp/remote/enabled") => {
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Input {
                enabled: bool,
            }
            let input: Input = serde_json::from_slice(&request.body)
                .map_err(|_| Error::usage("Provide enabled."))?;
            let mut status = service.status.lock().unwrap();
            if input.enabled && (!status.enabled || !status.saved || status.destination.is_none()) {
                return Err(Error::usage(
                    "Connect WhatsApp and choose a group before enabling remote control.",
                ));
            }
            security_framework::passwords::set_generic_password(
                &service.keychain_service,
                "remote-enabled-v1",
                if input.enabled { b"true" } else { b"false" },
            )
            .map_err(|_| failure("Could not save remote control preference."))?;
            status.remote_enabled = input.enabled;
            invalidate(&mut status);
            drop(status);
            service.snapshot()
        }
        ("POST", "/v1/whatsapp/remote/claim") => {
            let mut status = service.status.lock().unwrap();
            if !status.enabled || !status.remote_enabled {
                return Ok(json!({"command": null, "epoch": status.remote_epoch}));
            }
            // Consumed before execution. A failed HTTP response never causes a second execution.
            let time = now();
            status
                .remote
                .pending
                .retain(|c| time.saturating_sub(c.timestamp) <= 300);
            let command = status.remote.pending.pop_front();
            status.remote.active = command.as_ref().map(|c| c.id.clone());
            Ok(json!({"command": command, "epoch": status.remote_epoch}))
        }
        ("POST", "/v1/whatsapp/remote/reply") => {
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Input {
                id: String,
                epoch: String,
                text: String,
            }
            let input: Input = serde_json::from_slice(&request.body)
                .map_err(|_| Error::usage("Provide reply id, epoch and text."))?;
            let mut status = service.status.lock().unwrap();
            if !status.enabled
                || !status.remote_enabled
                || input.epoch != status.remote_epoch
                || status.remote.active.as_ref() != Some(&input.id)
            {
                return Err(Error::usage(
                    "Remote command was cancelled or already answered.",
                ));
            }
            let body = serde_json::to_vec(
                &json!({"text": format!("{}: {}", status.reply_name, input.text)}),
            )
            .map_err(|_| failure("Could not encode reply."))?;
            prepare_send(&status, &body)?;
            // Do not retry uncertain delivery. Prefix prevents replies becoming commands.
            status.remote.active = None;
            drop(status);
            let result = service.send(&body);
            if result.is_err() {
                service.status.lock().unwrap().message = Some("Remote reply failed; delivery may be uncertain. Check the group before retrying.".into());
            }
            result
        }
        _ => Err(Error::usage("Unknown remote control route or method.")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn status() -> Status {
        let mut s = Status {
            remote_enabled: true,
            phase: "connected".into(),
            destination: Some(Destination {
                id: "123@g.us".into(),
                name: "Fritz".into(),
            }),
            ..Status::default()
        };
        s.remote.since = 100;
        s
    }
    #[test]
    fn only_live_owner_commands_in_selected_group_are_accepted() {
        let mut s = status();
        for (id, group, owner, timestamp, text) in [
            ("other", "123@g.us", false, 101, "/fritz status"),
            ("group", "456@g.us", true, 101, "/fritz status"),
            ("history", "123@g.us", true, 100, "/fritz status"),
            ("future", "123@g.us", true, 103, "/fritz status"),
            ("echo", "123@g.us", true, 101, "Fritz: /fritz status"),
            ("prefix", "123@g.us", true, 101, "/fritzated"),
        ] {
            accept(&mut s, id, group, owner, timestamp, text, 102);
        }
        assert!(s.remote.pending.is_empty());
        accept(&mut s, "ok", "123@g.us", true, 101, "/fritz status", 102);
        accept(&mut s, "ok", "123@g.us", true, 101, "/fritz status", 102);
        assert_eq!(s.remote.pending.len(), 1);
        assert_eq!(s.remote.pending[0].text, "status");
        s.remote_enabled = false;
        accept(&mut s, "off", "123@g.us", true, 101, "/fritz status", 102);
        assert_eq!(s.remote.pending.len(), 1);
    }
    #[test]
    fn cancellation_interrupts_a_full_queue_and_revokes_the_active_reply() {
        let mut s = status();
        for i in 0..20 {
            accept(
                &mut s,
                &format!("cmd-{i}"),
                "123@g.us",
                true,
                101,
                "/fritz ask something",
                102,
            );
        }
        assert_eq!(s.remote.pending.len(), 16);
        assert!(s.message.as_deref().unwrap().contains("queue is full"));
        s.remote.active = Some("working".into());
        let epoch = s.remote_epoch.clone();
        accept(
            &mut s,
            "cancel",
            "123@g.us",
            true,
            101,
            "/fritz cancel",
            102,
        );
        assert_ne!(s.remote_epoch, epoch);
        assert!(s.remote.active.is_none());
        assert_eq!(s.remote.pending.len(), 1);
        assert_eq!(s.remote.pending[0].text, "cancel");
    }

    #[test]
    fn old_disabled_and_oversized_commands_are_rejected() {
        let mut s = status();
        accept(&mut s, "old", "123@g.us", true, 101, "/fritz status", 402);
        s.enabled = false;
        accept(
            &mut s,
            "disabled",
            "123@g.us",
            true,
            101,
            "/fritz status",
            102,
        );
        s.enabled = true;
        accept(
            &mut s,
            "long",
            "123@g.us",
            true,
            101,
            &format!("/fritz {}", "x".repeat(4096)),
            102,
        );
        assert!(s.remote.pending.is_empty());
    }

    #[test]
    fn revocation_invalidates_pending_commands_and_replies() {
        let mut s = status();
        accept(&mut s, "ok", "123@g.us", true, 101, "/fritz status", 102);
        s.remote.active = Some("running".into());
        let epoch = s.remote_epoch.clone();
        invalidate(&mut s);
        assert!(s.remote.pending.is_empty());
        assert!(s.remote.active.is_none());
        assert_ne!(s.remote_epoch, epoch);
    }
}
