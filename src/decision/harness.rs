//! Shared private decision child runtimes. Hosts call these only in an owned child process.
//! Native cancellation may exit the process after flushing its terminal event.
use crate::{decision, harness_client};
use anyhow::{Context, Result};
use serde_json::{Value, json};
use std::io::Write;
use tokio::io::{AsyncReadExt, BufReader};

fn emit(event: Value) {
    let mut out = std::io::stdout().lock();
    if serde_json::to_writer(&mut out, &event).is_ok() {
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }
}

pub async fn run_stdio() -> Result<()> {
    let mut input = BufReader::new(harness_client::PrivateStdin::new()?);
    let line = harness_client::read_line(&mut input, 3_000_000)
        .await?
        .context("Missing decision request.")?;
    let config: decision::HarnessInput =
        serde_json::from_str(&line).context("Invalid decision request.")?;
    config.validate()?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut byte = [0u8; 1];
    let is_local = matches!(config.backend, decision::HarnessBackend::Ollaya);
    let evaluation = async {
        match config.backend {
            decision::HarnessBackend::Jev { endpoint } => {
                let key = config.api_key.context("Jev requires an API key.")?;
                let backend = match endpoint {
                    Some(endpoint) => decision::Jev::with_endpoint(key, &endpoint)?,
                    None => decision::Jev::new(key)?,
                };
                decision::evaluate(&backend, &config.request).await
            }
            decision::HarnessBackend::Ollaya => {
                anyhow::ensure!(
                    config.api_key.is_none(),
                    "Local decision models do not use an API key."
                );
                let store = decision::local::ModelStore::from_configuration(
                    config
                        .model_store
                        .context("Local decisions require an explicit modelStore.")?,
                )?;
                decision::evaluate(&decision::local::Ollaya::new(store), &config.request).await
            }
        }
    };
    let (terminal, interrupted) = tokio::select! {
        result=evaluation=>(match result {
            Ok(response)=>json!({"type":"result","result":response}),
            Err(error)=>json!({"type":"error","message":error.to_string()}),
        }, false),
        _=tokio::time::sleep(std::time::Duration::from_secs(120))=>(json!({"type":"error","message":"The decision request exceeded its 120-second limit."}), true),
        _=input.read(&mut byte)=>(json!({"type":"cancelled"}), true),
        _=interrupt.recv()=>(json!({"type":"cancelled"}), true),
        _=sigint.recv()=>(json!({"type":"cancelled"}), true),
    };
    emit(terminal);
    if is_local && interrupted {
        // The terminal event has been flushed. Native loading/inference may still be on
        // its worker thread: libc exit/return from main runs ONNX's C++ global destructors
        // concurrently with that worker and can segfault. This read-only, single-request
        // process owns no pending writes; let the OS reclaim it without running atexit.
        unsafe { libc::_exit(0) };
    }
    Ok(())
}

/// Versioned private resident protocol. The session model and store cannot change.
#[derive(serde::Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
enum ResidentMessage {
    Open {
        version: u8,
        id: String,
        model: String,
        #[serde(rename = "modelStore")]
        model_store: decision::local::ModelStoreConfiguration,
    },
    Evaluate {
        version: u8,
        id: String,
        generation: u64,
        request: decision::DecisionRequest,
    },
    Shutdown {
        version: u8,
        id: String,
    },
}

struct Sequence {
    model: String,
    generation: u64,
    ids: std::collections::HashSet<String>,
}

impl Sequence {
    fn new(model: String, id: &str) -> Result<Self> {
        validate_resident_id(id)?;
        Ok(Self {
            model,
            generation: 0,
            ids: std::collections::HashSet::from([id.into()]),
        })
    }

    fn admit(
        &mut self,
        version: u8,
        id: &str,
        generation: u64,
        request: &decision::DecisionRequest,
    ) -> Result<()> {
        validate_resident_id(id)?;
        anyhow::ensure!(
            version == 1 && generation == self.generation + 1 && generation <= 64,
            "Resident requests require version 1 and the next generation, up to 64 requests."
        );
        anyhow::ensure!(
            !self.ids.contains(id),
            "Resident request IDs cannot be replayed."
        );
        anyhow::ensure!(
            request.model == self.model,
            "Resident decisions cannot change the session model."
        );
        request.validate()?;
        self.ids.insert(id.into());
        self.generation = generation;
        Ok(())
    }
}

fn validate_resident_id(id: &str) -> Result<()> {
    anyhow::ensure!(
        !id.trim().is_empty() && id.len() <= 128,
        "Resident request IDs require 1 to 128 bytes."
    );
    Ok(())
}

/// Shared resident entry point for an owned child, never the host application.
/// First evaluation loads the engine; later requests reuse weights with fresh state.
/// The host owns and must reap the whole child process group on every exit.
pub async fn run_resident_stdio() -> Result<()> {
    let result = resident_loop().await;
    if let Err(error) = result {
        emit(json!({"version":1,"type":"error","id":null,"message":error.to_string()}));
        unsafe { libc::_exit(1) };
    }
    // ONNX remains owned by its dedicated worker. Do not race global destructors.
    unsafe { libc::_exit(0) };
}

async fn resident_loop() -> Result<()> {
    let mut input = BufReader::new(harness_client::PrivateStdin::new()?);
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let first = tokio::select! {
        line=harness_client::read_line(&mut input,3_000_000)=>line?.context("Missing resident open request.")?,
        _=tokio::time::sleep(std::time::Duration::from_secs(60))=>anyhow::bail!("Resident open request exceeded its 60-second idle limit."),
        _=interrupt.recv()=>return Ok(()),
        _=sigint.recv()=>return Ok(()),
    };
    let ResidentMessage::Open {
        version,
        id: session_id,
        model,
        model_store,
    } = serde_json::from_str(&first).context("Invalid resident open request.")?
    else {
        anyhow::bail!("Open the resident decision session first.");
    };
    anyhow::ensure!(
        version == 1,
        "Resident decisions require protocol version 1."
    );
    let mut sequence = Sequence::new(model.clone(), &session_id)?;
    let store = decision::local::ModelStore::from_configuration(model_store)?;
    // Metadata/canonicalization use synchronous filesystem calls. Keep them off
    // this selecting task so a slow model volume cannot hide cancellation.
    // Fatal admission paths terminate this owned child, including the open task.
    let opening_model = model.clone();
    let runtime = tokio::runtime::Handle::current();
    let opening = tokio::task::spawn_blocking(move || {
        runtime.block_on(decision::local::ResidentOllaya::open(store, &opening_model))
    });
    let mut byte = [0u8; 1];
    let session = tokio::select! {
        biased;
        _=interrupt.recv()=>{emit(json!({"version":1,"type":"cancelled","id":session_id,"sessionId":session_id,"generation":0}));return Ok(());},
        _=sigint.recv()=>{emit(json!({"version":1,"type":"cancelled","id":session_id,"sessionId":session_id,"generation":0}));return Ok(());},
        read=input.read(&mut byte)=>{
            let terminal = match read { Ok(0)=>json!({"type":"cancelled"}), _=>json!({"type":"error","message":"Resident requests must be serial; stdin changed during admission."}) };
            let mut terminal=terminal;
            terminal["version"]=json!(1);terminal["id"]=json!(session_id);terminal["sessionId"]=json!(session_id);terminal["generation"]=json!(0);
            emit(terminal);return Ok(());
        },
        _=tokio::time::sleep(std::time::Duration::from_secs(120))=>anyhow::bail!("The resident model admission exceeded its 120-second limit."),
        result=opening=>result.context("The resident admission worker stopped unexpectedly.")??,
    };
    emit(
        json!({"version":1,"type":"opened","id":session_id,"sessionId":session_id,"generation":0,"model":session.resolved_model(),"modelDirectory":session.model_directory(),"loaded":false}),
    );
    loop {
        let line = tokio::select! {
            line=harness_client::read_line(&mut input,3_000_000)=>line?,
            _=tokio::time::sleep(std::time::Duration::from_secs(60))=>{
                emit(json!({"version":1,"type":"closed","id":null,"sessionId":session_id,"generation":sequence.generation,"reason":"idle_limit"}));return Ok(());
            },
            _=interrupt.recv()=>{ emit(json!({"version":1,"type":"closed","id":null,"sessionId":session_id,"generation":sequence.generation,"reason":"cancelled"}));return Ok(()); },
            _=sigint.recv()=>{ emit(json!({"version":1,"type":"closed","id":null,"sessionId":session_id,"generation":sequence.generation,"reason":"cancelled"}));return Ok(()); },
        };
        let Some(line) = line else {
            emit(
                json!({"version":1,"type":"closed","id":null,"sessionId":session_id,"generation":sequence.generation,"reason":"stdin_closed"}),
            );
            return Ok(());
        };
        match serde_json::from_str(&line).context("Invalid resident request.")? {
            ResidentMessage::Evaluate {
                version,
                id,
                generation,
                request,
            } => {
                if let Err(error) = sequence.admit(version, &id, generation, &request) {
                    emit(
                        json!({"version":1,"type":"error","id":id,"sessionId":session_id,"generation":generation,"message":error.to_string()}),
                    );
                    return Ok(());
                }
                let mut byte = [0u8; 1];
                let (terminal, stop) = tokio::select! {
                    biased;
                    _=interrupt.recv()=>(json!({"type":"cancelled"}),true),
                    _=sigint.recv()=>(json!({"type":"cancelled"}),true),
                    read=input.read(&mut byte)=>{
                        let event = match read { Ok(0)=>json!({"type":"cancelled"}), _=>json!({"type":"error","message":"Resident requests must be serial; stdin changed during evaluation."}) };
                        (event,true)
                    },
                    _=tokio::time::sleep(std::time::Duration::from_secs(120))=>(json!({"type":"error","message":"The decision request exceeded its 120-second limit."}),true),
                    result=decision::evaluate(&session,&request)=>match result {
                        Ok(response)=>(json!({"type":"result","result":response}),false),
                        Err(error)=>(json!({"type":"error","message":error.to_string()}),true),
                    },
                };
                let mut terminal = terminal;
                terminal["version"] = json!(1);
                terminal["id"] = json!(id);
                terminal["sessionId"] = json!(session_id);
                terminal["generation"] = json!(generation);
                emit(terminal);
                if stop {
                    return Ok(());
                }
            }
            ResidentMessage::Shutdown { version, id } => {
                validate_resident_id(&id)?;
                anyhow::ensure!(
                    version == 1 && !sequence.ids.contains(&id),
                    "Resident shutdown requires version 1 and a unique ID."
                );
                emit(
                    json!({"version":1,"type":"closed","id":id,"sessionId":session_id,"generation":sequence.generation,"reason":"shutdown"}),
                );
                return Ok(());
            }
            ResidentMessage::Open { .. } => {
                anyhow::bail!("A resident session cannot be reopened or change its model store.")
            }
        }
    }
}

#[cfg(test)]
mod resident_tests {
    use super::*;

    fn request() -> decision::DecisionRequest {
        serde_json::from_value(json!({"model":"kev-4b","state":{"value":"unchanged"},"questions":{"action":{"type":"choice","instructions":"Choose.","criteria":{"a":"first","b":"second"}}}})).unwrap()
    }

    #[test]
    fn resident_protocol_rejects_credentials_replay_and_identity_changes() {
        let open = json!({"version":1,"type":"open","id":"open","model":"kev-4b","modelStore":{"directory":"/Models"}});
        assert!(serde_json::from_value::<ResidentMessage>(open.clone()).is_ok());
        for field in ["apiKey", "backend", "history"] {
            let mut invalid = open.clone();
            invalid[field] = json!("forbidden");
            assert!(serde_json::from_value::<ResidentMessage>(invalid).is_err());
        }
        let original = request();
        let mut sequence = Sequence::new("kev-4b".into(), "open").unwrap();
        sequence.admit(1, "first", 1, &original).unwrap();
        assert!(sequence.admit(1, "first", 2, &original).is_err());
        assert!(sequence.admit(1, "second", 3, &original).is_err());
        let mut changed = original.clone();
        changed.model = "laya-en".into();
        assert!(sequence.admit(1, "second", 2, &changed).is_err());
        assert_eq!(sequence.generation, 1);
        for generation in 2..=64 {
            sequence
                .admit(1, &format!("request-{generation}"), generation, &original)
                .unwrap();
        }
        assert!(sequence.admit(1, "too-many", 65, &original).is_err());
    }
}
