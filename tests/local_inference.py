"""Opt-in native inference check using a model already installed in an isolated data directory."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--executable", type=Path, default=Path("dist/Fritz.app/Contents/Resources/fritz"))
    args = parser.parse_args()
    env = dict(os.environ, FRITZ_DATA_DIR=str(args.data_dir.resolve()))
    registry = json.loads(subprocess.check_output([str(args.executable.resolve()), "providers"], env=env, text=True))
    connection = next(c for c in registry["connections"] if c["provider"] == "fritz" and c["modelId"])
    params = {"connectionId": connection["id"], "model": connection["modelId"]}
    with tempfile.TemporaryFile(mode="w+") as errors:
        agent = subprocess.Popen([str(args.executable.resolve()), "--agent"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=errors, text=True, env=env)
        events = queue.Queue()

        def read():
            for line in agent.stdout:
                events.put(json.loads(line))

        threading.Thread(target=read, daemon=True).start()

        def send(method, params=None):
            request_id = str(uuid.uuid4())
            agent.stdin.write(json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n")
            agent.stdin.flush()
            return request_id

        def chat(prompt):
            return send("chat", dict(params, messages=[{"role": "user", "content": prompt}]))

        def first_delta(request_id):
            while True:
                event = events.get(timeout=120)
                assert event["id"] == request_id, event
                assert event["type"] not in ("error", "result", "cancelled"), event
                if event["type"] == "delta":
                    assert event["text"]
                    return

        try:
            request_id = chat("Reply with exactly: Fritz is ready.")
            first_delta(request_id)
            while True:
                event = events.get(timeout=120)
                assert event["id"] == request_id and event["type"] != "error", event
                if event["type"] == "result":
                    break
            request_id = chat("List every integer from 1 to 500, separated by commas.")
            first_delta(request_id)
            cancel = send("cancel", {"requestId": request_id})
            cancelled = acknowledged = False
            while not (cancelled and acknowledged):
                event = events.get(timeout=15)
                cancelled |= event["id"] == request_id and event["type"] == "cancelled"
                acknowledged |= event["id"] == cancel and event["type"] == "result"
                assert event["type"] != "error", event
            health = send("health")
            event = events.get(timeout=15)
            assert event["id"] == health and event["type"] == "result", event
            # EOF during a live request must stop the worker and release Metal weights.
            first_delta(chat("List every integer from 1 to 500, separated by commas."))
            agent.stdin.close()
            code = agent.wait(timeout=30)
            errors.seek(0)
            assert code == 0, errors.read()
            print("PASS: native streaming, cancellation, health after cancellation, and clean Metal shutdown on EOF")
        finally:
            if agent.poll() is None:
                agent.kill()
                agent.wait()


if __name__ == "__main__":
    main()
