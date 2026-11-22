#include "llama.h"
#include "ggml-backend.h"
#include "chat.h"
#include "fit.h"
#include "sampling.h"
#include "unicode.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>

using json = common_json;
using Cancel = bool (*)(void *);
using Emit = bool (*)(void *, const char *);
static void require(bool value, const char * message) {
    if (!value) throw std::runtime_error(message);
}
static char * copy(const std::string & text) {
    auto * result = new char[text.size()+1];
    std::memcpy(result, text.c_str(), text.size()+1);
    return result;
}
struct Control {
    Cancel cancel;
    void * data;
    bool stopped() const { return cancel(data); }
    void check() const { require(!stopped(), "Local inference cancelled"); }
};
static bool progress(float, void * data) { return !static_cast<Control *>(data)->stopped(); }
static bool abort_decode(void * data) { return static_cast<Control *>(data)->stopped(); }

struct Model {
    std::unique_ptr<llama_model, decltype(&llama_model_free)> weights{nullptr, llama_model_free};
    std::unique_ptr<llama_context, decltype(&llama_free)> context{nullptr, llama_free};
    common_chat_templates_ptr templates;
    int capacity;
    void decode(std::vector<llama_token> & tokens, Control & control) {
        for (size_t start = 0; start < tokens.size(); start += 512) {
            control.check();
            const int n = std::min<size_t>(512, tokens.size()-start);
            require(llama_decode(context.get(), llama_batch_get_one(tokens.data()+start,n)) == 0,
                    "llama.cpp could not decode the local request");
            llama_synchronize(context.get());
        }
        control.check();
    }
    void reset(Control & control) {
        llama_set_abort_callback(context.get(), abort_decode, &control);
        llama_memory_clear(llama_get_memory(context.get()), true);
    }
};
// Clear callbacks before their stack-owned control object leaves scope.
struct CallbackScope {
    Model & model;
    ~CallbackScope() { llama_set_abort_callback(model.context.get(), nullptr, nullptr); }
};

static bool fits_context(const char * path, const llama_model_params & model,
                         const llama_context_params & context, ggml_backend_dev_t gpu,
                         bool automatic) {
    size_t available = 0, total = 0;
    ggml_backend_dev_memory(gpu, &available, &total);
    constexpr size_t gib = 1024ULL * 1024 * 1024;
    // The Metal working-set estimate alone doesn't account for other apps'
    // memory growth while a chat is running.
    const size_t headroom = automatic ? std::max(3 * gib, total / 6) : gib;
    if (available <= headroom) return false;
    const auto rows = common_fit_measure({path}, &model, &context, nullptr, nullptr, GGML_LOG_LEVEL_ERROR);
    size_t bytes = 0;
    // Apple silicon Metal and CPU buffers consume the same physical memory.
    for (const auto & row : rows) bytes += row.model + row.context + row.compute;
    return bytes <= available - headroom;
}

extern "C" void fl_string_free(char * value) { delete[] value; }
extern "C" void fl_model_free(Model * model) { delete model; }
extern "C" int fl_model_context_size(const Model * model) { return model->capacity; }
extern "C" Model * fl_model_load(const char * path, int context, int minimum_context, bool chat, bool inkling_loop,
                                 bool quantize_kv_cache, Cancel cancel, void * data, char ** error) {
    try {
        static std::once_flag initialized;
        std::call_once(initialized, [] {
            llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
            llama_backend_init();
            ggml_backend_load_all();
        });
        Control control{cancel,data};
        control.check();
        auto gpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
        require(gpu, "Metal is unavailable for local inference");
        ggml_backend_dev_t devices[] = {gpu,nullptr};
        auto params = llama_model_default_params();
        params.devices = devices;
        params.n_gpu_layers = 999;
        // Keep the six non-repeating prelude layers' experts in CPU memory on
        // smaller Metal devices, leaving room for the loop's KV and compute buffers.
        const llama_model_tensor_buft_override inkling_overrides[] = {
            {R"(^blk\.[0-5]\.ffn_(gate_up|down)_exps\.weight$)", ggml_backend_cpu_buffer_type()},
            {nullptr, nullptr},
        };
        if (inkling_loop) {
            size_t metal_free, metal_total;
            ggml_backend_dev_memory(gpu, &metal_free, &metal_total);
            if (metal_free < 20ULL * 1024 * 1024 * 1024) {
                params.tensor_buft_overrides = inkling_overrides;
            }
        }
        params.progress_callback = progress;
        params.progress_callback_user_data = &control;
        auto config = llama_context_default_params();
        config.n_ctx = context;
        config.n_batch = 512;
        config.n_ubatch = 512;
        config.n_seq_max = 1;
        if (quantize_kv_cache) {
            config.type_k = GGML_TYPE_Q8_0;
            config.type_v = GGML_TYPE_Q8_0;
            config.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
        }
        config.abort_callback = abort_decode;
        config.abort_callback_data = &control;
        if (minimum_context > 0) {
            // llama.cpp's measurement temporarily installs a process-wide logger.
            static std::mutex measure_lock;
            const std::lock_guard<std::mutex> lock(measure_lock);
            const auto minimum = static_cast<uint32_t>(minimum_context);
            const bool automatic = config.n_ctx > minimum;
            const uint32_t default_ubatch = config.n_ubatch;
            // Inkling's full-attention layers need more compute memory at long
            // windows. A smaller physical batch leaves room for the KV cache.
            if (inkling_loop) config.n_ubatch = 128;
            auto fits = [&](uint32_t candidate) {
                config.n_ctx = candidate;
                control.check();
                try {
                    return fits_context(path, params, config, gpu, automatic);
                } catch (const std::runtime_error & error) {
                    control.check();
                    if (std::strcmp(error.what(), "failed to create llama_context from model") != 0) throw;
                    if (quantize_kv_cache && candidate == minimum) {
                        throw std::runtime_error("llama.cpp could not initialize the 8-bit KV cache. Turn off Quantize Local KV Cache or choose a smaller Context Budget.");
                    }
                    return false;
                }
            };
            uint32_t fitting = config.n_ctx;
            uint32_t too_large = fitting;
            while (!fits(fitting)) {
                require(fitting > minimum,
                        "The local context does not fit available Metal memory. Choose a smaller Context Budget, a smaller model, or close other models.");
                too_large = fitting;
                fitting = std::max(fitting / 2, minimum);
            }
            // Refine the bracket in useful increments without probing every token count.
            constexpr uint32_t step = 4096;
            while (too_large - fitting > step) {
                const uint32_t mid = fitting + (too_large - fitting) / 2;
                const uint32_t candidate = std::max(mid / step * step, fitting + step);
                if (fits(candidate)) fitting = candidate;
                else too_large = candidate;
            }
            if (inkling_loop) {
                const uint32_t smaller_ubatch = config.n_ubatch;
                config.n_ubatch = default_ubatch;
                if (!fits(fitting)) config.n_ubatch = smaller_ubatch;
            }
            config.n_ctx = fitting;
        }
        auto result = std::make_unique<Model>();
        result->weights.reset(llama_model_load_from_file(path, params));
        control.check();
        require(bool(result->weights), "llama.cpp could not load the local GGUF. Check model integrity and available memory.");
        result->context.reset(llama_init_from_model(result->weights.get(), config));
        control.check();
        require(bool(result->context), "llama.cpp could not allocate the local context. Close other models or reduce context size.");
        result->capacity = std::min(config.n_ctx, llama_n_ctx_seq(result->context.get()));
        llama_set_abort_callback(result->context.get(), nullptr, nullptr);
        if (chat) {
            const auto * tmpl = llama_model_chat_template(result->weights.get(), nullptr);
            require(tmpl && *tmpl, "The local GGUF has no chat template");
            result->templates = common_chat_templates_init(result->weights.get(), "");
        }
        return result.release();
    } catch (const std::exception & e) {
        *error = copy(e.what());
        return nullptr;
    }
}
extern "C" char * fl_tokenize(Model * model, const char * text, bool special) {
    try {
        return copy(json({{"tokens",common_tokenize(llama_model_get_vocab(model->weights.get()),text,special,true)}}).dump());
    } catch (const std::exception & e) { return copy(json({{"error",e.what()}}).dump()); }
}
extern "C" char * fl_logits(Model * model, const unsigned * ids, size_t n, unsigned first,
                            size_t count, Cancel cancel, void * data) {
    try {
        require(n>0 && n<=size_t(model->capacity), "Bosun prompt exceeds its context limit");
        const int vocab = llama_vocab_n_tokens(llama_model_get_vocab(model->weights.get()));
        require(vocab == 151925, "Bosun vocabulary differs from the pinned contract");
        require(first<=unsigned(vocab) && count<=size_t(vocab-first), "Bosun decision slots exceed the model vocabulary");
        Control control{cancel,data};
        model->reset(control);
        CallbackScope scope{*model};
        std::vector<llama_token> tokens(ids,ids+n);
        model->decode(tokens,control);
        const float * scores = llama_get_logits_ith(model->context.get(),-1);
        require(scores, "Bosun returned no final-position logits");
        std::vector<float> result(scores+first,scores+first+count);
        return copy(json({{"logits",result}}).dump());
    } catch (const std::exception & e) { return copy(json({{"error",e.what()}}).dump()); }
}
extern "C" char * fl_chat(Model * model, const char * input, Cancel cancel, void * cancel_data,
                          Emit emit, void * emit_data) {
    try {
        Control control{cancel,cancel_data};
        model->reset(control);
        CallbackScope scope{*model};
        const auto request = json::parse(input);
        common_chat_templates_inputs inputs;
        inputs.messages = common_chat_msgs_parse_oaicompat(request.at("messages"));
        inputs.enable_thinking = !request.value("disable_thinking",false);
        inputs.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
        inputs.parallel_tool_calls = true;
        if (request.contains("tools")) inputs.tools = common_chat_tools_parse_oaicompat(request["tools"]);
        if (request.value("json_format",false)) inputs.json_schema = "{}";
        const auto * vocab = llama_model_get_vocab(model->weights.get());
        common_chat_session session(model->templates.get(),vocab,inputs);
        auto tokens = common_tokenize(model->context.get(),session.prompt().str(),true,true);
        const auto prompt_tokens = tokens.size();
        const int limit = request.at("limit").get<int>();
        require(limit>0 && limit<=32768, "Invalid local output limit");
        require(prompt_tokens>0 && prompt_tokens+size_t(limit)<=size_t(model->capacity),
                "The local conversation and requested output exceed the model context. Compact the conversation or reduce output size.");
        common_params_sampling sampling;
        sampling.temp = 0;
        session.apply_sampling(sampling);
        auto sampler = std::unique_ptr<common_sampler,decltype(&common_sampler_free)>(
            common_sampler_init(model->weights.get(),sampling), common_sampler_free);
        require(bool(sampler), "Could not initialize local sampling");
        model->decode(tokens,control);
        common_chat_input pending;
        std::string sent;
        auto publish = [&](const common_chat_msg & message) {
            require(message.content.compare(0,sent.size(),sent)==0,
                    "The local chat parser revised already streamed content");
            if (message.content.size()>sent.size()) {
                auto delta = json({{"type","delta"},{"text",message.content.substr(sent.size())}}).dump();
                require(emit(emit_data,delta.c_str()), "Local inference cancelled");
                sent = message.content;
            }
        };
        bool complete = false;
        int generated = 0;
        for (; generated<limit;) {
            control.check();
            auto token = common_sampler_sample(sampler.get(),model->context.get(),-1);
            common_sampler_accept(sampler.get(),token,true);
            if (llama_vocab_is_eog(vocab,token)) { complete=true; break; }
            ++generated;
            pending.append(common_token_to_piece(model->context.get(),token,true),token);
            size_t safe = pending.text.size();
            for (const auto & stop : session.additional_stops()) {
                auto found = pending.text.find(stop);
                if (found!=std::string::npos) { safe=std::min(safe,found); complete=true; }
                if (!complete) {
                    for (size_t n=1;n<stop.size() && n<=pending.text.size();++n) {
                        if (pending.text.compare(pending.text.size()-n,n,stop,0,n)==0)
                            safe=std::min(safe,pending.text.size()-n);
                    }
                }
            }
            // Hold incomplete UTF-8 and possible stop delimiters across tokens.
            size_t valid=0;
            while (valid<safe) {
                auto cp=common_parse_utf8_codepoint(std::string_view(pending.text).substr(0,safe),valid);
                require(cp.status!=utf8_parse_result::INVALID,"Local model produced invalid UTF-8");
                if (cp.status==utf8_parse_result::INCOMPLETE) break;
                valid+=cp.bytes_consumed;
            }
            if (valid) {
                publish(session.feed(pending.substr(0,valid)));
                pending=pending.substr(valid);
            }
            if (complete) { pending={}; break; }
            if (generated<limit) {
                std::vector<llama_token> next{token};
                model->decode(next,control);
            }
        }
        auto final = complete ? session.finish(pending) : session.msg();
        // Length-limited output is never promoted into an executable tool call.
        if (complete) publish(final);
        auto result=final.to_json_oaicompat();
        if (!complete) result.erase("tool_calls");
        result["input_tokens"]=prompt_tokens;
        result["output_tokens"]=generated;
        result["truncated"]=!complete;
        return copy(result.dump());
    } catch (const std::exception & e) { return copy(json({{"error",e.what()}}).dump()); }
}
