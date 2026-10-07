"""Exercise decision transports and provider boundaries without remote credentials."""
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
        if self.path == "/v1/decisions":
            return self.openai_decision()
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

    def openai_decision(self):
        assert self.headers["Authorization"] == "Bearer test-key"
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append(request)
        assert request["model"] == "gpt-6-luna"
        assert [q["name"] for q in request["questions"]] == ["intent", "priority", "time_sensitive"]
        assert request["questions"][0] == {
            "type": "choice", "name": "intent", "instructions": "What is requested?",
            "choices": [{"value": "other", "description": "Something else"},
                        {"value": "reminder", "description": "A reminder"}],
        }
        assert request["questions"][1]["levels"] == [
            {"label": "0", "description": '{"urgency":"low"}'},
            {"label": "1", "description": '{"urgency":"high"}'},
        ]
        assert request["questions"][2]["type"] == "predicate"
        state = json.loads(request["input"])
        answers = [
            {"type": "choice", "name": "intent", "choice": "reminder", "confidence": 0.8,
             "probabilities": [{"value": "reminder", "probability": 0.9}, {"value": "other", "probability": 0.1}]},
            {"type": "score", "name": "priority", "score": 0.3, "confidence": 0.4,
             "probabilities": [{"value": 0, "label": "0", "probability": 0.7}, {"value": 1, "label": "1", "probability": 0.3}]},
            {"type": "predicate", "name": "time_sensitive", "probability": 0.3},
        ]
        failure = state.get("failure")
        if failure == "refusal": answers[0] = {"type": "refusal", "name": "intent"}
        if failure == "name": answers[0]["name"] = "wrong"
        if failure == "order": answers.reverse()
        if failure == "duplicate": answers[0]["probabilities"][1]["value"] = "reminder"
        if failure == "score_label": answers[1]["probabilities"][1]["label"] = "wrong"
        if failure == "score_value": answers[1]["probabilities"][1]["value"] = 8
        if failure == "distribution": answers[0]["probabilities"][1]["probability"] = 0.8
        if failure == "missing": answers.pop()
        body = json.dumps({"model": "gpt-6-luna", "answers": answers,
                           "usage": {"input_tokens": 24, "output_tokens": 0, "total_tokens": 24}}).encode()
        self.send_response(429 if failure == "http" else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass


def openai_transport(endpoint):
    def run(state=None, key="test-key", cancel=False, model="gpt-6-luna"):
        payload = decision_input(endpoint, state, key)
        payload["backend"]["kind"] = "openai"
        payload["request"]["model"] = model
        child = subprocess.Popen([str(BIN), "evaluate"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        child.stdin.write(json.dumps(payload) + "\n")
        child.stdin.flush()
        if cancel: child.stdin.close()
        result = json.loads(child.stdout.readline())
        if not cancel: child.stdin.close()
        child.wait(timeout=15)
        assert child.stdout.readline() == "", "Expected one terminal event"
        return result
    agent_result = evaluate_via_agent(endpoint, openai=True)
    assert agent_result["type"] == "result", agent_result
    assert agent_result["result"]["model"] == "gpt-6-luna"
    result = run()
    assert result["type"] == "result", result
    answers = result["result"]["answers"]
    assert answers["intent"]["choice"] == "reminder"
    assert answers["time_sensitive"] == {"type": "noul", "noul": 0.3}
    assert answers["priority"]["legend"] == {"0": {"urgency": "low"}, "1": {"urgency": "high"}}
    assert answers["priority"]["score"] == 0.3
    assert result["result"]["usage"] == {"input_tokens": 24, "output_tokens": 0}
    for failure in ["refusal", "name", "order", "duplicate", "score_label", "score_value", "distribution", "missing", "http"]:
        assert run({"failure": failure})["type"] == "error", failure
    assert "requires an API key" in run(key=None)["message"]
    assert "gpt-6-luna" in run(model="chat-model")["message"]
    assert run(cancel=True)["type"] == "cancelled"
    with tempfile.TemporaryDirectory(prefix="fritz-openai-decisions-") as data:
        env = dict(os.environ, FRITZ_DATA_DIR=data)
        def cli(*args, ok=True, input=None):
            result = subprocess.run([str(BIN.with_name("fritz")), *args], env=env, input=input,
                                    capture_output=True, text=True, timeout=20)
            assert (result.returncode == 0) == ok, result.stderr
            return result
        registry = json.loads(cli("add-provider", "--name", "OpenAI Decisions", "--provider", "openai-decisions",
                                  "--model", "gpt-6-luna", "--base-url", endpoint.removesuffix("/decisions"),
                                  "--api-key-stdin", input="test-key").stdout)
        connection = registry["connections"][0]["id"]
        try:
            assert registry["defaultConnectionId"] is None
            assert json.loads(cli("models", "--connection", connection).stdout) == [{"id": "gpt-6-luna", "displayName": "GPT-6 Luna"}]
            request = decision_input(endpoint)["request"]
            request["model"] = "gpt-6-luna"
            saved_result = json.loads(cli("decide", "--connection", connection, input=json.dumps(request)).stdout)
            assert saved_result["answers"]["intent"]["choice"] == "reminder"
            assert "LLM" in cli("default-provider", connection, ok=False).stderr
            assert "LLM" in cli("chat", "Hello", "--connection", connection, ok=False).stderr
            cli("add-provider", "--name", "Invalid model", "--provider", "openai-decisions", "--model", "chat-model", ok=False)
        finally:
            cli("remove-provider", connection)
    print("PASS: OpenAI Decisions wire translation, refusals, invalid answers, usage, cancellation, and chat/default exclusion")


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


def evaluate_via_agent(endpoint, openai=False):
    with tempfile.TemporaryDirectory(prefix="fritz-decision-test-") as data:
        env = os.environ.copy()
        env["FRITZ_DATA_DIR"] = data
        env["FRITZ_MODELS_DIR"] = str(Path(data) / "Models")
        child = subprocess.Popen([str(BIN.with_name("fritz")), "--agent"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=env)
        jev_connection = {
            "id": "e2aa77fb-18e9-42c8-9e47-45798368ab35",
            "name": "Jev", "provider": "jev", "modelId": "jev-latest",
        }
        payload = decision_input(endpoint)
        if openai:
            jev_connection.update(name="OpenAI Decisions", provider="openai-decisions", modelId="gpt-6-luna")
            payload["backend"]["kind"] = "openai"
            payload["request"]["model"] = "gpt-6-luna"
        child.stdin.write(json.dumps({"id": "catalog-1", "method": "models.list",
                                      "params": {"connection": jev_connection,
                                                 "apiKey": "test-key"}}) + "\n")
        child.stdin.write(json.dumps({"id": "decision-1", "method": "decisions.evaluate",
                                      "params": payload}) + "\n")
        child.stdin.flush()
        events = [json.loads(child.stdout.readline()) for _ in range(2)]
        child.stdin.close()
        child.wait(timeout=15)
        assert child.returncode == 0, child.stderr.read()
        catalog = next(event for event in events if event["id"] == "catalog-1")
        assert catalog["result"]["models"][0]["id"] == ("gpt-6-luna" if openai else "jev-latest"), catalog
        return next(event for event in events if event["id"] == "decision-1")


def local_provider_boundaries():
    with tempfile.TemporaryDirectory(prefix="fritz-local-decision-") as data:
        env = dict(os.environ, FRITZ_DATA_DIR=data, FRITZ_MODELS_DIR=str(Path(data) / "Models"))
        def cli(*args, ok=True, input=None):
            result = subprocess.run([str(BIN.with_name("fritz")), *args], env=env,
                                    input=input, capture_output=True, text=True, timeout=20)
            assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
            return result
        catalog = json.loads(cli("decision-models", "list").stdout)["models"]
        model = catalog[0]["id"]
        assert catalog and not any(item["installed"] for item in catalog)
        assert any(item["id"] == "kev-4b" for item in catalog)
        registry = json.loads(cli("add-provider", "--name", "Local decision", "--provider", "ollaya", "--model", model).stdout)
        connection = registry["connections"][0]["id"]
        assert registry["defaultConnectionId"] is None
        assert json.loads(cli("models", "--connection", connection).stdout) == []
        assert "LLM" in cli("default-provider", connection, ok=False).stderr
        assert "LLM" in cli("chat", "Hello", "--connection", connection, ok=False).stderr
        request = decision_input("unused")["request"]
        request["model"] = model
        assert "not installed" in cli("decide", "--connection", connection, input=json.dumps(request), ok=False).stderr
        for item in catalog:
            request["model"] = item["id"]
            assert "not installed" in cli("decide", "--connection", connection, input=json.dumps(request), ok=False).stderr
        request["model"] = "../../outside"
        assert "Unknown local decision model" in cli("decide", "--connection", connection, input=json.dumps(request), ok=False).stderr
        cli("add-provider", "--name", "Invalid endpoint", "--provider", "ollaya", "--base-url", "https://example.com", ok=False)
        cli("add-provider", "--name", "Invalid key", "--provider", "ollaya", "--api-key-stdin", input="synthetic-key", ok=False)
        assert not (Path(data) / "Models").exists(), "Listing/evaluation must never download weights"
        print("PASS: local decision discovery, explicit-install requirement, missing model, native provider validation, chat/default exclusion")


def local_private_input():
    with tempfile.TemporaryDirectory(prefix="fritz-host-decision-") as data:
        payload = decision_input("unused")
        payload["request"]["model"] = "kev-4b"
        payload["backend"] = {"kind": "ollaya"}
        payload["apiKey"] = None
        cases = [(None, None, "explicit modelStore"),
                 ({"directory": "relative"}, None, "absolute"),
                 ({"directory": data}, "forbidden-local-key", "API key"),
                 ({"directory": data}, None, "not installed")]
        for store, key, message in cases:
            payload["modelStore"] = store
            payload["apiKey"] = key
            child = subprocess.Popen([str(BIN), "evaluate"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            child.stdin.write(json.dumps(payload) + "\n")
            child.stdin.flush()
            terminal = json.loads(child.stdout.readline())
            child.stdin.close()
            child.wait(timeout=15)
            assert terminal["type"] == "error" and message in terminal["message"], terminal
            assert child.stdout.readline() == "", "Expected one terminal event"
        assert not any(Path(data).iterdir()), "Local inference must not create or download model artifacts"
        print("PASS: private local decisions require explicit absolute paths, reject credentials, and never download")


def main():
    local_provider_boundaries()
    local_private_input()
    server = ThreadingHTTPServer(("127.0.0.1", 0), DecisionEndpoint)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"http://127.0.0.1:{server.server_port}/v1/systemone"
    try:
        openai_transport(endpoint.replace("systemone", "decisions"))
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
