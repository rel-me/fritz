//! Chat templates, tool-call grammars and tool-call parsing from llama.cpp's own
//! chat library (see `chat_bridge.cpp`). Fritz keeps no per-model formats.
use anyhow::{Result, anyhow};
use serde::Deserialize;
use serde_json::Value;
use std::{
    ffi::{CStr, CString, c_char, c_int},
    ptr::NonNull,
};

#[repr(C)]
struct RawTemplates {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn fritz_chat_templates_new(
        source: *const c_char,
        bos: *const c_char,
        eos: *const c_char,
        error: *mut *mut c_char,
    ) -> *mut RawTemplates;
    fn fritz_chat_templates_free(templates: *mut RawTemplates);
    fn fritz_chat_apply(
        templates: *const RawTemplates,
        request: *const c_char,
        output: *mut *mut c_char,
    ) -> c_int;
    fn fritz_chat_parse(
        state: *const c_char,
        text: *const c_char,
        partial: bool,
        output: *mut *mut c_char,
    ) -> c_int;
    fn fritz_chat_string_free(text: *mut c_char);
}

fn take(text: *mut c_char) -> String {
    if text.is_null() {
        return String::new();
    }
    let owned = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    unsafe { fritz_chat_string_free(text) };
    owned
}

fn c_string(text: &str) -> Result<CString> {
    CString::new(text).map_err(|_| anyhow!("Fritz local model: text contains a NUL byte"))
}

/// A model's parsed Jinja chat template.
pub struct Templates(NonNull<RawTemplates>);

// The C++ object is immutable after construction; apply only reads it.
unsafe impl Send for Templates {}
unsafe impl Sync for Templates {}

impl Drop for Templates {
    fn drop(&mut self) {
        unsafe { fritz_chat_templates_free(self.0.as_ptr()) };
    }
}

/// A rendered prompt with the lazy grammar and parser llama.cpp chose for it.
#[derive(Debug, Deserialize)]
pub struct Applied {
    pub prompt: String,
    pub grammar: String,
    pub grammar_lazy: bool,
    pub trigger_patterns: Vec<String>,
    pub preserved_tokens: Vec<String>,
    pub additional_stops: Vec<String>,
    format: i64,
    generation_prompt: String,
    parser: String,
    #[serde(skip)]
    state: String,
}

impl Templates {
    pub fn new(source: &str, bos: &str, eos: &str) -> Result<Self> {
        let (source, bos, eos) = (c_string(source)?, c_string(bos)?, c_string(eos)?);
        let mut error = std::ptr::null_mut();
        let raw = unsafe {
            fritz_chat_templates_new(source.as_ptr(), bos.as_ptr(), eos.as_ptr(), &mut error)
        };
        NonNull::new(raw).map(Self).ok_or_else(|| {
            anyhow!(
                "Fritz local model: unsupported chat template ({})",
                take(error)
            )
        })
    }

    /// Renders OpenAI-shaped `messages` and `tools` with the model's template.
    pub fn apply(&self, messages: &Value, tools: &Value, enable_thinking: bool) -> Result<Applied> {
        let request = serde_json::json!({
            "messages": messages,
            "tools": tools,
            "enable_thinking": enable_thinking,
        });
        let request = c_string(&request.to_string())?;
        let mut output = std::ptr::null_mut();
        let status = unsafe { fritz_chat_apply(self.0.as_ptr(), request.as_ptr(), &mut output) };
        let output = take(output);
        if status != 0 {
            return Err(anyhow!(
                "Fritz local model: cannot apply chat template ({output})"
            ));
        }
        let mut applied: Applied = serde_json::from_str(&output)?;
        // Keep only the parser inputs, not the prompt, for per-token parsing.
        applied.state = serde_json::json!({
            "format": applied.format,
            "generation_prompt": applied.generation_prompt,
            "parser": applied.parser,
        })
        .to_string();
        Ok(applied)
    }
}

impl Applied {
    /// Parses generated text into an OpenAI-shaped assistant message.
    pub fn parse(&self, text: &str, partial: bool) -> Result<Value> {
        let (state, text) = (c_string(&self.state)?, c_string(text)?);
        let mut output = std::ptr::null_mut();
        let status =
            unsafe { fritz_chat_parse(state.as_ptr(), text.as_ptr(), partial, &mut output) };
        let output = take(output);
        if status != 0 {
            return Err(anyhow!(
                "Fritz local model: cannot parse model output ({output})"
            ));
        }
        Ok(serde_json::from_str(&output)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Qwen 3.5's published chat template (Apache-2.0), as embedded in the
    // catalog's GGUF files. Copied from llama.cpp's models/templates.
    const QWEN: &str = include_str!("../../tests/fixtures/qwen3.5-chat-template.jinja");

    fn tools() -> Value {
        json!(
            crate::tools::definitions()
                .iter()
                .map(|d| json!({"type":"function","function":d}))
                .collect::<Vec<_>>()
        )
    }

    fn conversation() -> Value {
        json!([{"role":"system","content":"Be brief."},{"role":"user","content":"Read a.txt"}])
    }

    #[test]
    fn template_renders_tools_and_a_lazy_call_grammar() {
        let templates = Templates::new(QWEN, "", "<|im_end|>").unwrap();
        let applied = templates.apply(&conversation(), &tools(), false).unwrap();
        assert!(applied.prompt.contains("<tools>"));
        assert!(applied.prompt.contains("\"name\": \"run_command\""));
        assert!(
            applied
                .prompt
                .ends_with("<|im_start|>assistant\n<think>\n\n</think>\n\n")
        );
        assert!(applied.grammar_lazy);
        assert!(applied.grammar.contains("read_file"));
        assert!(applied.trigger_patterns.contains(&"<tool_call>".to_owned()));
        assert!(applied.preserved_tokens.contains(&"<tool_call>".to_owned()));
    }

    #[test]
    fn tool_calls_parse_into_openai_shape() {
        let templates = Templates::new(QWEN, "", "<|im_end|>").unwrap();
        let applied = templates.apply(&conversation(), &tools(), false).unwrap();
        let output = "Checking.\n\n<tool_call>\n<function=read_file>\n<parameter=path>\na.txt\n</parameter>\n</function>\n</tool_call>";
        let message = applied.parse(output, false).unwrap();
        assert_eq!(message["content"].as_str().unwrap().trim(), "Checking.");
        let call = &message["tool_calls"][0]["function"];
        assert_eq!(call["name"], "read_file");
        let arguments: Value = serde_json::from_str(call["arguments"].as_str().unwrap()).unwrap();
        assert_eq!(arguments, json!({"path":"a.txt"}));
        // Streaming parses never expose a call that is still being written as prose.
        let partial = applied.parse(&output[..30], true).unwrap();
        assert!(!partial["content"].as_str().unwrap().contains("<tool"));
        let prose = applied.parse("The file is empty.", false).unwrap();
        assert_eq!(prose["content"], "The file is empty.");
        assert!(prose["tool_calls"].is_null());
    }

    #[test]
    fn tool_history_round_trips_through_the_template() {
        let templates = Templates::new(QWEN, "", "<|im_end|>").unwrap();
        let mut messages = conversation();
        messages.as_array_mut().unwrap().extend([
            json!({"role":"assistant","content":"","tool_calls":[{"id":"fritz-0","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"a.txt\"}"}}]}),
            json!({"role":"tool","tool_call_id":"fritz-0","content":"{\"content\":\"hello\"}"}),
        ]);
        let prompt = templates.apply(&messages, &tools(), false).unwrap().prompt;
        assert!(prompt.contains("<function=read_file>\n<parameter=path>\na.txt"));
        assert!(prompt.contains("<tool_response>\n{\"content\":\"hello\"}\n</tool_response>"));
    }

    #[test]
    fn templates_without_tool_support_produce_no_call_grammar() {
        let templates = Templates::new("chatml", "", "<|im_end|>").unwrap();
        let applied = templates.apply(&conversation(), &tools(), false).unwrap();
        assert!(applied.grammar.is_empty());
        assert!(!applied.prompt.contains("run_command"));
    }

    #[test]
    fn invalid_templates_are_reported() {
        assert!(Templates::new("{% if %}", "", "").is_err());
    }
}
