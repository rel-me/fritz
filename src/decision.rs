//! Typed judgments shared by remote and future local decision models.
//! Decision models return values for application code; they do not generate chat replies.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, future::Future, pin::Pin, time::Duration};

pub type DecisionFuture<'a> = Pin<Box<dyn Future<Output = Result<DecisionResponse>> + Send + 'a>>;

/// A local model can implement this same interface without using Jev's HTTP API.
pub trait DecisionModel: Send + Sync {
    fn evaluate<'a>(&'a self, request: &'a DecisionRequest) -> DecisionFuture<'a>;
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct DecisionRequest {
    pub state: Value,
    pub model: String,
    pub questions: BTreeMap<String, Question>,
}

/// Private-pipe input to the bundled decision harness. The API key is never persisted.
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HarnessInput {
    pub request: DecisionRequest,
    pub backend: HarnessBackend,
    pub api_key: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum HarnessBackend {
    Jev { endpoint: Option<String> },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Question {
    Noul {
        instructions: Value,
        #[serde(skip_serializing_if = "Option::is_none")]
        criteria: Option<Value>,
    },
    Choice {
        instructions: Value,
        criteria: BTreeMap<String, Value>,
    },
    Score {
        instructions: Value,
        criteria: Vec<Value>,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct DecisionResponse {
    pub model: String,
    pub answers: BTreeMap<String, Answer>,
    #[serde(default)]
    pub usage: Option<Usage>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Answer {
    Noul {
        noul: f64,
    },
    Choice {
        choice: String,
        probabilities: BTreeMap<String, f64>,
        confidence: f64,
    },
    Score {
        score: f64,
        legend: BTreeMap<String, String>,
        probabilities: BTreeMap<String, f64>,
        confidence: f64,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

impl DecisionRequest {
    pub fn validate(&self) -> Result<()> {
        if self.model.trim().is_empty() {
            bail!("Choose a decision model.");
        }
        if self.state.is_null() || self.questions.is_empty() || self.questions.len() > 64 {
            bail!("Supply state and between 1 and 64 decision questions.");
        }
        if serde_json::to_vec(self)?.len() > 2_000_000 {
            bail!("Decision request exceeds its size limit.");
        }
        for (id, question) in &self.questions {
            if id.trim().is_empty() {
                bail!("Decision question IDs cannot be empty.");
            }
            let instructions = match question {
                Question::Noul { instructions, .. }
                | Question::Choice { instructions, .. }
                | Question::Score { instructions, .. } => instructions,
            };
            if instructions.is_null() || instructions.as_str().is_some_and(|s| s.trim().is_empty())
            {
                bail!("Decision question {id} needs instructions.");
            }
            match question {
                Question::Choice { criteria, .. }
                    if criteria.len() < 2
                        || criteria.len() > 255
                        || criteria.keys().any(|option| option.trim().is_empty()) =>
                {
                    bail!("Decision choice {id} needs 2 to 255 named options.");
                }
                Question::Score { criteria, .. } if !(2..=10).contains(&criteria.len()) => {
                    bail!("Decision score {id} needs 2 to 10 levels.");
                }
                _ => {}
            }
        }
        Ok(())
    }
}

impl DecisionResponse {
    pub fn validate_for(&self, request: &DecisionRequest) -> Result<()> {
        if self.model.trim().is_empty() || self.answers.len() != request.questions.len() {
            bail!("The decision model returned an incomplete response.");
        }
        for (id, question) in &request.questions {
            let answer = self
                .answers
                .get(id)
                .with_context(|| format!("The decision model omitted question {id}."))?;
            match (question, answer) {
                (Question::Noul { .. }, Answer::Noul { noul }) if probability(*noul) => {}
                (
                    Question::Choice { criteria, .. },
                    Answer::Choice {
                        choice,
                        probabilities,
                        confidence,
                    },
                ) if criteria.contains_key(choice)
                    && criteria.keys().eq(probabilities.keys())
                    && probability(*confidence)
                    && distribution(probabilities.values().copied()) => {}
                (
                    Question::Score { criteria, .. },
                    Answer::Score {
                        score,
                        legend,
                        probabilities,
                        confidence,
                    },
                ) if score.is_finite()
                    && *score >= 0.0
                    && *score <= (criteria.len() - 1) as f64
                    && legend.len() == criteria.len()
                    && probabilities.len() == criteria.len()
                    && (0..criteria.len()).all(|level| {
                        let key = level.to_string();
                        legend.contains_key(&key) && probabilities.contains_key(&key)
                    })
                    && probability(*confidence)
                    && distribution(probabilities.values().copied()) => {}
                _ => bail!("The decision model returned an invalid answer for {id}."),
            }
        }
        Ok(())
    }
}

fn probability(value: f64) -> bool {
    value.is_finite() && (0.0..=1.0).contains(&value)
}

fn distribution(values: impl Iterator<Item = f64>) -> bool {
    let mut count = 0;
    let mut sum = 0.0;
    for value in values {
        if !probability(value) {
            return false;
        }
        count += 1;
        sum += value;
    }
    count > 0 && (sum - 1.0_f64).abs() <= 0.02
}

/// Remote TypeSafe Jev adapter. The credential stays in memory and is never logged.
pub struct Jev {
    client: reqwest::Client,
    endpoint: reqwest::Url,
    api_key: String,
}

impl Jev {
    pub fn new(api_key: impl Into<String>) -> Result<Self> {
        Self::with_endpoint(api_key, "https://api.typesafe.ai/v1/systemone")
    }

    /// Allows an explicit loopback endpoint for isolated tests and host-managed proxies.
    pub fn with_endpoint(api_key: impl Into<String>, endpoint: &str) -> Result<Self> {
        let api_key = api_key.into();
        if api_key.trim().is_empty() {
            bail!("Jev requires an API key.");
        }
        let endpoint = reqwest::Url::parse(endpoint).context("Invalid Jev endpoint.")?;
        if !matches!(endpoint.scheme(), "https" | "http")
            || endpoint.host_str().is_none()
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
            || (endpoint.scheme() == "http"
                && !matches!(
                    endpoint.host_str(),
                    Some("localhost" | "127.0.0.1" | "[::1]")
                ))
        {
            bail!("Jev requires HTTPS, or HTTP on loopback for tests.");
        }
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

impl DecisionModel for Jev {
    fn evaluate<'a>(&'a self, request: &'a DecisionRequest) -> DecisionFuture<'a> {
        Box::pin(async move {
            request.validate()?;
            let response = self
                .client
                .post(self.endpoint.clone())
                .bearer_auth(&self.api_key)
                .json(request)
                .send()
                .await
                .context("Could not reach Jev.")?;
            if !response.status().is_success() {
                bail!(
                    "Jev rejected the decision request (HTTP {}).",
                    response.status()
                );
            }
            let bytes = response
                .bytes()
                .await
                .context("Could not read Jev's response.")?;
            if bytes.len() > 2_000_000 {
                bail!("Jev's decision response exceeded its size limit.");
            }
            let answer: DecisionResponse = serde_json::from_slice(&bytes)
                .context("Jev returned an invalid decision response.")?;
            answer.validate_for(request)?;
            Ok(answer)
        })
    }
}

pub async fn evaluate(
    model: &impl DecisionModel,
    request: &DecisionRequest,
) -> Result<DecisionResponse> {
    request.validate()?;
    let response = model.evaluate(request).await?;
    response.validate_for(request)?;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn response_must_match_questions_and_distributions() {
        let request: DecisionRequest = serde_json::from_value(json!({
            "model":"jev-latest", "state":{"message":"Please remind me tomorrow"},
            "questions":{"intent":{"type":"choice","instructions":"What is requested?",
                "criteria":{"reminder":null,"other":null}},
                "urgent":{"type":"noul","instructions":"Is this urgent?"}}
        }))
        .unwrap();
        request.validate().unwrap();
        let mut response: DecisionResponse = serde_json::from_value(json!({
            "model":"jev-1.13.0","answers":{
                "intent":{"type":"choice","choice":"reminder","probabilities":{"reminder":0.9,"other":0.1},"confidence":0.8},
                "urgent":{"type":"noul","noul":0.2}
            },"usage":{"input_tokens":40,"output_tokens":10}
        })).unwrap();
        response.validate_for(&request).unwrap();
        if let Answer::Choice { probabilities, .. } = response.answers.get_mut("intent").unwrap() {
            probabilities.insert("other".into(), 1.5);
        }
        assert!(response.validate_for(&request).is_err());
        response.answers.remove("urgent");
        assert!(response.validate_for(&request).is_err());
    }

    struct LocalFixture;

    impl DecisionModel for LocalFixture {
        fn evaluate<'a>(&'a self, _request: &'a DecisionRequest) -> DecisionFuture<'a> {
            Box::pin(async {
                Ok(DecisionResponse {
                    model: "local-fixture-v1".into(),
                    answers: BTreeMap::from([("presence".into(), Answer::Noul { noul: 0.75 })]),
                    usage: None,
                })
            })
        }
    }

    #[tokio::test]
    async fn local_model_uses_the_same_contract() {
        let request: DecisionRequest = serde_json::from_value(json!({
            "model":"local-fixture-v1","state":{"note":"Take a walk"},
            "questions":{"presence":{"type":"noul","instructions":"Is a walk mentioned?"}}
        }))
        .unwrap();
        let response = evaluate(&LocalFixture, &request).await.unwrap();
        assert_eq!(response.model, "local-fixture-v1");
        assert!(matches!(
            response.answers["presence"],
            Answer::Noul { noul: 0.75 }
        ));
    }
}
