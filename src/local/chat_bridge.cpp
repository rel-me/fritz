// Thin C boundary over llama.cpp's own chat library (common/chat.h), the code
// llama-server uses for templates, tool-call grammars and tool-call parsing.
// Fritz owns no model-specific formats: everything here forwards to llama.cpp.
// All payloads cross as JSON strings in OpenAI chat-completions shape.

#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>
#include <vector>

#include "common/chat.h"
#include <nlohmann/json.hpp>

using ordered_json = nlohmann::ordered_json;

namespace {
char * duplicate(const std::string & text) {
    auto * copy = static_cast<char *>(std::malloc(text.size() + 1));
    if (copy) {
        std::memcpy(copy, text.c_str(), text.size() + 1);
    }
    return copy;
}

int fail(char ** output, const char * message) {
    *output = duplicate(message);
    return 1;
}

}  // namespace

struct fritz_chat_templates {
    common_chat_templates_ptr templates;
};

extern "C" {

fritz_chat_templates * fritz_chat_templates_new(const char * source,
                                                const char * bos_token,
                                                const char * eos_token,
                                                char ** error) {
    *error = nullptr;
    try {
        auto templates = common_chat_templates_init(nullptr, source, bos_token, eos_token);
        return new fritz_chat_templates{ std::move(templates) };
    } catch (const std::exception & e) {
        *error = duplicate(e.what());
    } catch (...) {
        *error = duplicate("unknown chat template error");
    }
    return nullptr;
}

void fritz_chat_templates_free(fritz_chat_templates * templates) {
    delete templates;
}

// Input: {"messages":[...], "tools":[...], "enable_thinking":bool}
// Output: prompt, lazy grammar and its triggers, preserved tokens, extra stop
// strings, and the parser state that fritz_chat_parse needs for this prompt.
int fritz_chat_apply(const fritz_chat_templates * templates, const char * request, char ** output) {
    *output = nullptr;
    try {
        const auto body = ordered_json::parse(request);
        common_chat_templates_inputs inputs;
        inputs.messages = common_chat_msgs_parse_oaicompat(body.at("messages"));
        if (body.contains("tools")) {
            inputs.tools = common_chat_tools_parse_oaicompat(body.at("tools"));
        }
        inputs.parallel_tool_calls = !inputs.tools.empty();
        inputs.enable_thinking     = body.value("enable_thinking", false);
        inputs.reasoning_format    = COMMON_REASONING_FORMAT_DEEPSEEK;
        inputs.use_jinja           = true;
        inputs.add_generation_prompt = true;

        const auto params = common_chat_templates_apply(templates->templates.get(), inputs);
        // Mirrors common/sampling.cpp: lazy grammars take anchored regex patterns.
        ordered_json patterns = ordered_json::array();
        for (const auto & trigger : params.grammar_triggers) {
            switch (trigger.type) {
                case COMMON_GRAMMAR_TRIGGER_TYPE_WORD:
                    patterns.push_back(regex_escape(trigger.value));
                    break;
                case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN:
                    patterns.push_back(trigger.value);
                    break;
                case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN_FULL: {
                    const auto & pattern = trigger.value;
                    std::string anchored = "^$";
                    if (!pattern.empty()) {
                        anchored = (pattern.front() != '^' ? "^" : "") + pattern +
                                   (pattern.back() != '$' ? "$" : "");
                    }
                    patterns.push_back(anchored);
                    break;
                }
                case COMMON_GRAMMAR_TRIGGER_TYPE_TOKEN:
                    // Token triggers need a vocabulary; chat templates emit none.
                    return fail(output, "unsupported token grammar trigger");
            }
        }
        const ordered_json result = {
            { "prompt", params.prompt },
            { "grammar", params.grammar },
            { "grammar_lazy", params.grammar_lazy },
            { "trigger_patterns", patterns },
            { "preserved_tokens", params.preserved_tokens },
            { "additional_stops", params.additional_stops },
            { "format", static_cast<int>(params.format) },
            { "generation_prompt", params.generation_prompt },
            { "parser", params.parser },
        };
        *output = duplicate(result.dump());
        return *output ? 0 : 1;
    } catch (const std::exception & e) {
        return fail(output, e.what());
    } catch (...) {
        return fail(output, "unknown chat template error");
    }
}

// Parses generated text with the parser state returned by fritz_chat_apply.
// Output is one OpenAI-shaped assistant message with content, optional
// reasoning_content, and tool_calls whose arguments are JSON strings.
int fritz_chat_parse(const char * state, const char * text, bool partial, char ** output) {
    *output = nullptr;
    try {
        const auto applied = ordered_json::parse(state);
        common_chat_parser_params params;
        params.format            = static_cast<common_chat_format>(applied.at("format").get<int>());
        params.generation_prompt = applied.at("generation_prompt").get<std::string>();
        params.reasoning_format  = COMMON_REASONING_FORMAT_DEEPSEEK;
        const auto parser        = applied.at("parser").get<std::string>();
        if (!parser.empty()) {
            params.parser.load(parser);
        }
        const auto message = common_chat_parse(text, partial, params);
        *output = duplicate(message.to_json_oaicompat().dump());
        return *output ? 0 : 1;
    } catch (const std::exception & e) {
        return fail(output, e.what());
    } catch (...) {
        return fail(output, "unknown chat parse error");
    }
}

void fritz_chat_string_free(char * text) {
    std::free(text);
}

}  // extern "C"
