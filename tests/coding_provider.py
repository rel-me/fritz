"""Provider-native tool streams for deterministic harness verification."""
import json
import time
from mock_provider import Provider


class CodingProvider(Provider):
    def do_GET(self):
        if self.path == "/v1/models":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"data": [{"id": name, "name": name} for name in ["coding-test", "cancel-command", "fritz-test"]]}).encode())
        else:
            super().do_GET()

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append(payload)
        model = payload.get("model", self.path)
        kind = "compatible"
        if self.path.endswith("/responses"):
            kind = "openai"
            history = payload["input"]
            results = [m for m in history if m.get("type") == "function_call_output"]
        elif self.path.endswith("/messages"):
            kind = "anthropic"
            history = payload["messages"]
            results = [p for m in history for p in m.get("content", []) if isinstance(p, dict) and p.get("type") == "tool_result"]
        elif ":streamGenerateContent" in self.path:
            kind = "gemini"
            history = payload["contents"]
            results = [p for m in history for p in m["parts"] if "functionResponse" in p]
        else:
            kind = "ollama" if self.path.endswith("/api/chat") else "compatible"
            history = payload["messages"]
            results = [m for m in history if m["role"] == "tool"]
        n = len(results)
        # Each turn checks that the previous round really returned native tool results.
        if n:
            encoded = json.dumps(history)
            if kind == "openai":
                assert "opaque-reasoning" in encoded
            if kind == "compatible":
                assert "opaque-router-signature" in encoded
            if kind in ("anthropic", "gemini"):
                assert "opaque-signature" in encoded
        call = None
        if "cancel-command" in model:
            if n == 0:
                call = ("run_command", {"command": "echo $$ > running.pid; sleep 30 & echo $! > descendant.pid; wait", "timeout_seconds": 120})
        elif "loop-test" in model:
            call = ("list_files", {"path": "."})
        elif "invalid-tool" in model:
            if n == 0:
                call = ("invented_tool", {})
            elif n == 1:
                assert "Unknown tool" in json.dumps(results)
                call = ("read_file", {"path": "hello.txt"})
        elif "unsafe-path" in model:
            if n == 0:
                call = ("create_file", {"path": "../outside.txt", "content": "wrong"})
            else:
                assert "relative project path" in json.dumps(results)
        elif payload.get("tools"):
            if n == 0:
                call = ("read_file", {"path": "hello.txt"})
            elif n == 1:
                assert "before" in json.dumps(results)
                call = ("edit_file", {"path": "hello.txt", "old_text": "before", "new_text": "after"})
            elif n == 2:
                assert "edited" in json.dumps(results)
                call = ("run_command", {"command": "test \"$(cat hello.txt)\" = after && printf 'verified\\n'", "timeout_seconds": 5})
            elif n == 3:
                assert "verified" in json.dumps(results)
        text = "Updated hello.txt and verified the result." if n else "Hello from Fritz."
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson" if kind == "ollama" else "text/event-stream")
        self.end_headers()
        def emit(v):
            encoded = json.dumps(v)
            self.wfile.write((encoded + "\n" if kind == "ollama" else "data: " + encoded + "\n\n").encode())
            self.wfile.flush()
        try:
            if kind == "compatible":
                emit({"choices": [{"delta": {"reasoning_details": [{"type": "reasoning.encrypted", "index": 0, "data": "opaque-router-signature", "format": "anthropic-claude-v1"}]}}]})
                if call:
                    name, args = call
                    args = json.dumps(args)
                    emit({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": f"call-{n}", "type": "function", "function": {"name": name, "arguments": args[:5]}}]}}]})
                    if "partial-tool" in model:
                        return
                    emit({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": args[5:]}}]}, "finish_reason": "tool_calls"}]})
                else:
                    for piece in text.split(" "):
                        emit({"choices": [{"delta": {"content": piece + " "}}]})
                    emit({"choices": [{"delta": {}, "finish_reason": "stop"}], "usage": {"total_tokens": 42}})
                self.wfile.write(b"data: [DONE]\n\n")
            elif kind == "openai":
                output = [{"type": "reasoning", "id": f"r-{n}", "summary": [], "encrypted_content": "opaque-reasoning"}]
                if call:
                    name, args = call
                    output.append({"type": "function_call", "call_id": f"call-{n}", "name": name, "arguments": json.dumps(args)})
                else:
                    emit({"type": "response.output_text.delta", "delta": text})
                    output.append({"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]})
                emit({"type": "response.completed", "response": {"status": "completed", "output": output, "usage": {"total_tokens": 42}}})
            elif kind == "anthropic":
                emit({"type": "message_start", "message": {"usage": {"input_tokens": 10}}})
                emit({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
                emit({"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "opaque-signature"}})
                emit({"type": "content_block_stop", "index": 0})
                if call:
                    name, args = call
                    emit({"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": f"call-{n}", "name": name, "input": {}}})
                    emit({"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": json.dumps(args)}})
                else:
                    emit({"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}})
                    emit({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": text}})
                emit({"type": "content_block_stop", "index": 1})
                emit({"type": "message_delta", "delta": {"stop_reason": "tool_use" if call else "end_turn"}, "usage": {"output_tokens": 32}})
                emit({"type": "message_stop"})
            elif kind == "gemini":
                parts = [{"functionCall": {"id": f"call-{n}", "name": call[0], "args": call[1]}, "thoughtSignature": "opaque-signature"}] if call else [{"text": text}]
                emit({"candidates": [{"content": {"role": "model", "parts": parts}, "finishReason": "STOP"}], "usageMetadata": {"totalTokenCount": 42}})
            elif kind == "ollama":
                message = {"role": "assistant", "content": "" if call else text}
                if call:
                    message["tool_calls"] = [{"function": {"name": call[0], "arguments": call[1]}}]
                emit({"message": message, "done": True, "done_reason": "stop", "prompt_eval_count": 10, "eval_count": 32})
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    from http.server import ThreadingHTTPServer
    server = ThreadingHTTPServer(("127.0.0.1", 0), CodingProvider)
    print(server.server_address[1], flush=True)
    server.serve_forever()
