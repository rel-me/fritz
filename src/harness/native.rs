//! Provider-native tool history. Preserve opaque reasoning/signature fields in memory
//! between tool rounds; never flatten tool calls into assistant prose.
use crate::{
    config::{Connection, ProviderKind},
    provider::{self, ChatRequest},
};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashSet},
    sync::Mutex,
};

pub use fritz_harness::ToolCall as Call;
use fritz_harness::{ToolDefinition, ToolResult};

struct ReceiptSlot {
    call: Call,
    message: usize,
    part: Option<usize>,
    image_message: Option<usize>,
    inline_images: Vec<usize>,
    failed: bool,
}

pub struct Session {
    pub history: Vec<Value>,
    kind: ProviderKind,
    suffix: &'static str,
    base: Value,
    receipts: Vec<ReceiptSlot>,
    strict_tools: bool,
    request_byte_limit: usize,
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
        if kind == ProviderKind::Ollama {
            base["options"] = json!({"num_predict":8192});
        }
        Ok(Self {
            history,
            kind,
            suffix,
            base,
            receipts: Vec::new(),
            strict_tools: false,
            request_byte_limit: 2_000_000,
        })
    }

    pub fn append_user(&mut self, content: &str) {
        self.history.push(match self.kind {
            ProviderKind::Gemini => json!({"role":"user","parts":[{"text":content}]}),
            _ => json!({"role":"user","content":content}),
        });
    }

    pub fn set_request_byte_limit(&mut self, limit: usize) {
        self.request_byte_limit = limit;
    }

    pub fn set_strict_tools(&mut self, strict: bool) {
        self.strict_tools = strict;
    }

    pub fn set_parameters(&mut self, parameters: Value) -> Result<()> {
        let parameters = parameters
            .as_object()
            .context("Provider parameters must be an object.")?;
        for (key, value) in parameters {
            if ![
                "reasoning",
                "reasoning_effort",
                "service_tier",
                "prompt_cache_key",
                "prompt_cache_retention",
                "provider",
                "max_tokens",
                "max_completion_tokens",
                "store",
                "cache_control",
            ]
            .contains(&key.as_str())
            {
                bail!("Unsupported host provider parameter: {key}");
            }
            if key == "store" && value != false {
                bail!("Response storage must remain disabled.");
            }
            self.base[key] = value.clone();
        }
        Ok(())
    }

    pub fn replace_result(&mut self, id: &str, mut replacement: ToolResult) -> Result<()> {
        let Some(slot) = self.receipts.iter().find(|slot| slot.call.id == id) else {
            return Ok(());
        };
        replacement.failed = slot.failed;
        let mut encoded = Self {
            history: Vec::new(),
            kind: self.kind,
            suffix: "",
            base: json!({}),
            receipts: Vec::new(),
            strict_tools: false,
            request_byte_limit: 2_000_000,
        };
        encoded.results(&[(slot.call.clone(), replacement)])?;
        match self.kind {
            ProviderKind::Anthropic => {
                self.history[slot.message]["content"][slot.part.unwrap()] =
                    encoded.history[0]["content"][0].clone()
            }
            ProviderKind::Gemini => {
                self.history[slot.message]["parts"][slot.part.unwrap()] =
                    encoded.history[0]["parts"][0].clone();
                for (index, destination) in slot.inline_images.iter().enumerate() {
                    self.history[slot.message]["parts"][*destination] = encoded.history[0]["parts"].get(index + 1).cloned().unwrap_or_else(|| json!({"text":"Earlier tool image omitted; request visual recall if needed."}));
                }
            }
            _ => self.history[slot.message] = encoded.history[0].clone(),
        }
        if let Some(index) = slot.image_message {
            self.history[index] = encoded.history.get(1).cloned().unwrap_or_else(|| json!({"role":"user","content":"Earlier tool image omitted; request visual recall if needed."}));
        }
        Ok(())
    }

    /// Change host instructions without rewriting opaque provider history.
    pub fn set_instructions(&mut self, system: &str) {
        match self.kind {
            ProviderKind::Openai => self.base["instructions"] = json!(system),
            ProviderKind::Anthropic => self.base["system"] = json!(system),
            ProviderKind::Gemini => {
                self.base["systemInstruction"] = json!({"parts":[{"text":system}]})
            }
            _ => self.history[0]["content"] = json!(system),
        }
    }

    pub fn set_output_limit(&mut self, limit: Option<usize>) {
        match self.kind {
            ProviderKind::Openai => {
                self.base
                    .as_object_mut()
                    .unwrap()
                    .remove("max_output_tokens");
                if let Some(limit) = limit {
                    self.base["max_output_tokens"] = json!(limit);
                }
            }
            ProviderKind::Gemini => {
                self.base["generationConfig"]
                    .as_object_mut()
                    .unwrap()
                    .remove("maxOutputTokens");
                if let Some(limit) = limit {
                    self.base["generationConfig"]["maxOutputTokens"] = json!(limit);
                }
            }
            ProviderKind::Ollama => {
                self.base["options"]
                    .as_object_mut()
                    .unwrap()
                    .remove("num_predict");
                if let Some(limit) = limit {
                    self.base["options"]["num_predict"] = json!(limit);
                }
            }
            _ => {
                self.base.as_object_mut().unwrap().remove("max_tokens");
                if let Some(limit) = limit {
                    self.base["max_tokens"] = json!(limit);
                }
            }
        }
    }

    pub fn set_tools(&mut self, definitions: &[ToolDefinition]) -> Result<()> {
        self.base.as_object_mut().unwrap().remove("tools");
        if !definitions.is_empty() {
            let defs = definitions
                .iter()
                .map(serde_json::to_value)
                .collect::<Result<Vec<_>, _>>()?;
            self.base["tools"] = match self.kind {
            ProviderKind::Openai => json!(defs.iter().map(|d| {
                let tool = fritz_harness::ResponsesToolDefinition::function(d["name"].as_str().unwrap(), d["description"].as_str().unwrap(), d["parameters"].clone());
                if self.strict_tools { tool.with_strict() } else { tool }
            }).collect::<Vec<_>>()),
            ProviderKind::Anthropic => json!(defs.iter().map(|d| json!({"name":d["name"],"description":d["description"],"input_schema":d["parameters"]})).collect::<Vec<_>>()),
            ProviderKind::Gemini => json!([{"functionDeclarations":defs.iter().map(|d| {
                let mut d = d.clone();
                d["parameters"].as_object_mut().unwrap().remove("additionalProperties");
                d
            }).collect::<Vec<_>>()}]),
            _ => json!(defs.iter().map(|d| json!({"type":"function","function":d})).collect::<Vec<_>>()),
        };
        }
        Ok(())
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
        if serde_json::to_vec(&body)?.len() > self.request_byte_limit {
            bail!("The conversation context reached its size limit. Start a new thread.");
        }
        let round = Mutex::new(Round::default());
        let previews = Mutex::new(BTreeMap::<usize, Preview>::new());
        provider::stream_body(
            connection,
            key,
            &request.model,
            self.suffix,
            &body,
            emit,
            |v| {
                round.lock().unwrap().push(self.kind, v)?;
                preview(self.kind, v, &mut previews.lock().unwrap(), emit);
                Ok(())
            },
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
    pub fn results(&mut self, results: &[(Call, ToolResult)]) -> Result<()> {
        let start = self.history.len();
        for (_, result) in results {
            for image in &result.images {
                if !["image/png", "image/jpeg", "image/webp", "image/gif"]
                    .contains(&image.media_type.as_str())
                {
                    bail!("Unsupported image media type.");
                }
            }
        }
        match self.kind {
            ProviderKind::Openai => self.history.extend(results.iter().map(|(c,r)| {
                let output = if r.images.is_empty() { json!(r.value.as_str().map(str::to_owned).unwrap_or_else(|| r.value.to_string())) } else {
                    let mut parts = vec![json!({"type":"input_text","text":r.value.as_str().map(str::to_owned).unwrap_or_else(|| r.value.to_string())})];
                    parts.extend(r.images.iter().map(|i| json!({"type":"input_image","image_url":format!("data:{};base64,{}",i.media_type,i.base64)})));
                    json!(parts)
                };
                json!({"type":"function_call_output","call_id":c.id,"output":output})
            })),
            ProviderKind::Anthropic => self.history.push(json!({"role":"user","content":results.iter().map(|(c,r)| {
                let mut content = vec![json!({"type":"text","text":r.value.as_str().map(str::to_owned).unwrap_or_else(|| r.value.to_string())})];
                content.extend(r.images.iter().map(|i| json!({"type":"image","source":{"type":"base64","media_type":i.media_type,"data":i.base64}})));
                json!({"type":"tool_result","tool_use_id":c.id,"content":content,"is_error":r.failed})
            }).collect::<Vec<_>>()})),
            ProviderKind::Gemini => {
                let mut parts = Vec::new();
                for (c,r) in results {
                    let mut response = json!({"name":c.name,"response":r.value});
                    if !c.id.starts_with("fritz-") { response["id"] = json!(c.id); }
                    parts.push(json!({"functionResponse":response}));
                    parts.extend(r.images.iter().map(|i| json!({"inlineData":{"mimeType":i.media_type,"data":i.base64}})));
                }
                self.history.push(json!({"role":"user","parts":parts}));
            },
            ProviderKind::Ollama => {
                self.history.extend(results.iter().map(|(c,r)| json!({"role":"tool","tool_name":c.name,"content":r.value.as_str().map(str::to_owned).unwrap_or_else(|| r.value.to_string())})));
                for (c,r) in results.iter().filter(|(_,r)| !r.images.is_empty()) {
                    self.history.push(json!({"role":"user","content":format!("Images returned by tool {} ({})",c.name,c.id),"images":r.images.iter().map(|i| &i.base64).collect::<Vec<_>>()}));
                }
            },
            _ => {
                self.history.extend(results.iter().map(|(c,r)| json!({"role":"tool","tool_call_id":c.id,"content":r.value.as_str().map(str::to_owned).unwrap_or_else(|| r.value.to_string())})));
                for (c,r) in results.iter().filter(|(_,r)| !r.images.is_empty()) {
                    let mut content = vec![json!({"type":"text","text":format!("Images returned by tool {} ({})",c.name,c.id)})];
                    content.extend(r.images.iter().map(|i| json!({"type":"image_url","image_url":{"url":format!("data:{};base64,{}",i.media_type,i.base64)}})));
                    self.history.push(json!({"role":"user","content":content}));
                }
            },
        }
        let mut image_message = start + results.len();
        let mut inline_part = 0;
        for (index, (call, result)) in results.iter().enumerate() {
            let (message, part, images, image_slot) = match self.kind {
                ProviderKind::Anthropic => (start, Some(index), vec![], None),
                ProviderKind::Gemini => {
                    let part = inline_part;
                    inline_part += 1 + result.images.len();
                    (start, Some(part), (part + 1..inline_part).collect(), None)
                }
                ProviderKind::Openai => (start + index, None, vec![], None),
                _ => {
                    let slot = if result.images.is_empty() {
                        None
                    } else {
                        let slot = image_message;
                        image_message += 1;
                        Some(slot)
                    };
                    (start + index, None, vec![], slot)
                }
            };
            self.receipts.push(ReceiptSlot {
                call: call.clone(),
                message,
                part,
                inline_images: images,
                image_message: image_slot,
                failed: result.failed,
            });
        }

        Ok(())
    }
}

#[derive(Default)]
struct Preview {
    id: String,
    name: String,
    arguments: String,
    received: usize,
}
fn preview(
    kind: ProviderKind,
    v: &Value,
    state: &mut BTreeMap<usize, Preview>,
    emit: &impl Fn(Value),
) {
    let mut updates = Vec::new();
    match kind {
        ProviderKind::Openai => {
            let index = v["output_index"].as_u64().unwrap_or_default() as usize;
            match v["type"].as_str() {
                Some("response.output_item.added") if v["item"]["type"] == "function_call" => {
                    updates.push((
                        index,
                        v["item"]["call_id"].as_str(),
                        v["item"]["name"].as_str(),
                        v["item"]["arguments"].as_str().unwrap_or(""),
                    ))
                }
                Some("response.function_call_arguments.delta") => {
                    updates.push((index, None, None, v["delta"].as_str().unwrap_or("")))
                }
                _ => {}
            }
        }
        ProviderKind::Anthropic => {
            let index = v["index"].as_u64().unwrap_or_default() as usize;
            match v["type"].as_str() {
                Some("content_block_start") if v["content_block"]["type"] == "tool_use" => updates
                    .push((
                        index,
                        v["content_block"]["id"].as_str(),
                        v["content_block"]["name"].as_str(),
                        "",
                    )),
                Some("content_block_delta") if v["delta"]["type"] == "input_json_delta" => updates
                    .push((
                        index,
                        None,
                        None,
                        v["delta"]["partial_json"].as_str().unwrap_or(""),
                    )),
                _ => {}
            }
        }
        ProviderKind::OpenaiCompatible | ProviderKind::Openrouter => {
            if let Some(calls) = v["choices"][0]["delta"]["tool_calls"].as_array() {
                for call in calls {
                    updates.push((
                        call["index"].as_u64().unwrap_or_default() as usize,
                        call["id"].as_str(),
                        call["function"]["name"].as_str(),
                        call["function"]["arguments"].as_str().unwrap_or(""),
                    ));
                }
            }
        }
        _ => {}
    }
    for (index, id, name, delta) in updates {
        let preview = state.entry(index).or_default();
        if let Some(id) = id {
            preview.id = id.into();
        }
        if let Some(name) = name {
            preview.name.push_str(name);
        }
        preview.received = preview.received.saturating_add(delta.len());
        if preview.received <= 64 * 1024 {
            preview.arguments.push_str(delta);
        } else {
            preview.arguments.clear();
        }
        let id = if preview.id.is_empty() {
            format!("pending-{index}")
        } else {
            preview.id.clone()
        };
        emit(
            json!({"type":"tool_preview","id":id,"name":preview.name,"arguments":if preview.received <= 64 * 1024 {Some(&preview.arguments)} else {None},"bytes_received":preview.received}),
        );
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
        let round_id = uuid::Uuid::new_v4();
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
                        .unwrap_or_else(|| format!("fritz-{round_id}-{i}")),
                    name: required(&item["functionCall"], "name")?,
                    arguments: item["functionCall"]["args"].to_string(),
                }),
                ProviderKind::Ollama => Some(Call {
                    id: format!("fritz-{round_id}-{i}"),
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
    fn image_receipts_preserve_native_history_and_call_identity() {
        for (kind, receipt_path, image_path) in [
            (ProviderKind::Openai, "/1/call_id", "/1/output/1/image_url"),
            (
                ProviderKind::Anthropic,
                "/1/content/0/tool_use_id",
                "/1/content/0/content/1/source/data",
            ),
            (
                ProviderKind::Gemini,
                "/1/parts/0/functionResponse/id",
                "/1/parts/1/inlineData/data",
            ),
            (
                ProviderKind::OpenaiCompatible,
                "/1/tool_call_id",
                "/2/content/1/image_url/url",
            ),
            (
                ProviderKind::Openrouter,
                "/1/tool_call_id",
                "/2/content/1/image_url/url",
            ),
            (ProviderKind::Ollama, "/1/tool_name", "/2/images/0"),
        ] {
            let opaque = json!({"opaque":"signed-history"});
            let mut session = Session {
                history: vec![opaque.clone()],
                kind,
                suffix: "",
                base: json!({}),
                receipts: Vec::new(),
                strict_tools: false,
                request_byte_limit: 2_000_000,
            };
            session
                .results(&[(
                    Call {
                        id: "call-1".into(),
                        name: "inspect".into(),
                        arguments: "{}".into(),
                    },
                    ToolResult {
                        value: json!({"text":"visible evidence"}),
                        failed: true,
                        images: vec![fritz_harness::Image {
                            media_type: "image/png".into(),
                            base64: "aW1hZ2U=".into(),
                        }],
                    },
                )])
                .unwrap();
            assert_eq!(session.history[0], opaque);
            let history = json!(session.history);
            assert_eq!(
                history.pointer(receipt_path).unwrap(),
                if kind == ProviderKind::Ollama {
                    "inspect"
                } else {
                    "call-1"
                }
            );
            assert!(
                history
                    .pointer(image_path)
                    .unwrap()
                    .as_str()
                    .unwrap()
                    .contains("aW1hZ2U=")
            );
            assert!(history.to_string().contains("visible evidence"));
            session
                .replace_result(
                    "call-1",
                    ToolResult::json(json!("Bounded prior evidence receipt"), false),
                )
                .unwrap();
            session.append_user("Continue the conversation.");
            let history = json!(session.history);
            assert_eq!(history[0], opaque);
            assert_eq!(
                history.pointer(receipt_path).unwrap(),
                if kind == ProviderKind::Ollama {
                    "inspect"
                } else {
                    "call-1"
                }
            );
            assert!(!history.to_string().contains("aW1hZ2U="));
            if kind == ProviderKind::Anthropic {
                assert_eq!(history[1]["content"][0]["is_error"], true);
            }
            assert!(!history.to_string().contains("visible evidence"));
            assert!(
                history
                    .to_string()
                    .contains("Bounded prior evidence receipt")
            );
            assert!(history.to_string().contains("Continue the conversation."));
        }
    }

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
