//! Provider-native tool history. Preserve opaque reasoning/signature fields in memory
//! between tool rounds; never flatten tool calls into assistant prose.
use crate::{
    config::{Connection, ProviderKind},
    provider::{self, ChatRequest},
    tools,
};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashSet},
    sync::Mutex,
};

pub struct Call {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

pub struct Session {
    pub history: Vec<Value>,
    kind: ProviderKind,
    suffix: &'static str,
    base: Value,
}
impl Session {
    pub fn new(connection: &Connection, request: &ChatRequest, system: &str) -> Result<Self> {
        let (suffix, mut base) = provider::payload(connection, request)?;
        let kind = connection.provider;
        let field = match kind {
            ProviderKind::Openai => "input",
            ProviderKind::Gemini => "contents",
            _ => "messages",
        };
        let mut history = base[field]
            .as_array()
            .context("Missing conversation")?
            .clone();
        match kind {
            ProviderKind::Openai => {
                base["instructions"] = json!(system);
                base["include"] = json!(["reasoning.encrypted_content"]);
                base["max_output_tokens"] = json!(8192);
            }
            ProviderKind::Anthropic => base["system"] = json!(system),
            ProviderKind::Gemini => {
                base["systemInstruction"] = json!({"parts":[{"text":system}]});
                base["generationConfig"] = json!({"maxOutputTokens":8192});
            }
            _ => history[0]["content"] = json!(system),
        }
        let defs = tools::definitions();
        base["tools"] = match kind {
            ProviderKind::Openai => json!(defs.iter().map(|d| json!({"type":"function","name":d["name"],"description":d["description"],"parameters":d["parameters"],"strict":false})).collect::<Vec<_>>()),
            ProviderKind::Anthropic => json!(defs.iter().map(|d| json!({"name":d["name"],"description":d["description"],"input_schema":d["parameters"]})).collect::<Vec<_>>()),
            ProviderKind::Gemini => json!([{"functionDeclarations":defs.iter().map(|d| {
                let mut d = d.clone();
                d["parameters"].as_object_mut().unwrap().remove("additionalProperties");
                d
            }).collect::<Vec<_>>()}]),
            _ => json!(defs.iter().map(|d| json!({"type":"function","function":d})).collect::<Vec<_>>()),
        };
        if kind == ProviderKind::Ollama {
            base["options"] = json!({"num_predict":8192});
        }
        Ok(Self {
            history,
            kind,
            suffix,
            base,
        })
    }

    pub async fn turn(
        &mut self,
        connection: &Connection,
        key: Option<&str>,
        request: &ChatRequest,
        emit: &(impl Fn(Value) + Sync),
    ) -> Result<Vec<Call>> {
        let field = match self.kind {
            ProviderKind::Openai => "input",
            ProviderKind::Gemini => "contents",
            _ => "messages",
        };
        let mut body = self.base.clone();
        body[field] = json!(self.history);
        if serde_json::to_vec(&body)?.len() > 2_000_000 {
            bail!("The coding context reached its size limit. Start a new thread.");
        }
        let round = Mutex::new(Round::default());
        provider::stream_body(
            connection,
            key,
            &request.model,
            self.suffix,
            &body,
            emit,
            |v| round.lock().unwrap().push(self.kind, v),
        )
        .await?;
        let round = round.into_inner().unwrap();
        if !round.complete {
            bail!("The provider did not finish a complete tool turn. No tools were executed.");
        }
        let (items, calls) = round.finish(self.kind)?;
        self.history.extend(items);
        Ok(calls)
    }
    pub fn results(&mut self, results: &[(Call, Value, bool)]) {
        match self.kind {
            ProviderKind::Openai => self.history.extend(results.iter().map(|(c,v,_)| json!({"type":"function_call_output","call_id":c.id,"output":v.to_string()}))),
            ProviderKind::Anthropic => self.history.push(json!({"role":"user","content":results.iter().map(|(c,v,e)| json!({"type":"tool_result","tool_use_id":c.id,"content":v.to_string(),"is_error":e})).collect::<Vec<_>>()})),
            ProviderKind::Gemini => self.history.push(json!({"role":"user","parts":results.iter().map(|(c,v,_)| {
                let mut response = json!({"name":c.name,"response":v});
                if !c.id.starts_with("fritz-") { response["id"] = json!(c.id); }
                json!({"functionResponse":response})
            }).collect::<Vec<_>>()})),
            ProviderKind::Ollama => self.history.extend(results.iter().map(|(c,v,_)| json!({"role":"tool","tool_name":c.name,"content":v.to_string()}))),
            _ => self.history.extend(results.iter().map(|(c,v,_)| json!({"role":"tool","tool_call_id":c.id,"content":v.to_string()}))),
        }
    }
}

#[derive(Default)]
struct Round {
    items: BTreeMap<usize, Value>,
    args: BTreeMap<usize, String>,
    text: String,
    reasoning: String,
    reasoning_details: Vec<Value>,
    complete: bool,
}
impl Round {
    fn push(&mut self, kind: ProviderKind, v: &Value) -> Result<()> {
        let index = v["index"].as_u64().unwrap_or(0) as usize;
        if index > 128 {
            bail!("Too many response blocks.");
        }
        match kind {
            ProviderKind::Openai => {
                if v["type"] == "response.completed" {
                    let items = v["response"]["output"]
                        .as_array()
                        .context("Missing response output.")?;
                    self.items = items.iter().cloned().enumerate().collect();
                    self.complete = true;
                }
            }
            ProviderKind::Anthropic => match v["type"].as_str() {
                Some("content_block_start") => {
                    self.items.insert(index, v["content_block"].clone());
                }
                Some("content_block_delta") => {
                    let delta = &v["delta"];
                    if delta["type"] == "input_json_delta" {
                        self.args
                            .entry(index)
                            .or_default()
                            .push_str(delta["partial_json"].as_str().unwrap_or(""));
                    } else {
                        let field = match delta["type"].as_str() {
                            Some("text_delta") => "text",
                            Some("thinking_delta") => "thinking",
                            Some("signature_delta") => "signature",
                            _ => return Ok(()),
                        };
                        let item = self
                            .items
                            .get_mut(&index)
                            .context("Missing content block.")?;
                        let mut text = item[field].as_str().unwrap_or("").to_owned();
                        text.push_str(delta[field].as_str().unwrap_or(""));
                        item[field] = json!(text);
                    }
                }
                Some("message_delta") => {
                    if let Some(reason) = v["delta"]["stop_reason"].as_str()
                        && !matches!(reason, "end_turn" | "tool_use" | "stop_sequence")
                    {
                        bail!("The provider stopped before completing the turn ({reason}).");
                    }
                }
                Some("message_stop") => self.complete = true,
                _ => {}
            },
            ProviderKind::Gemini => {
                if let Some(parts) = v["candidates"][0]["content"]["parts"].as_array() {
                    for part in parts {
                        self.items.insert(self.items.len(), part.clone());
                    }
                }
                if let Some(reason) = v["candidates"][0]["finishReason"].as_str() {
                    if reason != "STOP" {
                        bail!("The provider stopped before completing the turn ({reason}).");
                    }
                    self.complete = true;
                }
            }
            ProviderKind::Ollama => {
                self.text
                    .push_str(v["message"]["content"].as_str().unwrap_or(""));
                self.reasoning
                    .push_str(v["message"]["thinking"].as_str().unwrap_or(""));
                if let Some(calls) = v["message"]["tool_calls"].as_array() {
                    for call in calls {
                        self.items.insert(self.items.len(), call.clone());
                    }
                }
                if v["done"] == true {
                    if v["done_reason"] == "length" {
                        bail!("The provider reached its output limit.");
                    }
                    self.complete = true;
                }
            }
            _ => {
                let delta = &v["choices"][0]["delta"];
                self.text.push_str(delta["content"].as_str().unwrap_or(""));
                self.reasoning
                    .push_str(delta["reasoning_content"].as_str().unwrap_or(""));
                if delta["reasoning_content"].is_null() {
                    self.reasoning
                        .push_str(delta["reasoning"].as_str().unwrap_or(""));
                }
                if let Some(details) = delta["reasoning_details"].as_array() {
                    for detail in details {
                        // Merge indexed fragments without reordering opaque signed blocks.
                        let index = detail["index"].as_u64();
                        let existing = self.reasoning_details.iter_mut().find(|d| {
                            index.is_some()
                                && d["index"].as_u64() == index
                                && d["type"] == detail["type"]
                        });
                        if let Some(existing) = existing {
                            for (field, value) in
                                detail.as_object().context("Invalid reasoning detail.")?
                            {
                                if matches!(
                                    field.as_str(),
                                    "text" | "summary" | "signature" | "data"
                                ) {
                                    let mut joined =
                                        existing[field].as_str().unwrap_or("").to_owned();
                                    joined.push_str(
                                        value.as_str().context("Invalid reasoning fragment.")?,
                                    );
                                    existing[field] = json!(joined);
                                } else if !value.is_null() {
                                    existing[field] = value.clone();
                                }
                            }
                        } else {
                            self.reasoning_details.push(detail.clone());
                        }
                    }
                }
                if let Some(calls) = delta["tool_calls"].as_array() {
                    for call in calls {
                        let i =
                            call["index"].as_u64().context("Missing tool call index.")? as usize;
                        if i >= 64 {
                            bail!("Too many tool calls in one turn.");
                        }
                        let item=self.items.entry(i).or_insert_with(|| json!({"type":"function","id":"","function":{"name":"","arguments":""}}));
                        if let Some(id) = call["id"].as_str() {
                            item["id"] = json!(id);
                        }
                        for field in ["name", "arguments"] {
                            let mut text =
                                item["function"][field].as_str().unwrap_or("").to_owned();
                            text.push_str(call["function"][field].as_str().unwrap_or(""));
                            item["function"][field] = json!(text);
                        }
                    }
                }
                if let Some(reason) = v["choices"][0]["finish_reason"].as_str() {
                    if !matches!(reason, "stop" | "tool_calls") {
                        bail!("The provider stopped before completing the turn ({reason}).");
                    }
                    self.complete = true;
                }
            }
        }
        Ok(())
    }
    fn finish(mut self, kind: ProviderKind) -> Result<(Vec<Value>, Vec<Call>)> {
        for (i, args) in &self.args {
            self.items.get_mut(i).context("Missing tool block.")?["input"] =
                serde_json::from_str(args).context("Invalid tool arguments; no tools executed.")?;
        }
        let mut calls = vec![];
        let mut seen = HashSet::new();
        for (i, item) in &self.items {
            let call = match kind {
                ProviderKind::Openai if item["type"] == "function_call" => Some(Call {
                    id: required(item, "call_id")?,
                    name: required(item, "name")?,
                    arguments: required(item, "arguments")?,
                }),
                ProviderKind::Anthropic if item["type"] == "tool_use" => Some(Call {
                    id: required(item, "id")?,
                    name: required(item, "name")?,
                    arguments: item["input"].to_string(),
                }),
                ProviderKind::Gemini if item["functionCall"].is_object() => Some(Call {
                    id: item["functionCall"]["id"]
                        .as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| format!("fritz-{i}")),
                    name: required(&item["functionCall"], "name")?,
                    arguments: item["functionCall"]["args"].to_string(),
                }),
                ProviderKind::Ollama => Some(Call {
                    id: format!("fritz-{i}"),
                    name: required(&item["function"], "name")?,
                    arguments: item["function"]["arguments"].to_string(),
                }),
                ProviderKind::OpenaiCompatible | ProviderKind::Openrouter => Some(Call {
                    id: required(item, "id")?,
                    name: required(&item["function"], "name")?,
                    arguments: required(&item["function"], "arguments")?,
                }),
                _ => None,
            };
            if let Some(call) = call {
                if !seen.insert(call.id.clone()) {
                    bail!("The provider reused a tool call ID.");
                }
                if call.arguments.len() > 600_000 {
                    bail!("Tool arguments exceeded the size limit.");
                }
                calls.push(call);
            }
        }
        let items = self.items.into_values().collect::<Vec<_>>();
        let history = match kind {
            ProviderKind::Openai => items,
            ProviderKind::Anthropic => vec![json!({"role":"assistant","content":items})],
            ProviderKind::Gemini => vec![json!({"role":"model","parts":items})],
            _ => {
                let mut message = json!({"role":"assistant","content":self.text});
                if !items.is_empty() {
                    message["tool_calls"] = json!(items);
                }
                if !self.reasoning_details.is_empty() {
                    message["reasoning_details"] = json!(self.reasoning_details);
                }
                if !self.reasoning.is_empty() {
                    message[if kind == ProviderKind::Ollama {
                        "thinking"
                    } else {
                        "reasoning_content"
                    }] = json!(self.reasoning);
                }
                vec![message]
            }
        };
        Ok((history, calls))
    }
}
fn required(v: &Value, field: &str) -> Result<String> {
    v[field]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .with_context(|| format!("Missing tool {field}."))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fragmented_parallel_calls_and_reasoning_are_preserved() {
        let mut r = Round::default();
        r.push(ProviderKind::OpenaiCompatible,&json!({"choices":[{"delta":{"reasoning_content":"opaque","tool_calls":[{"index":0,"id":"a","function":{"name":"read_file","arguments":"{\"path\":"}},{"index":1,"id":"b","function":{"name":"list_files","arguments":"{\"path\":\".\"}"}}]}}]})).unwrap();
        r.push(ProviderKind::OpenaiCompatible,&json!({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a.txt\"}"}}]},"finish_reason":"tool_calls"}]})).unwrap();
        let (history, calls) = r.finish(ProviderKind::OpenaiCompatible).unwrap();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].arguments, "{\"path\":\"a.txt\"}");
        assert_eq!(history[0]["reasoning_content"], "opaque");
    }
    #[test]
    fn signed_provider_content_is_kept() {
        let mut router = Round::default();
        for data in ["opaque-", "signature"] {
            router.push(ProviderKind::Openrouter, &json!({"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","index":0,"data":data,"format":"anthropic-claude-v1"}]}}]})).unwrap();
        }
        let (history, _) = router.finish(ProviderKind::Openrouter).unwrap();
        assert_eq!(
            history[0]["reasoning_details"][0]["data"],
            "opaque-signature"
        );
        let mut r = Round::default();
        r.push(ProviderKind::Gemini,&json!({"candidates":[{"content":{"parts":[{"functionCall":{"name":"list_files","args":{"path":"."}},"thoughtSignature":"opaque"}]},"finishReason":"STOP"}]})).unwrap();
        let (history, calls) = r.finish(ProviderKind::Gemini).unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(history[0]["parts"][0]["thoughtSignature"], "opaque");
        let mut r = Round::default();
        r.push(ProviderKind::Openai,&json!({"type":"response.completed","response":{"output":[{"type":"reasoning","encrypted_content":"opaque"},{"type":"function_call","call_id":"a","name":"read_file","arguments":"{}"}]}})).unwrap();
        let (history, calls) = r.finish(ProviderKind::Openai).unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(history[0]["encrypted_content"], "opaque");
    }
}
