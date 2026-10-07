use fritz::{config, decision, decision_client, harness_client, local, provider};

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
    /// Install or inspect local decision models (no daemon).
    DecisionModels {
        #[command(subcommand)]
        command: DecisionModelCommand,
    },
    /// Evaluate typed decision questions from a JSON file, or stdin with "-".
    Decide {
        #[arg(long)]
        connection: String,
        #[arg(default_value = "-")]
        request: String,
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
        /// Attach a folder for file actions (local processes run with your user permissions).
        #[arg(long)]
        project: Option<String>,
        #[arg(long, default_value_t = 24, value_parser = clap::value_parser!(u32).range(1..=40))]
        max_turns: u32,
    },
}

#[derive(Subcommand)]
enum LocalModelCommand {
    /// Show the pinned catalog and file-presence installation status.
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
        /// Private app supervision over stdin/stdout.
        #[arg(long, hide = true)]
        managed: bool,
    },
}

#[derive(Subcommand)]
enum DecisionModelCommand {
    List { model: Option<String> },
    Install { model: String },
}

fn models_service() -> Result<fritz::models_service::ModelsService> {
    Ok(fritz::models_service::ModelsService::new(
        config::RegistryStore::new(config::data_dir()),
        config::CredentialStore::new(config::keychain_service())?,
        local::models::ModelStore::new(config::models_dir()),
        decision::local::ModelStore::new(config::models_dir()),
        config::ModelLocationStore::new(config::data_dir()),
    ))
}
fn save(
    connection: Connection,
    api_key: Option<String>,
    make_default: bool,
) -> Result<config::Registry> {
    models_service()?.save(connection, api_key, make_default)
}
fn remove(id: Uuid) -> Result<config::Registry> {
    models_service()?.remove(id)
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
    if let Some(result) = models_service()?
        .dispatch(&request.method, params, &emit)
        .await?
    {
        return Ok(result);
    }
    match request.method.as_str() {
        "health" => Ok(
            json!({"name":"fritz","version":env!("CARGO_PKG_VERSION"),"protocolVersion":2,"harness":"fritz-harness"}),
        ),
        "chat" => {
            harness_client::chat(serde_json::from_value(params.clone())?, emit).await?;
            Ok(json!({}))
        }
        "decisions.evaluate" => {
            let executable = std::env::current_exe()?
                .parent()
                .context("Missing executable directory")?
                .join("fritz-decision-harness");
            let input: decision::HarnessInput = if let Some(id) = params["connectionId"].as_str() {
                let connection = config::find(Some(id))?;
                let request: decision::DecisionRequest =
                    serde_json::from_value(params["request"].clone())?;
                let (backend, api_key) = match connection.provider {
                    ProviderKind::Jev => {
                        if request.model != "jev-latest" {
                            bail!("Jev currently supports the jev-latest model.");
                        }
                        (
                            decision::HarnessBackend::Jev { endpoint: None },
                            config::key(connection.id)?,
                        )
                    }
                    ProviderKind::Ollaya => {
                        decision::local::manifest(&request.model)?;
                        (decision::HarnessBackend::Ollaya, None)
                    }
                    _ => bail!("Choose a decision-model connection."),
                };
                decision::HarnessInput {
                    request,
                    model_store: if matches!(backend, decision::HarnessBackend::Ollaya) {
                        Some(decision::local::ModelStore::configured()?.configuration())
                    } else {
                        None
                    },
                    backend,
                    api_key,
                }
            } else {
                serde_json::from_value(params.clone())?
            };
            Ok(serde_json::to_value(
                decision_client::evaluate_with_input(&executable, input).await?,
            )?)
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
    let result = run().await;
    local::shutdown().await;
    if let Err(error) = result {
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
            LocalModelCommand::Serve {
                port,
                model,
                managed,
            } => local::ollama::serve(port, model, managed).await?,
        },
        Some(Command::DecisionModels { command }) => {
            let store = decision::local::ModelStore::configured()?;
            match command {
                DecisionModelCommand::List { model } => println!(
                    "{}",
                    serde_json::to_string_pretty(&store.inventory(model.as_deref()).await?)?
                ),
                DecisionModelCommand::Install { model } => {
                    store
                        .download(&model, &|event| {
                            println!("{event}");
                            let _ = io::stdout().flush();
                        })
                        .await?
                }
            }
        }
        Some(Command::Decide {
            connection,
            request,
        }) => {
            let bytes = if request == "-" {
                std::io::read_to_string(io::stdin())?
            } else {
                std::fs::read_to_string(request)?
            };
            let request: decision::DecisionRequest = serde_json::from_str(&bytes)?;
            let result = dispatch(&Request { id: "cli-decision".into(), method: "decisions.evaluate".into(),
                params: json!({"connectionId":config::find(Some(&connection))?.id,"request":request}) }, |_| {}).await?;
            println!("{}", serde_json::to_string_pretty(&result)?);
        }
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
            let connection = config::find(Some(&connection))?;
            if connection.provider.category() != config::ModelCategory::Llm {
                bail!("Only an LLM provider can be the default chat provider.");
            }
            let id = connection.id;
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
