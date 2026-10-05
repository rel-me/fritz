//! Experimental Bosun stable-slot readout; no generated text or remote model resolution.
//!
//! Compiler: Hanno-Labs/bosun-v3.1-0.6b@2afeaccc760165386c2dd52e78b851b1b53cb752.
//! Typed mapping: Hanno-Labs/jev-compatible-server@431b8e1ecc501cdb76c118fe58907a0a004d6fc0.
//! Native raw logits: mistral.rs@4400935451da5e2dc7379a3f92fbbada66557f6c.
//! Bosun uses temperature 1 and maximum-option confidence for both Choice and Score.
//! Those values have not been qualified as calibrated probabilities for Fritz workflows.
use super::Manifest;
use crate::decision::{Answer, DecisionRequest, DecisionResponse, Question, Usage};
use anyhow::{Context, Result, bail, ensure};
use ollaya_decision::pyjson::dumps_canonical;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::PathBuf};

const PROMPT_SCHEMA: &str = "bosun-decision-prompt-v3-stable-slots";
const SYSTEM: &str = "Choose exactly one supplied decision token. Return only that token. Do not explain the answer.";
const VOCAB_SIZE: usize = 151925;
const DECISION_START: u32 = 151669;
const SLOT_COUNT: usize = 256;
const MAX_PROMPT_TOKENS: usize = 2048;
// mistral.rs returns all prompt positions, including an internal full-logit CPU copy.
// This bounds only the returned raw tensor payload, not total resident memory.
const MAX_RAW_BYTES: usize = MAX_PROMPT_TOKENS * VOCAB_SIZE * 4;

struct Candidate {
    id: String,
    label: String,
    description: String,
}

struct Row {
    id: String,
    prompt: String,
    // Presented slot -> original candidate index, never candidate ID order guessed from logits.
    presentation_order: Vec<usize>,
    candidates: Vec<Candidate>,
    question: Question,
}

fn render_content(value: &Value) -> Result<String> {
    match value {
        Value::String(text) => Ok(text.clone()),
        Value::Object(_) | Value::Array(_) => Ok(dumps_canonical(value)),
        _ => bail!("Bosun instructions and criteria must be strings, objects, or arrays."),
    }
}

fn candidates(question: &Question) -> Result<(&'static str, String, Vec<Candidate>)> {
    let make = |id: String, label: String, description: Option<&Value>| -> Result<Candidate> {
        Ok(Candidate {
            id,
            label,
            description: match description {
                None | Some(Value::Null) => String::new(),
                Some(value) => render_content(value)?,
            },
        })
    };
    match question {
        Question::Choice {
            instructions,
            criteria,
        } => Ok((
            "choice",
            render_content(instructions)?,
            criteria
                .iter()
                .map(|(id, description)| make(id.clone(), id.clone(), Some(description)))
                .collect::<Result<_>>()?,
        )),
        Question::Score {
            instructions,
            criteria,
        } => Ok((
            "score",
            render_content(instructions)?,
            criteria
                .iter()
                .enumerate()
                .map(|(index, level)| make(index.to_string(), render_content(level)?, None))
                .collect::<Result<_>>()?,
        )),
        Question::Noul {
            instructions,
            criteria,
        } => {
            let values = match criteria {
                None | Some(Value::Null) => vec![
                    make("true".into(), "true".into(), Some(&json!("yes")))?,
                    make("false".into(), "false".into(), Some(&json!("no")))?,
                ],
                Some(Value::Object(object))
                    if object.len() == 2
                        && object.contains_key("true")
                        && object.contains_key("false") =>
                {
                    // Unlike Choice, the official Noul protocol does not admit null criteria.
                    render_content(&object["true"])?;
                    render_content(&object["false"])?;
                    vec![
                        make("true".into(), "true".into(), Some(&object["true"]))?,
                        make("false".into(), "false".into(), Some(&object["false"]))?,
                    ]
                }
                _ => bail!("Bosun Noul criteria must contain exactly true and false."),
            };
            Ok(("noul", render_content(instructions)?, values))
        }
    }
}

/// Reproduce Pydantic model_dump(mode="json"): omitted Noul criteria is explicit null.
fn protocol_request(request: &DecisionRequest) -> Result<Value> {
    let mut value = serde_json::to_value(request)?;
    for (id, question) in &request.questions {
        if matches!(question, Question::Noul { criteria: None, .. }) {
            value["questions"][id]["criteria"] = Value::Null;
        }
    }
    Ok(value)
}

fn parsed_description(description: &str) -> Result<Option<serde_json::Map<String, Value>>> {
    if description.trim_start().starts_with('{') {
        // Python's json.loads admits NaN/Infinity and arbitrary-size integers inside
        // string descriptions. Reject that unsupported domain instead of silently
        // rendering a different criteria layout or rounding an integer into a float.
        let mut quoted = false;
        let mut escaped = false;
        let mut atom = String::new();
        let check = |atom: &str| -> Result<()> {
            if matches!(atom, "NaN" | "Infinity" | "-Infinity") {
                bail!("Bosun JSON descriptions require finite numbers.");
            }
            if atom.starts_with(|c: char| c.is_ascii_digit() || c == '-') {
                if atom.contains(['.', 'e', 'E']) {
                    if atom.parse::<f64>().is_ok_and(|number| !number.is_finite()) {
                        bail!("Bosun JSON descriptions require finite numbers.");
                    }
                } else if atom.parse::<i64>().is_err()
                    && atom.parse::<u64>().is_err()
                    && atom
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || byte == b'-')
                {
                    bail!("Bosun JSON description integers must fit the supported 64-bit range.");
                }
            }
            Ok(())
        };
        for character in description.chars() {
            if quoted {
                if escaped {
                    escaped = false;
                } else if character == '\\' {
                    escaped = true;
                } else if character == '"' {
                    quoted = false;
                }
            } else if character == '"' {
                check(&atom)?;
                atom.clear();
                quoted = true;
            } else if character.is_ascii_whitespace()
                || matches!(character, '{' | '}' | '[' | ']' | ',' | ':')
            {
                check(&atom)?;
                atom.clear();
            } else {
                atom.push(character);
            }
        }
        check(&atom)?;
    }
    Ok(serde_json::from_str::<Value>(description)
        .ok()
        .and_then(|value| value.as_object().cloned()))
}

fn compile(request: &DecisionRequest) -> Result<Vec<Row>> {
    request.validate()?;
    let wire = protocol_request(request)?;
    request.questions.iter().map(|(id, question)| {
        let (kind, instructions, candidates) = candidates(question)?;
        ensure!((2..=255).contains(&candidates.len()), "Bosun supports 2 to 255 candidates.");
        let row_id = format!("{:x}", Sha256::digest(dumps_canonical(&json!({"question_name":id,"request":wire})).as_bytes()));
        let digest = Sha256::digest(format!("0:{row_id}:candidate-order").as_bytes());
        let seed = u64::from_be_bytes(digest[..8].try_into()?);
        let mut presentation_order: Vec<usize> = (0..candidates.len()).collect();
        PythonRandom::new(seed).shuffle(&mut presentation_order);
        let parsed = presentation_order.iter().map(|index| parsed_description(&candidates[*index].description)).collect::<Result<Vec<_>>>()?;
        let parsed: Option<Vec<serde_json::Map<String, Value>>> = parsed.into_iter().collect();
        let description_fields = parsed.as_ref().and_then(|objects| {
            let mut fields: Vec<String> = objects.first()?.keys().cloned().collect();
            fields.sort();
            objects.iter().all(|object| object.len() == fields.len() && fields.iter().all(|field| object.contains_key(field))).then_some(fields)
        });
        let mut fields = vec!["t".to_owned(), "o".to_owned(), "n".to_owned()];
        fields.extend(description_fields.clone().unwrap_or_else(|| vec!["d".into()]));
        let criteria: Vec<Value> = presentation_order.iter().enumerate().map(|(slot, index)| {
            let candidate = &candidates[*index];
            let mut row = vec![json!(format!("<|decision_{slot:03}|>")), json!(index), json!(candidate.label)];
            match &description_fields {
                Some(keys) => row.extend(keys.iter().map(|key| parsed.as_ref().unwrap()[slot][key].clone())),
                None => row.push(json!(candidate.description)),
            }
            Value::Array(row)
        }).collect();
        let content = dumps_canonical(&json!({
            "schema":PROMPT_SCHEMA,"state":request.state,
            "question":{"instructions":instructions,"type":kind,"criteria_fields":fields,"criteria":criteria}
        }));
        // Exact two-message, tools-absent, thinking-disabled branch of pinned chat_template.jinja.
        let prompt = format!("<|im_start|>system\n{SYSTEM}<|im_end|>\n<|im_start|>user\n{content}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n");
        Ok(Row { id:id.clone(), prompt, presentation_order, candidates, question:question.clone() })
    }).collect()
}

// CPython integer seeding, MT19937 getrandbits and Random.shuffle/_randbelow.
// Reference: CPython v3.11.9 Modules/_randommodule.c and Lib/random.py (PSF license).
// The 64-bit digest integer is seeded as little-endian 32-bit words, not init_genrand(u32).
struct PythonRandom {
    state: [u32; 624],
    index: usize,
}
impl PythonRandom {
    fn new(seed: u64) -> Self {
        let mut random = Self {
            state: [0; 624],
            index: 624,
        };
        random.state[0] = 19650218;
        for index in 1..624 {
            random.state[index] = 1812433253u32
                .wrapping_mul(random.state[index - 1] ^ (random.state[index - 1] >> 30))
                .wrapping_add(index as u32);
        }
        let words = if seed >> 32 == 0 {
            vec![seed as u32]
        } else {
            vec![seed as u32, (seed >> 32) as u32]
        };
        let (mut i, mut j) = (1usize, 0usize);
        for _ in 0..624 {
            random.state[i] = (random.state[i]
                ^ (random.state[i - 1] ^ (random.state[i - 1] >> 30)).wrapping_mul(1664525))
            .wrapping_add(words[j])
            .wrapping_add(j as u32);
            i += 1;
            j += 1;
            if i >= 624 {
                random.state[0] = random.state[623];
                i = 1;
            }
            if j >= words.len() {
                j = 0;
            }
        }
        for _ in 0..623 {
            random.state[i] = (random.state[i]
                ^ (random.state[i - 1] ^ (random.state[i - 1] >> 30)).wrapping_mul(1566083941))
            .wrapping_sub(i as u32);
            i += 1;
            if i >= 624 {
                random.state[0] = random.state[623];
                i = 1;
            }
        }
        random.state[0] = 0x80000000;
        random
    }
    fn next(&mut self) -> u32 {
        if self.index >= 624 {
            for i in 0..624 {
                let y = (self.state[i] & 0x80000000) | (self.state[(i + 1) % 624] & 0x7fffffff);
                self.state[i] = self.state[(i + 397) % 624]
                    ^ (y >> 1)
                    ^ if y & 1 == 1 { 0x9908b0df } else { 0 };
            }
            self.index = 0;
        }
        let mut y = self.state[self.index];
        self.index += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c5680;
        y ^= (y << 15) & 0xefc60000;
        y ^= y >> 18;
        y
    }
    fn shuffle(&mut self, values: &mut [usize]) {
        for i in (1..values.len()).rev() {
            let n = i + 1;
            let bits = usize::BITS - n.leading_zeros();
            let mut j = (self.next() >> (32 - bits)) as usize;
            while j >= n {
                j = (self.next() >> (32 - bits)) as usize;
            }
            values.swap(i, j);
        }
    }
}

fn answer(row: &Row, slot_logits: &[f32]) -> Result<Answer> {
    ensure!(
        slot_logits.len() == row.candidates.len()
            && slot_logits.iter().all(|score| score.is_finite()),
        "Bosun returned invalid decision slot logits."
    );
    let max = slot_logits
        .iter()
        .copied()
        .fold(f32::NEG_INFINITY, f32::max);
    let weights: Vec<f32> = slot_logits
        .iter()
        .map(|score| (*score - max).exp())
        .collect();
    let total: f32 = weights.iter().sum();
    let mut probabilities = vec![0f64; weights.len()];
    for (slot, index) in row.presentation_order.iter().enumerate() {
        probabilities[*index] = (weights[slot] / total) as f64;
    }
    // The publisher's protocol adapter normalizes the float32 softmax output in float64.
    let total: f64 = probabilities.iter().sum();
    ensure!(
        total.is_finite() && total > 0.0,
        "Bosun returned an invalid probability distribution."
    );
    probabilities
        .iter_mut()
        .for_each(|probability| *probability /= total);
    let mut best = 0;
    for index in 1..probabilities.len() {
        if probabilities[index] > probabilities[best] {
            best = index;
        }
    }
    let distribution: BTreeMap<_, _> = row
        .candidates
        .iter()
        .zip(&probabilities)
        .map(|(candidate, probability)| (candidate.id.clone(), *probability))
        .collect();
    Ok(match &row.question {
        Question::Choice { .. } => Answer::Choice {
            choice: row.candidates[best].id.clone(),
            probabilities: distribution,
            confidence: probabilities[best],
        },
        Question::Score { criteria, .. } => Answer::Score {
            score: probabilities
                .iter()
                .enumerate()
                .map(|(index, probability)| index as f64 * probability)
                .sum(),
            legend: criteria
                .iter()
                .enumerate()
                .map(|(index, level)| (index.to_string(), level.clone()))
                .collect(),
            probabilities: distribution,
            confidence: probabilities[best],
        },
        Question::Noul { .. } => Answer::Noul {
            noul: probabilities[0],
        },
    })
}

#[cfg(not(target_os = "macos"))]
pub(super) async fn evaluate(
    _: &Manifest,
    _: PathBuf,
    _: DecisionRequest,
) -> Result<DecisionResponse> {
    bail!("The experimental Bosun native decision runtime requires macOS.")
}

#[cfg(target_os = "macos")]
pub(super) async fn evaluate(
    pin: &'static Manifest,
    directory: PathBuf,
    request: DecisionRequest,
) -> Result<DecisionResponse> {
    let rows = compile(&request)?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    // The owning private child retains its existing EOF/signal/deadline process cancellation.
    std::thread::Builder::new()
        .name("bosun-decision".into())
        .spawn(move || {
            let result = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .context("Could not start the Bosun decision worker.")
                .and_then(|runtime| runtime.block_on(infer(pin, directory, rows)));
            let _ = tx.send(result);
        })?;
    rx.await
        .context("The Bosun decision worker stopped unexpectedly.")?
}

#[cfg(target_os = "macos")]
fn verify_contract(pin: &Manifest, directory: &std::path::Path) -> Result<()> {
    // Fresh downloads are hashed; installation discovery itself is presence-only. Recheck
    // small contracts here; GGUF loading validates every vocabulary ID. Qualification
    // must independently hash the complete GGUF, including previously installed files.
    for file in &pin.files {
        let path = directory.join(&file.file);
        ensure!(
            std::fs::metadata(&path)?.len() == file.size,
            "Bosun artifact has an invalid size: {}",
            file.file
        );
        if !file.file.ends_with(".gguf") {
            ensure!(
                format!("{:x}", Sha256::digest(std::fs::read(&path)?)) == file.sha256,
                "Bosun artifact failed its pinned checksum: {}",
                file.file
            );
        }
    }
    let serving: Value = serde_json::from_slice(&std::fs::read(
        directory.join("bosun-v3.1-0.6b.serving.json"),
    )?)?;
    ensure!(
        serving["schema_version"] == PROMPT_SCHEMA
            && serving["decision_token_assignment"] == "presented_slot"
            && serving["max_runtime_choices"] == 255
            && serving["null_token_index"] == 255
            && serving["decision_prompt_enable_thinking"] == false,
        "Bosun serving contract does not match the pinned adapter."
    );
    ensure!(
        serving["decision_tokens"].as_array().map(Vec::len) == Some(SLOT_COUNT)
            && serving["decision_token_ids"].as_array().map(Vec::len) == Some(SLOT_COUNT),
        "Bosun serving vocabulary is incomplete."
    );
    for slot in 0..SLOT_COUNT {
        ensure!(
            serving["decision_tokens"][slot] == format!("<|decision_{slot:03}|>")
                && serving["decision_token_ids"][slot].as_u64()
                    == Some(DECISION_START as u64 + slot as u64),
            "Bosun serving token mapping differs at slot {slot}."
        );
    }
    Ok(())
}

#[cfg(target_os = "macos")]
async fn load(pin: &Manifest, directory: &std::path::Path) -> Result<mistralrs::Model> {
    verify_contract(pin, directory)?;
    let model = mistralrs::GgufModelBuilder::new(
        directory.to_string_lossy(),
        vec![
            pin.entry_file
                .as_deref()
                .context("Bosun is missing its GGUF entry file.")?,
        ],
    )
    .with_tokenizer_json(
        directory
            .join("bosun-v3.1-0.6b.tokenizer.json")
            .to_string_lossy(),
    )
    .with_jinja_explicit(
        directory
            .join("bosun-v3.1-0.6b.chat_template.jinja")
            .to_string_lossy()
            .into_owned(),
    )
    .with_token_source(mistralrs::TokenSource::None)
    .with_dtype(mistralrs::ModelDType::F16)
    .with_max_model_len(MAX_PROMPT_TOKENS)
    .with_max_num_seqs(1)
    .with_prefix_cache_n(None)
    .with_no_kv_cache()
    .build()
    .await
    .context("Could not load the installed Bosun GGUF with mistral.rs.")?;
    let decision_text: String = (0..SLOT_COUNT)
        .map(|slot| format!("<|decision_{slot:03}|>"))
        .collect();
    let tokens = tokenize(&model, decision_text, false).await?;
    ensure!(
        tokens == (DECISION_START..DECISION_START + SLOT_COUNT as u32).collect::<Vec<_>>(),
        "Bosun tokenizer does not encode every decision token at the pinned ID."
    );
    Ok(model)
}

#[cfg(target_os = "macos")]
async fn tokenize(
    model: &mistralrs::Model,
    prompt: String,
    add_special_tokens: bool,
) -> Result<Vec<u32>> {
    model
        .tokenize(
            either::Either::Right(prompt),
            None,
            add_special_tokens,
            false,
            None,
        )
        .await
        .context("Bosun prompt tokenization failed.")
}

#[cfg(target_os = "macos")]
async fn row_tokens(model: &mistralrs::Model, row: &Row) -> Result<Vec<u32>> {
    let tokens = tokenize(model, row.prompt.clone(), true).await?;
    admit_tokens(&row.id, &tokens)?;
    Ok(tokens)
}

fn admit_tokens(id: &str, tokens: &[u32]) -> Result<()> {
    ensure!(
        !tokens.is_empty() && tokens.len() <= MAX_PROMPT_TOKENS,
        "Bosun rendered prompt {id} exceeds its {MAX_PROMPT_TOKENS}-token context limit; no state was truncated."
    );
    ensure!(
        tokens.iter().all(|id| (*id as usize) < VOCAB_SIZE),
        "Bosun prompt contains a token outside the pinned vocabulary."
    );
    ensure!(
        tokens
            .len()
            .checked_mul(VOCAB_SIZE)
            .and_then(|n| n.checked_mul(4))
            .is_some_and(|bytes| bytes <= MAX_RAW_BYTES),
        "Bosun raw readout exceeds its tensor memory limit."
    );
    Ok(())
}

#[cfg(target_os = "macos")]
async fn slot_logits(model: &mistralrs::Model, tokens: &[u32], count: usize) -> Result<Vec<f32>> {
    use mistralrs::{NormalRequest, Request, RequestMessage, Response, SamplingParams};
    let (tx, mut rx) = tokio::sync::mpsc::channel(1);
    // This engine rejects max_len=0 before checking return_raw_logits. Raw mode exits
    // with Done(Length(0)) before sampling; 1 only satisfies its request admission rule.
    let mut request = NormalRequest::new_simple(
        RequestMessage::CompletionTokens(tokens.to_vec()),
        SamplingParams {
            max_len: Some(1),
            ..SamplingParams::deterministic()
        },
        tx,
        0,
        None,
        None,
    );
    request.return_raw_logits = true;
    request.truncate_sequence = false;
    model
        .inner()
        .get_sender(None)?
        .send(Request::Normal(Box::new(request)))
        .await?;
    match rx
        .recv()
        .await
        .context("Bosun raw readout channel closed unexpectedly.")?
    {
        Response::Raw {
            logits_chunks,
            tokens: returned,
        } => {
            ensure!(
                returned == tokens,
                "Bosun raw readout changed or truncated the supplied prompt tokens."
            );
            final_slot_logits(&logits_chunks, tokens.len(), count)
        }
        Response::InternalError(error) | Response::ValidationError(error) => {
            bail!("Bosun native readout failed: {error}")
        }
        _ => bail!("Bosun native readout returned generated output instead of raw logits."),
    }
}

#[cfg(target_os = "macos")]
fn final_slot_logits(
    chunks: &[mistralrs::Tensor],
    prompt_tokens: usize,
    count: usize,
) -> Result<Vec<f32>> {
    ensure!(
        (2..=255).contains(&count),
        "Bosun raw readout needs 2 to 255 candidates."
    );
    let (mut rows, mut bytes) = (0usize, 0usize);
    for chunk in chunks {
        let (height, width) = chunk.dims2()?;
        ensure!(
            height > 0 && width == VOCAB_SIZE,
            "Bosun raw logits have an incomplete vocabulary or invalid shape."
        );
        rows = rows
            .checked_add(height)
            .context("Bosun raw row count overflow.")?;
        bytes = bytes
            .checked_add(
                chunk
                    .elem_count()
                    .checked_mul(chunk.dtype().size_in_bytes())
                    .context("Bosun tensor size overflow.")?,
            )
            .context("Bosun raw tensor size overflow.")?;
    }
    ensure!(
        rows == prompt_tokens && bytes <= MAX_RAW_BYTES,
        "Bosun raw tensor exceeds its bounded prompt contract."
    );
    let last = chunks.last().context("Bosun returned no raw logit rows.")?;
    // Slice the final row and only eligible slots before converting to a Rust vector.
    Ok(last
        .narrow(0, last.dim(0)? - 1, 1)?
        .narrow(1, DECISION_START as usize, count)?
        .squeeze(0)?
        .to_dtype(mistralrs::DType::F32)?
        .to_vec1::<f32>()?)
}

#[cfg(target_os = "macos")]
async fn infer(pin: &Manifest, directory: PathBuf, rows: Vec<Row>) -> Result<DecisionResponse> {
    let model = load(pin, &directory).await?;
    let mut encoded = Vec::with_capacity(rows.len());
    // Admit every head before inference: one oversized head rejects the complete request.
    for row in &rows {
        encoded.push(row_tokens(&model, row).await?);
    }
    let mut answers = BTreeMap::new();
    let mut input_tokens = 0;
    for (row, tokens) in rows.iter().zip(&encoded) {
        answers.insert(
            row.id.clone(),
            answer(
                row,
                &slot_logits(&model, tokens, row.candidates.len()).await?,
            )?,
        );
        input_tokens += tokens.len() as u64;
    }
    Ok(DecisionResponse {
        model: format!("{}@{}", pin.id, pin.revision),
        answers,
        usage: Some(Usage {
            input_tokens,
            output_tokens: 0,
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn compiler_reference() -> Value {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/bosun-compiler-reference.json"
        ))
        .unwrap()
    }

    #[test]
    fn compiler_matches_independent_official_prompt_bytes_and_presented_slots() {
        // The oracle came from only pinned official AST functions, Jinja and tokenizer;
        // no Fritz compiler output or native/model probabilities supplied its expectations.
        for reference in compiler_reference()["rows"].as_array().unwrap() {
            let request: DecisionRequest =
                serde_json::from_value(reference["request"].clone()).unwrap();
            let rows = compile(&request).unwrap();
            let row = rows
                .iter()
                .find(|row| row.id == reference["question_name"].as_str().unwrap())
                .unwrap();
            assert_eq!(row.prompt, reference["prompt"].as_str().unwrap());
            assert_eq!(
                serde_json::to_value(&row.presentation_order).unwrap(),
                reference["presentation_order"]
            );
            let mapping: BTreeMap<_, _> = row
                .presentation_order
                .iter()
                .enumerate()
                .map(|(slot, index)| (row.candidates[*index].id.clone(), slot))
                .collect();
            assert_eq!(
                serde_json::to_value(mapping).unwrap(),
                reference["candidate_to_slot"]
            );
        }
    }

    #[test]
    fn compiler_rejects_unrepresentable_description_objects_instead_of_changing_the_layout() {
        let mut request: DecisionRequest =
            serde_json::from_value(compiler_reference()["rows"][0]["request"].clone()).unwrap();
        for description in [
            r#"{"value":NaN}"#,
            r#"{"value":Infinity}"#,
            r#"{"value":1e400}"#,
            r#"{"value":18446744073709551616}"#,
        ] {
            let Question::Choice { criteria, .. } = request.questions.get_mut("route").unwrap()
            else {
                panic!("choice")
            };
            for value in criteria.values_mut() {
                *value = json!(description);
            }
            assert!(
                compile(&request).is_err(),
                "unrepresentable description: {description}"
            );
        }
        // A quoted mention is ordinary text and remains supported.
        let Question::Choice { criteria, .. } = request.questions.get_mut("route").unwrap() else {
            panic!("choice")
        };
        for value in criteria.values_mut() {
            *value = json!(r#"{"value":"NaN"}"#);
        }
        assert!(compile(&request).is_ok());
    }

    #[test]
    fn mapped_probabilities_preserve_score_levels_and_true_noul_slot() {
        // Deliberately reordered slots: high first, low second, medium third.
        let question = Question::Score {
            instructions: json!("Priority?"),
            criteria: vec![
                json!({"level":"low"}),
                json!({"level":"medium"}),
                json!({"level":"high"}),
            ],
        };
        let (_, _, options) = candidates(&question).unwrap();
        let row = Row {
            id: "priority".into(),
            prompt: String::new(),
            presentation_order: vec![2, 0, 1],
            candidates: options,
            question,
        };
        let result = answer(&row, &[0.7_f32.ln(), 0.1_f32.ln(), 0.2_f32.ln()]).unwrap();
        let Answer::Score {
            score,
            legend,
            probabilities,
            confidence,
        } = result
        else {
            panic!("expected score")
        };
        assert!((score - 1.6).abs() < 1e-6);
        assert!((confidence - 0.7).abs() < 1e-6);
        assert!(
            (probabilities["0"] - 0.1).abs() < 1e-6
                && (probabilities["1"] - 0.2).abs() < 1e-6
                && (probabilities["2"] - 0.7).abs() < 1e-6
        );
        assert_eq!(
            legend,
            BTreeMap::from([
                ("0".into(), json!({"level":"low"})),
                ("1".into(), json!({"level":"medium"})),
                ("2".into(), json!({"level":"high"}))
            ])
        );
        let question = Question::Noul {
            instructions: json!("Authorized?"),
            criteria: None,
        };
        let (_, _, options) = candidates(&question).unwrap();
        let row = Row {
            id: "authorized".into(),
            prompt: String::new(),
            presentation_order: vec![1, 0],
            candidates: options,
            question,
        };
        let Answer::Noul { noul } = answer(&row, &[0.2_f32.ln(), 0.8_f32.ln()]).unwrap() else {
            panic!("expected noul")
        };
        assert!((noul - 0.8).abs() < 1e-6);
        assert!(answer(&row, &[f32::NAN, 0.0]).is_err());
    }

    #[test]
    fn prompt_admission_rejects_overflow_and_incomplete_vocabulary_without_truncation() {
        let mut tokens = vec![1; MAX_PROMPT_TOKENS];
        admit_tokens("full", &tokens).unwrap();
        tokens.push(1);
        assert!(
            admit_tokens("overflow", &tokens)
                .unwrap_err()
                .to_string()
                .contains("no state was truncated")
        );
        assert_eq!(tokens.len(), MAX_PROMPT_TOKENS + 1);
        assert!(admit_tokens("empty", &[]).is_err());
        assert!(admit_tokens("unknown", &[VOCAB_SIZE as u32]).is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn raw_readout_masks_unused_slots_and_uses_final_prompt_position() {
        let mut values = vec![0_f32; VOCAB_SIZE * 2];
        values[DECISION_START as usize] = 999.0; // Earlier prompt position must not win.
        for (offset, score) in [1.0, 2.0, 3.0, 10000.0].into_iter().enumerate() {
            values[VOCAB_SIZE + DECISION_START as usize + offset] = score;
        }
        values[VOCAB_SIZE + DECISION_START as usize + 255] = 20000.0; // Null slot is never eligible.
        let logits =
            mistralrs::Tensor::from_vec(values, (2, VOCAB_SIZE), &mistralrs::Device::Cpu).unwrap();
        assert_eq!(
            final_slot_logits(std::slice::from_ref(&logits), 2, 3).unwrap(),
            vec![1.0, 2.0, 3.0]
        );
        assert!(final_slot_logits(std::slice::from_ref(&logits), 1, 3).is_err());
        assert!(final_slot_logits(&[logits.narrow(1, 0, VOCAB_SIZE - 1).unwrap()], 2, 3).is_err());
    }

    #[cfg(target_os = "macos")]
    fn file_hash(path: &std::path::Path) -> String {
        use std::io::Read;
        let mut file = std::fs::File::open(path).unwrap();
        let mut hash = Sha256::new();
        let mut buffer = [0u8; 65536];
        loop {
            let count = file.read(&mut buffer).unwrap();
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
        }
        format!("{:x}", hash.finalize())
    }

    #[cfg(target_os = "macos")]
    fn write_native_receipt(path: &std::path::Path, value: &Value, first: bool) {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).mode(0o600);
        if first {
            options.create_new(true);
        } else {
            options.truncate(true);
        }
        let mut file = options.open(path).unwrap();
        serde_json::to_writer_pretty(&mut file, value).unwrap();
        file.write_all(b"\n").unwrap();
        file.flush().unwrap();
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore = "requires explicit installed Bosun F16 artifacts and separately frozen official CPU probability goldens"]
    async fn native_f16_matches_official_cpu_reference_without_generating_tokens() {
        let directory = PathBuf::from(
            std::env::var("FRITZ_BOSUN_MODELS_DIR")
                .expect("explicit FRITZ_BOSUN_MODELS_DIR is required"),
        );
        assert!(directory.is_absolute());
        let path = std::env::var("FRITZ_BOSUN_CPU_REFERENCE")
            .expect("explicit FRITZ_BOSUN_CPU_REFERENCE is required");
        let reference: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(reference["schema"], "fritz-bosun-cpu-reference-v1");
        assert_eq!(reference["status"], "complete");
        assert_eq!(
            reference["compiler_reference_sha256"],
            format!(
                "{:x}",
                Sha256::digest(include_bytes!(
                    "../../../tests/fixtures/bosun-compiler-reference.json"
                ))
            )
        );
        let pin = super::super::manifest("bosun-v3.1-0.6b-f16").unwrap();
        let receipt_path = PathBuf::from(
            std::env::var("FRITZ_BOSUN_NATIVE_RECEIPT")
                .expect("explicit FRITZ_BOSUN_NATIVE_RECEIPT is required"),
        );
        assert!(receipt_path.is_absolute() && !receipt_path.exists());
        let executable = std::env::current_exe().unwrap();
        let artifacts: Vec<_> = pin
            .files
            .iter()
            .map(|artifact| {
                let path = directory.join(&artifact.file);
                let hash = file_hash(&path);
                let size = std::fs::metadata(path).unwrap().len();
                assert_eq!(hash, artifact.sha256);
                assert_eq!(size, artifact.size);
                json!({"file":artifact.file,"size":size,"sha256":hash})
            })
            .collect();
        let mut receipt = json!({
            "status":"running", "source_commit":std::env::var("FRITZ_BOSUN_SOURCE_COMMIT").unwrap(),
            "source_dirty":std::env::var("FRITZ_BOSUN_SOURCE_DIRTY").unwrap()=="true",
            "binary_sha256":std::env::var("FRITZ_BOSUN_STAGED_HARNESS_SHA256").unwrap(),
            "test_executable_path":executable,"test_executable_sha256":file_hash(&executable),
            "source_sha256":{
                "bosun":format!("{:x}",Sha256::digest(include_bytes!("bosun.rs"))),
                "local":format!("{:x}",Sha256::digest(include_bytes!("../local.rs"))),
                "harness":format!("{:x}",Sha256::digest(include_bytes!("../harness.rs"))),
                "catalog":format!("{:x}",Sha256::digest(include_bytes!("../../../Sources/Fritz/DecisionModels.json")))
            },
            "model":pin.id,"revision":pin.revision,"engine_revision":mistralrs::MISTRALRS_GIT_REVISION,
            "artifacts":artifacts,"rows":[],"cleanup":null
        });
        write_native_receipt(&receipt_path, &receipt, true);
        let model = load(pin, &directory).await.unwrap();
        let expected_rows = compiler_reference();
        assert_eq!(
            reference["rows"].as_array().unwrap().len(),
            expected_rows["rows"].as_array().unwrap().len()
        );
        for (oracle, compiler) in reference["rows"]
            .as_array()
            .unwrap()
            .iter()
            .zip(expected_rows["rows"].as_array().unwrap())
        {
            assert_eq!(oracle["case_id"], compiler["case_id"]);
            assert_eq!(oracle["prompt"], compiler["prompt"]);
            assert_eq!(oracle["token_ids"], compiler["token_ids"]);
            let request: DecisionRequest =
                serde_json::from_value(compiler["request"].clone()).unwrap();
            let row = compile(&request).unwrap().pop().unwrap();
            let tokens = row_tokens(&model, &row).await.unwrap();
            assert_eq!(serde_json::to_value(&tokens).unwrap(), oracle["token_ids"]);
            let logits = tokio::time::timeout(
                std::time::Duration::from_secs(120),
                slot_logits(&model, &tokens, row.candidates.len()),
            )
            .await
            .expect("native parity row deadline")
            .unwrap();
            let actual = serde_json::to_value(answer(&row, &logits).unwrap()).unwrap();
            let expected: Vec<f64> =
                serde_json::from_value(oracle["probabilities"].clone()).unwrap();
            assert_eq!(expected.len(), row.candidates.len());
            let aligned: Vec<f64> = match row.question {
                Question::Noul { .. } => vec![
                    actual["noul"].as_f64().unwrap(),
                    1.0 - actual["noul"].as_f64().unwrap(),
                ],
                _ => row
                    .candidates
                    .iter()
                    .map(|candidate| actual["probabilities"][&candidate.id].as_f64().unwrap())
                    .collect(),
            };
            let best = |values: &[f64]| {
                let mut index = 0;
                for next in 1..values.len() {
                    if values[next] > values[index] {
                        index = next;
                    }
                }
                index
            };
            let error = aligned
                .iter()
                .zip(&expected)
                .map(|(actual, expected)| (actual - expected).abs())
                .fold(0f64, f64::max);
            let mapping: BTreeMap<_, _> = row
                .presentation_order
                .iter()
                .enumerate()
                .map(|(slot, index)| (row.candidates[*index].id.clone(), slot))
                .collect();
            let passed = error <= 0.005 && best(&aligned) == best(&expected);
            receipt["rows"].as_array_mut().unwrap().push(json!({
                "case_id":compiler["case_id"],"question_name":row.id,"request":compiler["request"],
                "prompt":row.prompt,"token_ids":tokens,"candidate_to_slot":mapping,
                "probabilities":aligned,"reference_probabilities":expected,"slot_logits":logits,
                "max_absolute_probability_error":error,"selected_index":best(&aligned),
                "reference_selected_index":best(&expected),"passed":passed,
                "usage":{"input_tokens":tokens.len(),"output_tokens":0}
            }));
            if !passed {
                receipt["status"] = json!("failed");
            }
            write_native_receipt(&receipt_path, &receipt, false);
            assert!(
                error <= 0.005,
                "{} maximum native/CPU probability difference {error}",
                row.id
            );
            assert_eq!(best(&aligned), best(&expected));
        }
        receipt["status"] = json!("complete");
        write_native_receipt(&receipt_path, &receipt, false);
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore = "opt-in two-attempt phase diagnostic; requires a separately frozen protocol and owned process supervisor"]
    async fn profile_first_choice_twice_with_one_loaded_model() {
        use std::time::{Duration, Instant};

        let directory = PathBuf::from(
            std::env::var("FRITZ_BOSUN_MODELS_DIR")
                .expect("explicit FRITZ_BOSUN_MODELS_DIR is required"),
        );
        let cpu_path = PathBuf::from(
            std::env::var("FRITZ_BOSUN_CPU_REFERENCE")
                .expect("explicit FRITZ_BOSUN_CPU_REFERENCE is required"),
        );
        let receipt_path = PathBuf::from(
            std::env::var("FRITZ_BOSUN_PROFILE_RECEIPT")
                .expect("explicit FRITZ_BOSUN_PROFILE_RECEIPT is required"),
        );
        assert!(directory.is_absolute() && cpu_path.is_absolute());
        assert!(receipt_path.is_absolute() && !receipt_path.exists());
        let started = Instant::now();
        let executable = std::env::current_exe().unwrap();
        let mut receipt = json!({
            "schema":"fritz-bosun-phase-profile-v1", "status":"running", "phase":"preflight",
            "protocol_sha256":std::env::var("FRITZ_BOSUN_PROFILE_PROTOCOL_SHA256").unwrap(),
            "source_commit":std::env::var("FRITZ_BOSUN_SOURCE_COMMIT").unwrap(),
            "source_dirty":std::env::var("FRITZ_BOSUN_SOURCE_DIRTY").unwrap()=="true",
            "binary_sha256":std::env::var("FRITZ_BOSUN_STAGED_HARNESS_SHA256").unwrap(),
            "test_executable_path":executable,"test_executable_sha256":file_hash(&executable),
            "source_sha256":{
                "bosun":format!("{:x}",Sha256::digest(include_bytes!("bosun.rs"))),
                "local":format!("{:x}",Sha256::digest(include_bytes!("../local.rs"))),
                "harness":format!("{:x}",Sha256::digest(include_bytes!("../harness.rs"))),
                "catalog":format!("{:x}",Sha256::digest(include_bytes!("../../../Sources/Fritz/DecisionModels.json")))
            },
            "cpu_reference_path":cpu_path,"cpu_reference_sha256":null,
            "compiler_reference_sha256":format!("{:x}",Sha256::digest(include_bytes!("../../../tests/fixtures/bosun-compiler-reference.json"))),
            "model":"bosun-v3.1-0.6b-f16", "engine_revision":mistralrs::MISTRALRS_GIT_REVISION,
            "artifacts":[],"planned_attempts":2,"attempts":[],"cleanup":null,
            "phase_scope":"raw_await includes pinned engine inference, full-logit CPU copy, and final-slot extraction; timing has no pass threshold"
        });
        write_native_receipt(&receipt_path, &receipt, true);
        let result: Result<()> = async {
            let reference: Value = serde_json::from_slice(&std::fs::read(&cpu_path)?)?;
            ensure!(reference["schema"] == "fritz-bosun-cpu-reference-v1" && reference["status"] == "complete", "A complete frozen CPU reference is required.");
            let cpu_hash = file_hash(&cpu_path);
            ensure!(cpu_hash == "ee98e277a9b48e00758e57c21d0a4aa120fc4d0c35865830aaf0c1308c330c34", "The CPU reference differs from the frozen five-case cohort.");
            receipt["cpu_reference_sha256"] = json!(cpu_hash);
            let compiler = compiler_reference();
            ensure!(reference["compiler_reference_sha256"] == receipt["compiler_reference_sha256"], "The compiler pin differs from the CPU reference.");
            let gold = &compiler["rows"][0];
            let oracle = &reference["rows"][0];
            for field in ["case_id", "request", "prompt", "token_ids", "candidate_to_slot"] {
                ensure!(gold[field] == oracle[field], "First-case CPU/compiler mismatch: {field}");
            }
            ensure!(gold["token_ids"].as_array().context("Missing golden tokens")?.len() == 188, "The fixed first-case prompt must contain 188 tokens.");
            let pin = super::super::manifest("bosun-v3.1-0.6b-f16")?;
            receipt["revision"] = json!(pin.revision);
            for artifact in &pin.files {
                let path = directory.join(&artifact.file);
                let hash = file_hash(&path);
                let size = std::fs::metadata(path)?.len();
                receipt["artifacts"].as_array_mut().unwrap().push(json!({"file":artifact.file,"size":size,"sha256":hash}));
                write_native_receipt(&receipt_path, &receipt, false);
                ensure!(hash == artifact.sha256 && size == artifact.size, "Artifact integrity mismatch: {}", artifact.file);
            }
            receipt["phase"] = json!("load");
            write_native_receipt(&receipt_path, &receipt, false);
            let phase = Instant::now();
            let loaded = load(pin, &directory).await;
            receipt["load_seconds"] = json!(phase.elapsed().as_secs_f64());
            write_native_receipt(&receipt_path, &receipt, false);
            let model = loaded?;
            let expected: Vec<f64> = serde_json::from_value(oracle["probabilities"].clone())?;
            ensure!(!expected.is_empty() && expected.iter().all(|value| value.is_finite()), "CPU probabilities must be complete and finite.");
            let best = |values: &[f64]| {
                let mut index = 0;
                for next in 1..values.len() {
                    if values[next] > values[index] { index = next; }
                }
                index
            };
            for attempt in 0..2 {
                receipt["phase"] = json!("tokenize_admit");
                receipt["attempts"].as_array_mut().unwrap().push(json!({"attempt":attempt+1,"status":"inflight","case_id":gold["case_id"],"request":gold["request"],"prompt":gold["prompt"],"reference_probabilities":expected}));
                write_native_receipt(&receipt_path, &receipt, false);
                let phase = Instant::now();
                let request: DecisionRequest = serde_json::from_value(gold["request"].clone())?;
                let mut rows = compile(&request)?;
                ensure!(rows.len() == 1, "The diagnostic must retain its single Choice head.");
                let row = rows.pop().unwrap();
                ensure!(matches!(row.question, Question::Choice { .. }), "The fixed first case must remain a Choice.");
                let tokens = row_tokens(&model, &row).await?;
                ensure!(serde_json::to_value(&tokens)? == gold["token_ids"] && json!(&row.prompt) == gold["prompt"], "The fixed prompt/token IDs changed.");
                let mapping: BTreeMap<_, _> = row.presentation_order.iter().enumerate().map(|(slot,index)|(row.candidates[*index].id.clone(),slot)).collect();
                ensure!(serde_json::to_value(&mapping)? == gold["candidate_to_slot"], "The fixed candidate mapping changed.");
                receipt["attempts"][attempt]["tokenize_admit_seconds"] = json!(phase.elapsed().as_secs_f64());
                receipt["attempts"][attempt]["token_ids"] = json!(tokens);
                receipt["attempts"][attempt]["candidate_to_slot"] = json!(mapping);
                receipt["attempts"][attempt]["expected_raw_payload_bytes"] = json!(tokens.len()*VOCAB_SIZE*4);
                receipt["phase"] = json!("raw_await");
                write_native_receipt(&receipt_path, &receipt, false);
                let phase = Instant::now();
                let logits = tokio::time::timeout(Duration::from_secs(120), slot_logits(&model,&tokens,row.candidates.len())).await.context("Bosun profiling raw-readout deadline")??;
                receipt["attempts"][attempt]["raw_await_seconds"] = json!(phase.elapsed().as_secs_f64());
                receipt["phase"] = json!("render");
                receipt["attempts"][attempt]["slot_logits"] = json!(logits);
                write_native_receipt(&receipt_path, &receipt, false);
                let phase = Instant::now();
                let actual = serde_json::to_value(answer(&row,&logits)?)?;
                let aligned: Vec<f64> = row.candidates.iter().map(|candidate| actual["probabilities"][&candidate.id].as_f64().context("Missing original-candidate probability")).collect::<Result<_>>()?;
                ensure!(aligned.len() == expected.len() && aligned.iter().all(|value|value.is_finite()), "Native probabilities must be complete and finite.");
                let error = aligned.iter().zip(&expected).map(|(actual,expected)|(actual-expected).abs()).fold(0f64,f64::max);
                let passed = error <= 0.005 && best(&aligned) == best(&expected);
                receipt["attempts"][attempt]["render_seconds"] = json!(phase.elapsed().as_secs_f64());
                receipt["attempts"][attempt]["probabilities"] = json!(aligned);
                receipt["attempts"][attempt]["max_absolute_probability_error"] = json!(error);
                receipt["attempts"][attempt]["selected_index"] = json!(best(&aligned));
                receipt["attempts"][attempt]["reference_selected_index"] = json!(best(&expected));
                receipt["attempts"][attempt]["usage"] = json!({"input_tokens":tokens.len(),"output_tokens":0});
                receipt["attempts"][attempt]["passed"] = json!(passed);
                receipt["attempts"][attempt]["status"] = json!(if passed {"complete"} else {"failed"});
                write_native_receipt(&receipt_path, &receipt, false);
                ensure!(passed, "Fixed-case probability/argmax parity failed on attempt {}.",attempt+1);
            }
            receipt["phase"] = json!("drop_model");
            write_native_receipt(&receipt_path, &receipt, false);
            let phase = Instant::now();
            drop(model);
            receipt["drop_model_seconds"] = json!(phase.elapsed().as_secs_f64());
            Ok(())
        }.await;
        receipt["elapsed_seconds"] = json!(started.elapsed().as_secs_f64());
        receipt["status"] = json!(if result.is_ok() { "complete" } else { "failed" });
        if let Err(error) = &result {
            receipt["error"] = json!(format!("{error:#}"));
        }
        write_native_receipt(&receipt_path, &receipt, false);
        result.unwrap();
    }
}
