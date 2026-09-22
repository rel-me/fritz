"""Exercise the real Fritz executable with no API credentials or remote requests."""
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import uuid
from http.server import ThreadingHTTPServer
from mock_provider import Provider

ROOT = Path(__file__).resolve().parents[1]
EXECUTABLE = ROOT / "target/debug/fritz"


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = f"http://127.0.0.1:{server.server_address[1]}/v1"
    with tempfile.TemporaryDirectory(prefix="fritz-test-") as directory:
        env = dict(os.environ, FRITZ_DATA_DIR=directory)

        def cli(*args, success=True):
            result = subprocess.run([str(EXECUTABLE), *args], text=True, capture_output=True, env=env, timeout=15)
            assert (result.returncode == 0) == success, result.stderr
            return result

        registry = json.loads(cli("providers").stdout)
        assert registry["connections"] == []
        # The built-in catalog is offline; listing and chat never install weights.
        local_models = json.loads(cli("local-models", "list").stdout)["models"]
        assert len(local_models) > 1 and not any(model["installed"] for model in local_models)
        assert not (Path(directory) / "Models").exists()
        assert "Unknown Fritz local model" in cli("local-models", "install", "../../outside", success=False).stderr
        native_id = local_models[-1]["id"]
        cli("add-provider", "--name", "Fritz", "--provider", "fritz", "--model", native_id)
        assert json.loads(cli("models", "--connection", "Fritz").stdout) == []
        assert "not installed" in cli("chat", "Hi", "--connection", "Fritz", success=False).stderr
        assert "Chat mode only" in cli("chat", "Hi", "--connection", "Fritz", "--project", directory, success=False).stderr
        assert not (Path(directory) / "Models").exists()
        assert "does not use an endpoint" in cli("add-provider", "--name", "Invalid", "--provider", "fritz", "--base-url", endpoint, success=False).stderr
        cli("remove-provider", "Fritz")
        registry = json.loads(cli("add-provider", "--name", "Test", "--provider", "openai-compatible", "--base-url", endpoint, "--model", "fritz-test", "--default").stdout)
        connection = registry["connections"][0]
        assert registry["defaultConnectionId"] == connection["id"]
        assert len(json.loads(cli("models").stdout)) == 4
        assert len(json.loads(cli("models", "--connection", connection["id"].upper()).stdout)) == 4
        assert "Hello from Fritz" in cli("chat", "Hello").stdout
        assert "HTTP 401" in cli("chat", "Hello", "--model", "error-test", success=False).stderr
        assert "before the response finished" in cli("chat", "Hello", "--model", "disconnect-test", success=False).stderr
        assert "reasoning" not in Provider.requests[0]
        assert Provider.requests[0]["messages"][0]["role"] == "system"
        cli("add-provider", "--name", "Test", "--provider", "ollama", success=False)
        assert "apiKey" not in (Path(directory) / "providers.json").read_text()

        agent = subprocess.Popen([str(EXECUTABLE), "--agent"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        events = queue.Queue()
        threading.Thread(target=lambda: [events.put(json.loads(line)) for line in agent.stdout], daemon=True).start()

        def send(method, params=None):
            request_id = str(uuid.uuid4())
            agent.stdin.write(json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n")
            agent.stdin.flush()
            return request_id

        def receive():
            return events.get(timeout=10)

        health = send("health")
        event = receive()
        assert event["id"] == health and event["result"]["name"] == "fritz"
        local_list = send("localModels.list", {"modelId": native_id})
        event = receive()
        assert event["id"] == local_list and event["result"]["models"][0]["installed"] is False
        send("localModels.install", {"modelId": "unknown"})
        assert receive()["type"] == "error"
        chat = send("chat", {"connectionId": connection["id"].upper(), "model": "slow-test", "messages": [{"role": "user", "content": "Hello"}]})
        event = receive()
        assert event["id"] == chat and event["type"] == "delta"
        cancel = send("cancel", {"requestId": chat})
        terminal = [receive(), receive()]
        assert any(e["id"] == chat and e["type"] == "cancelled" for e in terminal)
        assert any(e["id"] == cancel and e["type"] == "result" for e in terminal)
        # A changed endpoint cannot reuse a saved connection's credentials.
        modified = dict(connection, baseUrl="http://localhost:1/v1")
        send("models.list", {"connection": modified})
        assert "Enter a key again" in receive()["message"]
        # The agent stays responsive after cancellation and request errors.
        send("unknown")
        assert receive()["type"] == "error"
        send("health")
        assert receive()["type"] == "result"
        agent.stdin.close()
        assert agent.wait(timeout=5) == 0
        cli("remove-provider", "Test")
        assert json.loads(cli("providers").stdout)["connections"] == []
        print("PASS: CLI, catalog, streaming, provider errors, interrupted stream, cancellation, credential routing, persistence, and agent shutdown")
    server.shutdown()


if __name__ == "__main__":
    main()
