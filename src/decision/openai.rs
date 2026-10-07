//! OpenAI Decisions transport, translated into Fritz's backend-neutral judgments.
use super::{
    Answer, DecisionFuture, DecisionModel, DecisionRequest, DecisionResponse, Question, Usage,
};
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::BTreeMap, time::Duration};

pub struct OpenAI {
    client: reqwest::Client,
    endpoint: reqwest::Url,
    api_key: String,
}

impl OpenAI {
    /// The endpoint is the full Decisions URL. HTTP is allowed only on loopback.
    pub fn with_endpoint(api_key: String, endpoint: &str) -> Result<Self> {
        ensure!(
            !api_key.trim().is_empty(),
            "OpenAI Decisions requires an API key."
        );
        let endpoint =
            reqwest::Url::parse(endpoint).context("Invalid OpenAI Decisions endpoint.")?;
        ensure!(
            matches!(endpoint.scheme(), "https" | "http")
                && endpoint.host_str().is_some()
                && endpoint.username().is_empty()
                && endpoint.password().is_none()
                && endpoint.query().is_none()
                && endpoint.fragment().is_none()
                && (endpoint.scheme() == "https"
                    || matches!(
                        endpoint.host_str(),
                        Some("localhost" | "127.0.0.1" | "[::1]")
                    )),
            "OpenAI Decisions requires HTTPS, or HTTP on loopback for tests."
        );
        Ok(Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .redirect(reqwest::redirect::Policy::none())
                .build()?,
            endpoint,
            api_key,
        })
    }
}

fn text(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string())
}

fn payload(request: &DecisionRequest) -> Result<Value> {
    request.validate()?;
    ensure!(
        request.model == "gpt-6-luna",
        "OpenAI Decisions currently supports gpt-6-luna."
    );
    let questions: Vec<Value> = request.questions.iter().map(|(name, question)| match question {
        Question::Noul { instructions, criteria } => {
            let instructions = match criteria {
                Some(criteria) => format!("{}\nCriteria: {}", text(instructions), text(criteria)),
                None => text(instructions),
            };
            json!({"type":"predicate", "name":name, "instructions":instructions})
        }
        Question::Choice { instructions, criteria } => json!({
            "type":"choice", "name":name, "instructions":text(instructions),
            "choices":criteria.iter().map(|(value, description)| json!({"value":value,"description":text(description)})).collect::<Vec<_>>()
        }),
        Question::Score { instructions, criteria } => json!({
            "type":"score", "name":name, "instructions":text(instructions),
            "levels":criteria.iter().enumerate().map(|(i, description)| json!({"label":i.to_string(),"description":text(description)})).collect::<Vec<_>>()
        }),
    }).collect();
    // JSON state is shared evidence, never interpreted as messages or instructions.
    Ok(json!({"model":request.model,"input":text(&request.state),"questions":questions}))
}

#[derive(Deserialize)]
struct Response {
    model: String,
    answers: Vec<NamedAnswer>,
    usage: Usage,
}
#[derive(Deserialize)]
struct NamedAnswer {
    name: Option<String>,
    #[serde(flatten)]
    answer: WireAnswer,
}
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum WireAnswer {
    Predicate {
        probability: f64,
    },
    Choice {
        choice: String,
        confidence: f64,
        probabilities: Vec<ChoiceProbability>,
    },
    Score {
        score: f64,
        confidence: f64,
        probabilities: Vec<ScoreProbability>,
    },
    Refusal,
}
#[derive(Deserialize)]
struct ChoiceProbability {
    value: String,
    probability: f64,
}
#[derive(Deserialize)]
struct ScoreProbability {
    value: usize,
    label: String,
    probability: f64,
}

fn translate(response: Response, request: &DecisionRequest) -> Result<DecisionResponse> {
    ensure!(
        response.answers.len() == request.questions.len(),
        "OpenAI Decisions returned an incomplete response."
    );
    let mut answers = BTreeMap::new();
    for (wire, (id, question)) in response.answers.into_iter().zip(&request.questions) {
        ensure!(
            wire.name.as_deref() == Some(id),
            "OpenAI Decisions returned mismatched question names or order."
        );
        let answer = match (wire.answer, question) {
            (WireAnswer::Refusal, _) => {
                bail!("OpenAI Decisions refused a question. Revise the decision input or question.")
            }
            (WireAnswer::Predicate { probability }, Question::Noul { .. }) => {
                Answer::Noul { noul: probability }
            }
            (
                WireAnswer::Choice {
                    choice,
                    confidence,
                    probabilities,
                },
                Question::Choice { criteria, .. },
            ) => {
                let count = probabilities.len();
                let probabilities: BTreeMap<_, _> = probabilities
                    .into_iter()
                    .map(|p| (p.value, p.probability))
                    .collect();
                ensure!(
                    count == probabilities.len() && count == criteria.len(),
                    "OpenAI Decisions returned duplicate or missing choices."
                );
                Answer::Choice {
                    choice,
                    confidence,
                    probabilities,
                }
            }
            (
                WireAnswer::Score {
                    score,
                    confidence,
                    probabilities,
                },
                Question::Score { criteria, .. },
            ) => {
                let count = probabilities.len();
                let mut mapped = BTreeMap::new();
                for p in probabilities {
                    ensure!(
                        p.value < criteria.len() && p.label == p.value.to_string(),
                        "OpenAI Decisions returned an unknown score level."
                    );
                    ensure!(
                        mapped.insert(p.label, p.probability).is_none(),
                        "OpenAI Decisions returned duplicate score levels."
                    );
                }
                ensure!(
                    count == criteria.len(),
                    "OpenAI Decisions returned missing score levels."
                );
                Answer::Score {
                    score,
                    confidence,
                    probabilities: mapped,
                    legend: criteria
                        .iter()
                        .enumerate()
                        .map(|(i, v)| (i.to_string(), v.clone()))
                        .collect(),
                }
            }
            _ => bail!("OpenAI Decisions returned an unexpected answer type."),
        };
        answers.insert(id.clone(), answer);
    }
    let result = DecisionResponse {
        model: response.model,
        answers,
        usage: Some(response.usage),
    };
    result.validate_for(request)?;
    Ok(result)
}

impl DecisionModel for OpenAI {
    fn evaluate<'a>(&'a self, request: &'a DecisionRequest) -> DecisionFuture<'a> {
        Box::pin(async move {
            let body = payload(request)?;
            let mut response = self
                .client
                .post(self.endpoint.clone())
                .bearer_auth(&self.api_key)
                .json(&body)
                .send()
                .await
                .context("Could not reach OpenAI Decisions.")?;
            ensure!(
                response.status().is_success(),
                "OpenAI Decisions rejected the request (HTTP {}). Check API access, the key, and request limits.",
                response.status()
            );
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .context("Could not read OpenAI Decisions' response.")?
            {
                ensure!(
                    bytes.len() + chunk.len() <= 2_000_000,
                    "OpenAI Decisions' response exceeded its size limit."
                );
                bytes.extend_from_slice(&chunk);
            }
            let response = serde_json::from_slice(&bytes)
                .context("OpenAI Decisions returned an invalid response.")?;
            translate(response, request)
        })
    }
}
