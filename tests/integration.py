"""Exercise the real Fritz executable with no personal credentials or remote requests."""
import json
import sqlite3
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import uuid
from http.server import ThreadingHTTPServer
import urllib.request
import urllib.error
from mock_provider import Provider

ROOT = Path(__file__).resolve().parents[1]
EXECUTABLE = Path(os.environ.get("FRITZ_TEST_BIN_DIR", ROOT / "target/debug")) / "fritz"


class AuthenticatedProvider(Provider):
    """Require the imported fixture key on a separate discovery endpoint."""

    def do_GET(self):
        if self.path == "/authenticated/v1/models":
            if self.headers.get("Authorization") != "Bearer synthetic-import-key":
                self.send_error(401)
                return
            self.path = "/v1/models"
        super().do_GET()


def managed_local_api():
    """Test real listener ownership and private-pipe model admission, without weights."""
    with tempfile.TemporaryDirectory(prefix="fritz-api-test-") as directory:
        models = Path(directory) / "Models"
        env = dict(os.environ, FRITZ_DATA_DIR=directory, FRITZ_MODELS_DIR=str(models))
        process = subprocess.Popen([str(EXECUTABLE), "local-models", "serve", "--port", "0", "--managed"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=env)
        events = queue.Queue()
        threading.Thread(target=lambda: [events.put(json.loads(line)) for line in process.stdout], daemon=True).start()

        def receive():
            return events.get(timeout=15)

        def control(action, model):
            process.stdin.write(json.dumps({"action": action, "modelId": model}) + "\n")
            process.stdin.flush()

        def request(path, payload=None):
            data = None if payload is None else json.dumps(payload).encode()
            req = urllib.request.Request(address + path, data=data, headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=15) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)

        replies = queue.Queue()

        def infer():
            try:
                replies.put(request("/api/generate", {"model": model, "prompt": "Fixture", "stream": False}))
            except Exception as error:
                replies.put(error)

        try:
            started = receive()
            assert started["type"] == "service"
            address = started["address"]
            assert address.startswith("http://127.0.0.1:")
            assert request("/api/tags") == (200, {"models": []})
            assert not models.exists(), "Starting a listener must not install a model"
            model = "qwen3-0.6b-q4_k_m"
            assert request("/api/generate", {"model": model, "prompt": "Fixture"})[0] == 404
            models.mkdir()
            (models / "qwen3-0.6b-q4_k_m.gguf").write_bytes(b"invalid GGUF lifecycle fixture")
            assert [item["model"] for item in request("/api/tags")[1]["models"]] == [model]

            threading.Thread(target=infer, daemon=True).start()
            assert receive() == {"type": "loadRequested", "modelId": model}
            assert replies.empty(), "Inference must wait for app admission"
            control("deny", model)
            status, body = replies.get(timeout=15)
            assert status == 503 and "cancelled" in body["error"]

            threading.Thread(target=infer, daemon=True).start()
            assert receive() == {"type": "loadRequested", "modelId": model}
            control("start", model)
            assert receive()["status"] == "starting"
            failed = receive()
            assert failed["status"] == "failed" and "Could not load the installed GGUF" in failed["error"]
            status, body = replies.get(timeout=15)
            assert status == 503 and "Could not load" in body["error"]
            # Start actually invokes the loader; file presence alone is not Running.
            control("stop", model)
            assert receive() == {"type": "model", "modelId": model, "status": "stopped"}
            assert request("/api/tags")[0] == 200, "Stopping weights must leave the listener running"

            threading.Thread(target=infer, daemon=True).start()
            assert receive()["type"] == "loadRequested"
            control("stop", model)
            assert receive()["status"] == "stopped"
            assert isinstance(replies.get(timeout=15), Exception), "Stop must cancel the model's active request"
            assert request("/api/tags")[0] == 200

            threading.Thread(target=infer, daemon=True).start()
            assert receive()["type"] == "loadRequested"
            process.stdin.close()
            assert process.wait(timeout=5) == 0, process.stderr.read()
            assert isinstance(replies.get(timeout=15), Exception), "Owner exit must close pending API requests"
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        # Quit's SIGTERM path also releases the listener without needing a command.
        process = subprocess.Popen([str(EXECUTABLE), "local-models", "serve", "--port", "0", "--managed"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=env)
        try:
            assert json.loads(process.stdout.readline())["type"] == "service"
            process.terminate()
            assert process.wait(timeout=5) == 0, process.stderr.read()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
        print("PASS: empty local API, private model admission/cancellation, loader failure, stop, EOF and SIGTERM shutdown")


def provider_migration(endpoint):
    """Copy only referenced synthetic keys, commit once, and survive process restart."""
    with tempfile.TemporaryDirectory(prefix="fritz-migration-") as directory:
        root = Path(directory)
        source_service = f"dev.fritz.provider-credentials.test-{uuid.uuid4()}"
        target_service = f"dev.fritz.provider-credentials.test-{uuid.uuid4()}"
        source_env = dict(os.environ, FRITZ_DATA_DIR=str(root / "source"), FRITZ_KEYCHAIN_SERVICE=source_service)
        target_env = dict(os.environ, FRITZ_DATA_DIR=str(root / "target"), FRITZ_KEYCHAIN_SERVICE=target_service)

        def cli(env, *args, input=None):
            result = subprocess.run([str(EXECUTABLE), *args], input=input, env=env,
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout) if result.stdout.strip() else None

        source = cli(source_env, "add-provider", "--name", "Migrated", "--provider", "openai-compatible",
                     "--base-url", endpoint.replace("/v1", "/authenticated/v1"), "--model", "fritz-test",
                     "--api-key-stdin", input="synthetic-import-key")["connections"][0]
        duplicate = dict(source, id=str(uuid.uuid4()), name="Same endpoint", modelId="slow-test")
        other = dict(source, id=str(uuid.uuid4()), name="Other", baseUrl=endpoint)
        request = dict(migrationId="fixture-v1", defaultConnectionId=duplicate["id"], providers=[
            dict(connection=source, credentialSource=dict(service=source_service, account=source["id"])),
            dict(connection=duplicate), dict(connection=other)])

        def migrate(payload, method="providers.migrate"):
            result = subprocess.run([str(EXECUTABLE), "--agent"], env=target_env, text=True,
                                    input=json.dumps(dict(id="migration", method=method, params=payload)) + "\n",
                                    capture_output=True, timeout=15)
            assert result.returncode == 0, result.stderr
            events = [json.loads(line) for line in result.stdout.splitlines()]
            assert len(events) == 1 and "synthetic-import-key" not in result.stdout
            return events[0]

        try:
            status = dict(migrationId=request["migrationId"])
            assert migrate(status, "providers.migrationStatus")["result"]["migration"] is None
            invalid = dict(request, providers=request["providers"] + [dict(connection=dict(other, id=str(uuid.uuid4()), baseUrl="invalid"))])
            assert migrate(invalid)["type"] == "error"
            assert cli(target_env, "providers")["connections"] == []
            with sqlite3.connect(root / "target/providers.sqlite") as database:
                assert database.execute("SELECT COUNT(*) FROM provider_migrations").fetchone()[0] == 0
            event = migrate(request)
            assert event["type"] == "result", event
            mapping = event["result"]["connectionIds"]
            assert migrate(status, "providers.migrationStatus")["result"]["migration"] == event["result"]
            assert mapping[source["id"]] == source["id"] == mapping[duplicate["id"]]
            assert len(cli(target_env, "providers")["connections"]) == 2
            assert cli(target_env, "providers")["defaultConnectionId"] == source["id"]
            assert cli(target_env, "providers")["connections"][0]["modelId"] == duplicate["modelId"]
            # A new process authenticates using the destination namespace, and the
            # source still authenticates independently after copying.
            assert len(cli(target_env, "models", "--connection", source["id"])) == 4
            assert len(cli(source_env, "models", "--connection", source["id"])) == 4
            cli(target_env, "default-provider", other["id"])
            assert migrate(request)["result"] == event["result"]
            assert cli(target_env, "providers")["defaultConnectionId"] == other["id"]
            with sqlite3.connect(root / "target/providers.sqlite") as database:
                assert database.execute("SELECT COUNT(*) FROM provider_migrations").fetchone()[0] == 1
                for table in ["providers", "provider_migrations"]:
                    assert all("synthetic-import-key" not in row[0] for row in database.execute(f"SELECT payload FROM {table}"))
        finally:
            for env in [source_env, target_env]:
                for item in cli(env, "providers")["connections"]:
                    cli(env, "remove-provider", item["id"])
    print("PASS: atomic provider migration, Rust credential copying, deduplication, default, restart and one-time completion")


def main():
    managed_local_api()
    server = ThreadingHTTPServer(("127.0.0.1", 0), AuthenticatedProvider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = f"http://127.0.0.1:{server.server_address[1]}/v1"
    provider_migration(endpoint)
    with tempfile.TemporaryDirectory(prefix="fritz-test-") as directory:
        keychain_service = f"dev.fritz.provider-credentials.test-{uuid.uuid4()}"
        env = dict(os.environ, FRITZ_DATA_DIR=directory, FRITZ_MODELS_DIR=str(Path(directory) / "Models"), FRITZ_KEYCHAIN_SERVICE=keychain_service)

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
        assert "already exists" in cli("add-provider", "--name", "Same local model", "--provider", "fritz", "--model", native_id, success=False).stderr
        other_native_id = local_models[-2]["id"]
        cli("add-provider", "--name", "Other local model", "--provider", "fritz", "--model", other_native_id)
        cli("remove-provider", "Other local model")
        assert json.loads(cli("models", "--connection", "Fritz").stdout) == []
        assert "not installed" in cli("chat", "Hi", "--connection", "Fritz", success=False).stderr
        assert "not installed" in cli("chat", "Hi", "--connection", "Fritz", "--project", directory, success=False).stderr
        assert not (Path(directory) / "Models").exists()
        assert "does not use an endpoint" in cli("add-provider", "--name", "Invalid", "--provider", "fritz", "--base-url", endpoint, success=False).stderr
        cli("remove-provider", "Fritz")
        registry = json.loads(cli("add-provider", "--name", "Test", "--provider", "openai-compatible", "--base-url", endpoint, "--model", "fritz-test", "--default").stdout)
        assert "already exists" in cli("add-provider", "--name", "Same endpoint", "--provider", "openai-compatible", "--base-url", endpoint + "/", "--model", "other", success=False).stderr
        cli("add-provider", "--name", "Other endpoint", "--provider", "openai-compatible", "--base-url", endpoint + "/other")
        cli("remove-provider", "Other endpoint")
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
        with sqlite3.connect(Path(directory) / "providers.sqlite") as database:
            assert all("apiKey" not in row[0] for row in database.execute("SELECT payload FROM providers"))
        assert not (Path(directory) / "providers.json").exists()

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
        # Imported configurations may omit keys, but malformed batches write nothing.
        imported = dict(id=str(uuid.uuid4()), name="TypeSafe", provider="jev", modelId="jev-latest")
        invalid = dict(imported, id=str(uuid.uuid4()), baseUrl="https://example.com")
        send("providers.import", {"providers": [{"connection": imported}, {"connection": invalid}]})
        assert receive()["type"] == "error"
        send("providers.list")
        assert len(receive()["result"]["connections"]) == 1
        send("providers.import", {"providers": [{"connection": imported}]})
        registry = receive()["result"]
        assert len(registry["connections"]) == 2
        assert registry["defaultConnectionId"] == connection["id"]
        send("models.list", {"connectionId": imported["id"]})
        assert "Add an API key" in receive()["message"]
        send("providers.default", {"id": imported["id"]})
        assert receive()["type"] == "error"
        send("providers.remove", {"id": imported["id"]})
        assert len(receive()["result"]["connections"]) == 1
        # Import keys stay in Keychain, survive keyless overwrites, and cannot be
        # carried to a changed endpoint by passing a whitespace-only replacement.
        keyed = dict(connection, id=str(uuid.uuid4()), name="Import credential fixture",
                     baseUrl=endpoint.replace("/v1", "/authenticated/v1"))
        # Prove the fixture rejects a missing credential before testing preservation.
        send("models.list", {"connection": keyed})
        assert "HTTP 401" in receive()["message"]
        try:
            send("providers.import", {"providers": [{"connection": keyed, "apiKey": "synthetic-import-key"}]})
            event = receive()
            assert "synthetic-import-key" not in json.dumps(event)
            assert event["type"] == "result", event
            send("providers.import", {"providers": [{"connection": dict(keyed, modelId="other")}]})
            assert receive()["type"] == "result"
            # A fresh CLI process must retrieve the persisted key and authenticate.
            assert len(json.loads(cli("models", "--connection", keyed["id"]).stdout)) == 4
            send("providers.import", {"providers": [{"connection": dict(keyed, baseUrl="http://localhost:1/v1"), "apiKey": "  "}]})
            assert "Enter a key again" in receive()["message"]
            with sqlite3.connect(Path(directory) / "providers.sqlite") as database:
                assert all("synthetic-import-key" not in row[0] for row in database.execute("SELECT payload FROM providers"))
        finally:
            # Also clean up when a credential assertion fails.
            saved = json.loads(cli("providers").stdout)["connections"]
            if any(item["id"] == keyed["id"] for item in saved):
                cli("remove-provider", keyed["id"])
        assert len(json.loads(cli("providers").stdout)["connections"]) == 1
        local_list = send("localModels.list", {"modelId": native_id})
        event = receive()
        assert event["id"] == local_list and event["result"]["models"][0]["installed"] is False
        send("localModels.install", {"modelId": "unknown"})
        assert receive()["type"] == "error"
        chat = send("chat", {"connectionId": connection["id"].upper(), "model": "slow-test", "messages": [{"role": "user", "content": "Hello"}]})
        event = receive()
        while event["type"] == "activity":
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
