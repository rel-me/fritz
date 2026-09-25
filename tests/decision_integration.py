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
        child.stdin.write(json.dumps({"id": "decision-1", "method": "decisions.evaluate",
                                      "params": decision_input(endpoint)}) + "\n")
        child.stdin.flush()
        event = json.loads(child.stdout.readline())
        child.stdin.close()
        child.wait(timeout=15)
        assert child.returncode == 0, child.stderr.read()
        return event


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), DecisionEndpoint)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"http://127.0.0.1:{server.server_port}/v1/systemone"
    try:
        result = evaluate(endpoint)
        assert result["type"] == "result", result
        assert result["result"]["answers"]["intent"]["choice"] == "reminder"
        assert result["result"]["model"] == "jev-1.13.0"
        assert DecisionEndpoint.requests[-1]["questions"]["time_sensitive"]["type"] == "noul"
        agent_result = evaluate_via_agent(endpoint)
        assert agent_result["id"] == "decision-1" and agent_result["type"] == "result", agent_result
        assert agent_result["result"]["answers"]["intent"]["choice"] == "reminder"
        assert evaluate(endpoint, {"invalid": True})["type"] == "error"
        assert evaluate(endpoint, key=None)["type"] == "error"
        assert evaluate(endpoint, cancel=True)["type"] == "cancelled"
        print("PASS: typed Jev request/response, agent supervision, invalid answer rejection, missing key, pipe cancellation")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
