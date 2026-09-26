"""Exercise the bundled decision harness against a deterministic Jev-shaped endpoint."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
from threading import Thread


BIN = Path(os.environ.get("FRITZ_TEST_BIN_DIR", "target/debug")) / "fritz-decision-harness"


class DecisionEndpoint(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        assert self.path == "/v1/systemone"
        assert self.headers["Authorization"] == "Bearer test-key"
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append(request)
        answers = {
            "intent": {
                "type": "choice",
                "choice": "reminder",
                "probabilities": {"reminder": 0.9, "other": 0.1},
                "confidence": 0.8,
            },
            "time_sensitive": {"type": "noul", "noul": 0.3},
            "priority": {"type": "score", "score": 0.3, "legend": {"0": {"urgency": "low"}, "1": {"urgency": "high"}}, "probabilities": {"0": 0.7, "1": 0.3}, "confidence": 0.4},
        }
        if request["state"].get("invalid"):
            answers["intent"]["probabilities"] = {"reminder": 0.2, "other": 0.2}
        body = json.dumps({"model": "jev-1.13.0", "answers": answers,
                           "usage": {"input_tokens": 24, "output_tokens": 8}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def decision_input(endpoint, state=None, key="test-key"):
    return {
        "request": {
            "model": "jev-latest",
            "state": state or {"message": "Remind me tomorrow"},
            "questions": {
                "intent": {"type": "choice", "instructions": "What is requested?",
                           "criteria": {"reminder": "A reminder", "other": "Something else"}},
                "time_sensitive": {"type": "noul", "instructions": "Is this urgent?"},
                "priority": {"type": "score", "instructions": "How urgent?", "criteria": [{"urgency": "low"}, {"urgency": "high"}]},
            },
        },
        "backend": {"kind": "jev", "endpoint": endpoint},
        "apiKey": key,
    }


def evaluate(endpoint, state=None, key="test-key", cancel=False):
    child = subprocess.Popen([str(BIN), "evaluate"], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    child.stdin.write(json.dumps(decision_input(endpoint, state, key)) + "\n")
    child.stdin.flush()
    if cancel:
        child.stdin.close()
    line = child.stdout.readline()
    result = json.loads(line)
    child.wait(timeout=15)
    assert child.stdout.readline() == "", "Expected one terminal event"
    return result


def evaluate_via_agent(endpoint):
    with tempfile.TemporaryDirectory(prefix="fritz-decision-test-") as data:
        env = os.environ.copy()
        env["FRITZ_DATA_DIR"] = data
        child = subprocess.Popen([str(BIN.with_name("fritz")), "--agent"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=env)
        jev_connection = {
            "id": "e2aa77fb-18e9-42c8-9e47-45798368ab35",
            "name": "Jev", "provider": "jev", "modelId": "jev-latest",
        }
        child.stdin.write(json.dumps({"id": "catalog-1", "method": "models.list",
                                      "params": {"connection": jev_connection,
                                                 "apiKey": "test-key"}}) + "\n")
        child.stdin.write(json.dumps({"id": "decision-1", "method": "decisions.evaluate",
                                      "params": decision_input(endpoint)}) + "\n")
        child.stdin.flush()
        events = [json.loads(child.stdout.readline()) for _ in range(2)]
        child.stdin.close()
        child.wait(timeout=15)
        assert child.returncode == 0, child.stderr.read()
        catalog = next(event for event in events if event["id"] == "catalog-1")
        assert catalog["result"]["models"][0]["id"] == "jev-latest", catalog
        return next(event for event in events if event["id"] == "decision-1")


def local_provider_boundaries():
    with tempfile.TemporaryDirectory(prefix="fritz-local-decision-") as data:
        env = dict(os.environ, FRITZ_DATA_DIR=data)
        def cli(*args, ok=True, input=None):
            result = subprocess.run([str(BIN.with_name("fritz")), *args], env=env,
                                    input=input, capture_output=True, text=True, timeout=20)
            assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
            return result
        catalog = json.loads(cli("decision-models", "list").stdout)["models"]
        model = catalog[0]["id"]
        assert catalog and not any(item["installed"] for item in catalog)
        registry = json.loads(cli("add-provider", "--name", "Local decision", "--provider", "ollaya", "--model", model).stdout)
        connection = registry["connections"][0]["id"]
        assert registry["defaultConnectionId"] is None
        assert json.loads(cli("models", "--connection", connection).stdout) == []
        assert "LLM" in cli("default-provider", connection, ok=False).stderr
        assert "LLM" in cli("chat", "Hello", "--connection", connection, ok=False).stderr
        request = decision_input("unused")["request"]
        request["model"] = model
        assert "not installed" in cli("decide", "--connection", connection, input=json.dumps(request), ok=False).stderr
        request["model"] = "../../outside"
        assert "Unknown local decision model" in cli("decide", "--connection", connection, input=json.dumps(request), ok=False).stderr
        cli("add-provider", "--name", "Invalid endpoint", "--provider", "ollaya", "--base-url", "https://example.com", ok=False)
        cli("add-provider", "--name", "Invalid key", "--provider", "ollaya", "--api-key-stdin", input="synthetic-key", ok=False)
        assert not (Path(data) / "DecisionModels").exists(), "Listing/evaluation must never download weights"
        print("PASS: local decision discovery, explicit-install requirement, missing model, native provider validation, chat/default exclusion")


def main():
    local_provider_boundaries()
    server = ThreadingHTTPServer(("127.0.0.1", 0), DecisionEndpoint)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"http://127.0.0.1:{server.server_port}/v1/systemone"
    try:
        result = evaluate(endpoint)
        assert result["type"] == "result", result
        assert result["result"]["answers"]["intent"]["choice"] == "reminder"
        assert result["result"]["model"] == "jev-1.13.0"
        assert result["result"]["answers"]["priority"]["legend"]["1"] == {"urgency": "high"}
        assert DecisionEndpoint.requests[-1]["questions"]["time_sensitive"]["type"] == "noul"
        agent_result = evaluate_via_agent(endpoint)
        assert agent_result["id"] == "decision-1" and agent_result["type"] == "result", agent_result
        assert agent_result["result"]["answers"]["intent"]["choice"] == "reminder"
        assert evaluate(endpoint, {"invalid": True})["type"] == "error"
        assert evaluate(endpoint, key=None)["type"] == "error"
        assert evaluate(endpoint, cancel=True)["type"] == "cancelled"
        print("PASS: Jev decision catalog, typed request/response, agent supervision, invalid answer rejection, missing key, pipe cancellation")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
