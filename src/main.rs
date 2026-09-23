use fritz::{config, harness_client, local, provider};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use config::{Connection, ProviderKind};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{self, Write},
};
use tokio::io::{AsyncWriteExt, BufReader};
use uuid::Uuid;

#[derive(Parser)]
#[command(name = "fritz", version, about = "Fritz native chat agent and CLI")]
struct Cli {
    /// Run the private newline-delimited JSON transport used by Fritz.app.
    #[arg(long, hide = true)]
    agent: bool,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// List or explicitly download Fritz's built-in local models.
    LocalModels {
        #[command(subcommand)]
        command: LocalModelCommand,
    },
    /// List saved provider connections (never prints keys).
    Providers,
    /// Add a provider. Read a key from stdin with --api-key-stdin.
    AddProvider {
        #[arg(long)]
        name: String,
        #[arg(long, value_enum)]
        provider: ProviderKind,
        #[arg(long)]
        base_url: Option<String>,
        #[arg(long, default_value = "")]
        model: String,
        #[arg(long)]
        api_key_stdin: bool,
        #[arg(long)]
        default: bool,
    },
    /// Remove a provider connection and its saved key.
    RemoveProvider { connection: String },
    /// Set the default provider connection.
    DefaultProvider { connection: String },
    /// Discover models for a connection (uses the default when omitted).
    Models {
        #[arg(long)]
        connection: Option<String>,
    },
    /// Send a prompt; output streams to stdout. With no prompt, read stdin.
    Chat {
        prompt: Option<String>,
        #[arg(long)]
        connection: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long, value_parser = ["low", "medium", "high"])]
        effort: Option<String>,
        #[arg(long, value_parser = ["standard", "priority", "flex"])]
        speed: Option<String>,
        /// Enable coding tools in this project (commands run with your user permissions).
        #[arg(long)]
        project: Option<String>,
        #[arg(long, default_value_t = 24, value_parser = clap::value_parser!(u32).range(1..=40))]
        max_turns: u32,
    },
}

#[derive(Subcommand)]
enum LocalModelCommand {
    /// Show the pinned catalog and verified installation status.
    List { model: Option<String> },
    /// Download and verify a model; progress is newline-delimited JSON.
    Install { model: String },
    /// Serve installed models through an Ollama-compatible API on loopback.
    Serve {
        #[arg(long, default_value_t = 11435)]
        port: u16,
        /// Restrict this listener to one installed model.
        #[arg(long)]
        model: Option<String>,
    },
}

fn save(
    connection: Connection,
    api_key: Option<String>,
    make_default: bool,
) -> Result<config::Registry> {
    connection.validate()?;
    if connection.provider == ProviderKind::Fritz
        && api_key.as_deref().is_some_and(|key| !key.is_empty())
    {
        bail!("Fritz local models do not use an API key.");
    }
    config::update(|registry| {
        if registry
            .connections
            .iter()
            .any(|c| c.id != connection.id && c.name.eq_ignore_ascii_case(&connection.name))
        {
            bail!("A connection with that name already exists.");
        }
        if connection.provider == ProviderKind::Fritz {
            config::delete_key(connection.id)?;
        }
        if let Some(old) = registry.connections.iter().find(|c| c.id == connection.id)
            && (old.provider != connection.provider || old.base_url() != connection.base_url())
            && api_key.as_deref().is_none_or(str::is_empty)
            && config::key(old.id)?.is_some()
        {
            bail!("Enter a key again when changing the provider or endpoint.");
        }
        if let Some(key) = api_key {
            config::set_key(connection.id, key.trim())?;
        }
        if connection.provider.requires_key() && config::key(connection.id)?.is_none() {
            bail!("This provider requires an API key.");
        }
        if make_default || registry.connections.is_empty() {
            registry.default_connection_id = Some(connection.id);
        }
        if let Some(old) = registry
            .connections
            .iter_mut()
            .find(|c| c.id == connection.id)
        {
            *old = connection;
        } else {
            registry.connections.push(connection);
        }
        Ok(())
    })
}

fn remove(id: Uuid) -> Result<config::Registry> {
    config::update(|registry| {
        if !registry.connections.iter().any(|c| c.id == id) {
            bail!("Provider not found.");
        }
        config::delete_key(id)?;
        registry.connections.retain(|c| c.id != id);
        if registry.default_connection_id == Some(id) {
            registry.default_connection_id = registry.connections.first().map(|c| c.id);
        }
        Ok(())
    })
}

#[derive(Deserialize)]
struct Request {
    id: String,
    method: String,
    #[serde(default)]
    params: Value,
}

async fn dispatch(request: &Request, emit: impl Fn(Value) + Sync) -> Result<Value> {
    let params = &request.params;
    match request.method.as_str() {
        "health" => Ok(
            json!({"name":"fritz","version":env!("CARGO_PKG_VERSION"),"protocolVersion":2,"harness":"fritz-harness"}),
        ),
        "localModels.list" => match params["modelId"].as_str() {
            Some(id) => local::models::inventory_model(id).await,
            None => local::models::inventory().await,
        },
        "localModels.install" => {
            let id = params["modelId"]
                .as_str()
                .context("Choose a local model.")?;
            local::models::download(id, &emit).await?;
            Ok(json!({"modelId":id,"installed":true}))
        }
        "providers.list" => Ok(serde_json::to_value(config::load()?)?),
        "providers.save" => Ok(serde_json::to_value(save(
            serde_json::from_value(params["connection"].clone())?,
            params["apiKey"].as_str().map(str::to_string),
            params["makeDefault"] == true,
        )?)?),
        "providers.remove" => Ok(serde_json::to_value(remove(serde_json::from_value(
            params["id"].clone(),
        )?)?)?),
        "providers.default" => {
            let id: Uuid = serde_json::from_value(params["id"].clone())?;
            Ok(serde_json::to_value(config::update(|registry| {
                if !registry.connections.iter().any(|c| c.id == id) {
                    bail!("Provider not found.");
                }
                registry.default_connection_id = Some(id);
                Ok(())
            })?)?)
        }
        "models.list" => {
            let connection = if params["connection"].is_object() {
                serde_json::from_value(params["connection"].clone())?
            } else {
                config::find(params["connectionId"].as_str())?
            };
            let models = provider::discover(&connection, params["apiKey"].as_str()).await?;
            Ok(json!({"models":models}))
        }
        "chat" => {
            harness_client::chat(serde_json::from_value(params.clone())?, emit).await?;
            Ok(json!({}))
        }
        _ => bail!("Unknown agent method: {}", request.method),
    }
}

async fn agent() -> Result<()> {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(event) = receiver.recv().await {
            let mut bytes = serde_json::to_vec(&event)?;
            bytes.push(b'\n');
            stdout.write_all(&bytes).await?;
            stdout.flush().await?;
        }
        Ok::<_, anyhow::Error>(())
    });
    let mut input = BufReader::new(tokio::io::stdin());
    let mut jobs: HashMap<String, tokio::task::JoinHandle<()>> = HashMap::new();
    while let Some(line) = harness_client::read_line(&mut input, 3_000_000).await? {
        jobs.retain(|_, job| !job.is_finished());
        if line.len() > 3_000_000 {
            let _ = sender.send(json!({"id":"","type":"error","message":"Request too large."}));
            continue;
        }
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                let _ =
                    sender.send(json!({"id":"","type":"error","message":"Invalid request JSON."}));
                continue;
            }
        };
        if jobs.contains_key(&request.id) {
            let _ = sender.send(
                json!({"id":request.id,"type":"error","message":"Request ID is already active."}),
            );
            continue;
        }
        if request.method == "cancel" {
            if let Some(target) = request.params["requestId"].as_str()
                && let Some(job) = jobs.remove(target)
            {
                job.abort();
                let _ = job.await;
                let _ = sender.send(json!({"id":target,"type":"cancelled"}));
            }
            let _ = sender.send(json!({"id":request.id,"type":"result","result":{}}));
            continue;
        }
        let tx = sender.clone();
        // Registry mutations finish in request order; network operations can be cancelled.
        if request.method.starts_with("providers.") {
            let result = dispatch(&request, |_| {}).await;
            let _ = tx.send(envelope(&request.id, result));
        } else {
            jobs.insert(
                request.id.clone(),
                tokio::spawn(async move {
                    let result = dispatch(&request, |mut event| {
                        event["id"] = json!(request.id);
                        let _ = tx.send(event);
                    })
                    .await;
                    let _ = tx.send(envelope(&request.id, result));
                }),
            );
        }
    }
    for job in jobs.values() {
        job.abort();
    }
    for (_, job) in jobs {
        let _ = job.await;
    }
    drop(sender);
    writer.await??;
    Ok(())
}

fn envelope(id: &str, result: Result<Value>) -> Value {
    match result {
        Ok(result) => json!({"id":id,"type":"result","result":result}),
        Err(error) => json!({"id":id,"type":"error","message":error.to_string()}),
    }
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("fritz: {error:#}");
        std::process::exit(1);
    }
}
async fn run() -> Result<()> {
    let cli = Cli::parse();
    if cli.agent {
        return agent().await;
    }
    match cli.command {
        Some(Command::LocalModels { command }) => match command {
            LocalModelCommand::List { model } => {
                let inventory = match model {
                    Some(id) => local::models::inventory_model(&id).await?,
                    None => local::models::inventory().await?,
                };
                println!("{}", serde_json::to_string_pretty(&inventory)?);
            }
            LocalModelCommand::Install { model } => {
                local::models::download(&model, &|event| {
                    println!("{event}");
                    let _ = io::stdout().flush();
                })
                .await?;
            }
            LocalModelCommand::Serve { port, model } => local::ollama::serve(port, model).await?,
        },
        None => {
            use clap::CommandFactory;
            Cli::command().print_help()?;
            println!();
        }
        Some(Command::Providers) => println!("{}", serde_json::to_string_pretty(&config::load()?)?),
        Some(Command::AddProvider {
            name,
            provider,
            base_url,
            model,
            api_key_stdin,
            default,
        }) => {
            let key = if api_key_stdin {
                Some(std::io::read_to_string(io::stdin())?.trim().to_owned())
            } else {
                None
            };
            let connection = Connection {
                id: Uuid::new_v4(),
                name,
                provider,
                base_url,
                model_id: model,
            };
            println!(
                "{}",
                serde_json::to_string_pretty(&save(connection, key, default)?)?
            );
        }
        Some(Command::RemoveProvider { connection }) => {
            remove(config::find(Some(&connection))?.id)?;
        }
        Some(Command::DefaultProvider { connection }) => {
            let id = config::find(Some(&connection))?.id;
            config::update(|registry| {
                registry.default_connection_id = Some(id);
                Ok(())
            })?;
        }
        Some(Command::Models { connection }) => println!(
            "{}",
            serde_json::to_string_pretty(
                &provider::discover(&config::find(connection.as_deref())?, None).await?
            )?
        ),
        Some(Command::Chat {
            prompt,
            connection,
            model,
            effort,
            speed,
            project,
            max_turns,
        }) => {
            let connection = config::find(connection.as_deref())?;
            let model = model.unwrap_or(connection.model_id);
            if model.is_empty() {
                bail!("Pass --model with a model ID from `fritz models`.");
            }
            let prompt = prompt
                .map(Ok)
                .unwrap_or_else(|| std::io::read_to_string(io::stdin()))
                .context("Could not read the prompt.")?;
            if prompt.trim().is_empty() {
                bail!("Enter a prompt.");
            }
            let project = project
                .map(|path| {
                    std::fs::canonicalize(path)
                        .map(|p| p.to_string_lossy().into_owned())
                        .context("Could not open the project folder.")
                })
                .transpose()?;
            harness_client::chat(
                provider::ChatRequest {
                    connection_id: connection.id.to_string(),
                    model,
                    messages: vec![provider::Message {
                        role: "user".into(),
                        content: prompt,
                    }],
                    effort,
                    speed,
                    project_path: project,
                    max_turns: max_turns as usize,
                },
                |event| {
                    if event["type"] == "tool_start" {
                        eprintln!(
                            "[{}] {}",
                            event["name"].as_str().unwrap_or("tool"),
                            event["summary"].as_str().unwrap_or("")
                        );
                    }
                    if event["type"] == "delta"
                        && let Some(text) = event["text"].as_str()
                    {
                        print!("{text}");
                        let _ = io::stdout().flush();
                    }
                },
            )
            .await?;
            println!();
        }
    }
    Ok(())
}
