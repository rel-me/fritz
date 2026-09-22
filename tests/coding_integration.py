"""Run real harness binaries against all five provider wire protocols, without keys."""
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import ThreadingHTTPServer
from coding_provider import CodingProvider

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("FRITZ_TEST_BIN_DIR", ROOT / "target/debug"))


class Process:
    def __init__(self, args, env):
        self.child = subprocess.Popen([str(BIN / args[0]), *args[1:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.events = queue.Queue()
        def read():
            for line in self.child.stdout:
                self.events.put(json.loads(line))
            self.events.put(None)
        threading.Thread(target=read, daemon=True).start()

    def send(self, value):
        self.child.stdin.write(json.dumps(value) + "\n")
        self.child.stdin.flush()

    def receive(self):
        event = self.events.get(timeout=15)
        assert event is not None, self.child.stderr.read()
        return event

    def finish(self):
        if not self.child.stdin.closed:
            self.child.stdin.close()
        assert self.child.wait(timeout=5) == 0, self.child.stderr.read()


def wait_file(path):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if path.exists() and path.read_text().strip():
            return int(path.read_text())
        time.sleep(0.025)
    raise AssertionError(f"Command never started: {path}")


def assert_gone(pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.025)
    raise AssertionError(f"Command process {pid} survived cancellation")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), CodingProvider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}"
    with tempfile.TemporaryDirectory(prefix="fritz-code-") as directory:
        root = Path(directory)
        project = root / "project"
        project.mkdir()
        (project / "AGENTS.md").write_text("Preserve unrelated files.\n")
        env = dict(os.environ, FRITZ_DATA_DIR=str(root / "data"))
        connection_id = str(uuid.uuid4())
        def request(kind="openai-compatible", model="coding-test", **overrides):
            return {"connectionId": connection_id, "model": model, "messages": [{"role": "user", "content": "Change before to after in hello.txt and verify it."}], "mode": "code", "projectPath": str(project), **overrides}
        def config(kind="openai-compatible", model="coding-test", **overrides):
            return {"request": request(kind, model, **overrides), "connection": {"id": connection_id, "name": "Mock", "provider": kind, "baseUrl": url if kind == "ollama" else url + "/v1", "modelId": model}, "apiKey": None}
        def run(config):
            p = Process(["fritz-harness", "chat"], env)
            p.send(config)
            events = []
            while True:
                event = p.receive()
                events.append(event)
                if event["type"] in ("result", "error", "cancelled"):
                    break
            p.finish()
            return events
        for kind in ["openai-compatible", "openrouter", "openai", "anthropic", "gemini", "ollama"]:
            (project / "hello.txt").write_text("before\n")
            events = run(config(kind))
            assert events[-1]["type"] == "result", (kind, events)
            assert (project / "hello.txt").read_text() == "after\n", kind
            assert len([e for e in events if e["type"] == "tool_start"]) == 3, kind
            assert all(e["success"] for e in events if e["type"] == "tool_end"), kind
            assert "verified" in "".join(e.get("text", "") for e in events), kind
            print(f"PASS: {kind} read → edit → command → answer")
        for model, last_type in [("invalid-tool", "result"), ("unsafe-path", "result"), ("partial-tool", "error"), ("loop-test", "error")]:
            (project / "hello.txt").write_text("before\n")
            events = run(config(model=model, maxTurns=3))
            assert events[-1]["type"] == last_type, events
            assert not (root / "outside.txt").exists()
            if model == "partial-tool":
                assert not any(e["type"] == "tool_start" for e in events)
            if model == "loop-test":
                assert len([e for e in events if e["type"] == "tool_start"]) == 2
        events = run(config(mode="chat"))
        assert events[-1]["type"] == "result" and not any(e["type"].startswith("tool_") for e in events)
        events = run(config(projectPath=str(root / "missing")))
        assert events[-1]["type"] == "error"
        # A direct harness must stop the command and descendants on private-stdin EOF.
        for termination in ("eof", "sigterm"):
            p = Process(["fritz-harness", "chat"], env)
            p.send(config(model="cancel-command"))
            shell = wait_file(project / "running.pid")
            descendant = wait_file(project / "descendant.pid")
            if termination == "sigterm":
                p.child.terminate()
            else:
                p.child.stdin.close()
            p.finish()
            assert_gone(shell)
            assert_gone(descendant)
            (project / "running.pid").unlink()
            (project / "descendant.pid").unlink()
        # Service/CLI launches exercise the packaged sibling lookup and private credential handoff.
        data = root / "data"
        data.mkdir(exist_ok=True)
        (data / "providers.json").write_text(json.dumps({"version": 1, "connections": [config()["connection"]], "defaultConnectionId": connection_id}))
        (project / "hello.txt").write_text("before\n")
        cli = subprocess.run([str(BIN / "fritz"), "chat", "Fix hello.txt", "--project", str(project)], capture_output=True, text=True, env=env, timeout=15)
        assert cli.returncode == 0 and "verified" in cli.stdout, cli.stderr
        for termination in ("cancel", "eof", "sigterm"):
            service = Process(["fritz", "--agent"], env)
            service.send({"id": "run", "method": "chat", "params": request(model="cancel-command")})
            shell = wait_file(project / "running.pid")
            descendant = wait_file(project / "descendant.pid")
            if termination == "cancel":
                service.send({"id": "stop", "method": "cancel", "params": {"requestId": "run"}})
                while True:
                    event = service.receive()
                    if event["id"] == "stop":
                        assert event["type"] == "result"
                        break
                service.send({"id": "health", "method": "health"})
                assert service.receive()["id"] == "health"
            if termination == "sigterm":
                service.child.terminate()
                assert service.child.wait(timeout=5) == -signal.SIGTERM
                service.child.stdin.close()
            else:
                service.finish()
            assert_gone(shell)
            assert_gone(descendant)
            (project / "running.pid").unlink()
            (project / "descendant.pid").unlink()
        print("PASS: recovery, path rejection, incomplete tools, turn limit, chat isolation, EOF, SIGTERM, service Stop, descendant cleanup, and CLI")
    server.shutdown()


if __name__ == "__main__":
    main()
