#!/usr/bin/env python3
"""Build Fritz, exercise a synthetic chat through its UI, and capture the window."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent
PROMPT = "Help me plan a quiet Saturday. I'd like a walk by the water, a simple lunch, and time to read."
REPLY = """## A Saturday with room to breathe

**Morning · Walk by the water**
Head out after breakfast. Leave your headphones at home and take the longer way back if you feel like it.

**Lunch · Keep it simple**
Pick up fresh bread on the way home. Make tomato soup and toast, then leave the dishes for later.

**Afternoon · A book and no plans**
Find a comfortable spot, put your phone aside, and read for an hour. The rest of the day can stay open.

You only need to decide when to start the walk. Everything else can follow at your own pace."""
DRAFT = "Can you make a short shopping list for lunch?"


class ScreenshotProvider(BaseHTTPRequestHandler):
    """Keyless loopback fixture; this is example copy, not a model evaluation."""
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != "/v1/models":
            self.send_error(404)
            return
        data = json.dumps({"data": [{"id": "screenshot-example", "name": "Example model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path != "/v1/chat/completions" or payload.get("model") != "screenshot-example":
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            for offset in range(0, len(REPLY), 24):
                event = {"choices": [{"delta": {"content": REPLY[offset:offset + 24]}}]}
                self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.025)
            self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def wait_for(description, predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {description}.")


def applescript(pid, body, *args):
    # All UI operations target this launch's verified PID, never an app name.
    source = f'''on run argv
        tell application "System Events"
            tell first application process whose unix id is {pid}
                {body}
            end tell
        end tell
    end run'''
    return run("osascript", "-", *args, input=source, text=True, capture_output=True).stdout.strip()


def enter_message(pid, text):
    wait_for("the Message field", lambda: applescript(pid, '''set frontmost to true
    delay 0.2
    set allElements to get entire contents of window 1
    repeat with field in allElements
        try
            if role of field is "AXTextField" and description of field is "Message" then
                set value of attribute "AXFocused" of field to true
                keystroke "a" using command down
                keystroke (item 1 of argv)
                return "entered"
            end if
        end try
    end repeat
    return "waiting"''', text) == "entered")


def seed_workspace(database, appearance):
    """Seed only the fresh database after the real app has created its schema."""
    selected = None
    with sqlite3.connect(database) as db:
        if db.execute("SELECT count(*) FROM projects").fetchone()[0]:
            raise RuntimeError("Capture database is not empty.")
        for position, (name, titles) in enumerate([
            ("Everyday", ["A quiet Saturday", "Ideas for dinner", "Vet questions"]),
            ("Writing", ["A note to a friend"]),
        ]):
            project_id = str(uuid.uuid4()).upper()
            project = {"id": project_id, "name": name, "threads": []}
            # No attached folder: this example exercises plain chat.
            db.execute("INSERT INTO projects VALUES (?, ?, ?)", (project_id, position, json.dumps(project)))
            for index, title in enumerate(titles):
                thread_id = str(uuid.uuid4()).upper()
                thread = {"id": thread_id, "title": title, "createdAt": 0, "titleIsAutomatic": False}
                db.execute("INSERT INTO threads VALUES (?, ?, ?, ?)",
                           (thread_id, project_id, index, json.dumps(thread)))
                if selected is None:
                    selected = thread_id
        db.execute("UPDATE workspace SET selected_thread_id = ?", (selected,))
        db.execute("INSERT INTO settings VALUES ('appearance', ?) ON CONFLICT(key) DO UPDATE SET payload = excluded.payload",
                   (json.dumps(appearance),))
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Use this checkout's existing staged Release app")
    parser.add_argument("--width", type=int, default=1120, help="Window width in points (default: 1120)")
    parser.add_argument("--height", type=int, default=740, help="Window height in points (default: 740)")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Capture requires macOS, a logged-in desktop, Accessibility and Screen Recording access.")
    if args.width < 900 or args.height < 620:
        parser.error("Fritz requires a window of at least 900 × 620 points.")
    app = ROOT / "dist/Fritz.app"
    scratch = ROOT / "dist/website-capture"
    scratch.mkdir(parents=True, exist_ok=True)
    helper = scratch / "capture-window"
    run("python3", ROOT / "scripts/build-cache.py", "xcrun", "swiftc", "-parse-as-library",
        ROOT / "scripts/website/capture-window.swift", "-o", helper)

    def app_pid():
        return int(run(helper, "pid", app, capture_output=True, text=True).stdout.strip())

    if app_pid():
        raise RuntimeError("This checkout's Release app is already running. Quit it before capturing.")
    if not args.skip_build:
        run("make", "build", cwd=ROOT, env={**os.environ, "CONFIGURATION": "release"})
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if "FritzDataDirectory" in info or info["CFBundleIdentifier"] != "dev.fritz.app":
        raise RuntimeError("Capture requires the staged Release app so FRITZ_DATA_DIR is honored.")
    server = ThreadingHTTPServer(("127.0.0.1", 0), ScreenshotProvider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    pid = 0
    temporary = tempfile.TemporaryDirectory(prefix="data-", dir=scratch)
    directory = temporary.name
    try:
        data = Path(directory)
        database = data / "workspace.sqlite"
        env = {**os.environ, "FRITZ_DATA_DIR": directory, "FRITZ_MODELS_DIR": str(data / "Models")}
        run(app / "Contents/Resources/fritz", "add-provider", "--name", "Screenshot example",
            "--provider", "openai-compatible", "--base-url", f"http://127.0.0.1:{server.server_port}/v1",
            "--model", "screenshot-example", "--default", env=env, capture_output=True)

        def launch():
            nonlocal pid
            run("open", "-n", "--env", f"FRITZ_DATA_DIR={directory}",
                "--env", f"FRITZ_MODELS_DIR={data / 'Models'}", app)
            pid = wait_for("the staged Fritz process", app_pid)
            print("Opened the staged Fritz app.", flush=True)
            wait_for("the chat window", lambda: applescript(pid, "return count of windows") != "0")

        def quit_app():
            nonlocal pid
            run(helper, "quit", app)
            wait_for("Fritz shutdown", lambda: app_pid() == 0)
            pid = 0

        launch()
        wait_for("workspace schema", lambda: database.exists())
        quit_app()
        thread_id = seed_workspace(database, "light")
        for appearance in ("light", "dark"):
            with sqlite3.connect(database) as db:
                db.execute("UPDATE settings SET payload = ? WHERE key = 'appearance'", (json.dumps(appearance),))
            launch()
            applescript(pid, f'''set frontmost to true
                set position of window 1 to {{40, 60}}
                set size of window 1 to {{{args.width}, {args.height}}}
                return size of window 1''')
            # Find the real composer through Accessibility; Return invokes its normal send action.
            if appearance == "light":
                enter_message(pid, PROMPT)
                print("Entered the example prompt.", flush=True)

                def send_prompt():
                    with sqlite3.connect(database) as db:
                        if db.execute("SELECT count(*) FROM messages WHERE thread_id = ?", (thread_id,)).fetchone()[0]:
                            return True
                    applescript(pid, '''set frontmost to true
                        delay 0.2
                        set allElements to get entire contents of window 1
                        repeat with field in allElements
                            try
                                if role of field is "AXTextField" and description of field is "Message" then
                                    set value of attribute "AXFocused" of field to true
                                    key code 36
                                    exit repeat
                                end if
                            end try
                        end repeat''')
                    return False

                wait_for("the submitted prompt to be persisted", send_prompt)
                print("Sent the example prompt.", flush=True)

            def completed():
                with sqlite3.connect(database) as db:
                    messages = [json.loads(row[0]) for row in db.execute(
                        "SELECT payload FROM messages WHERE thread_id = ? ORDER BY position", (thread_id,))]
                return len(messages) == 2 and messages[-1].get("isComplete") and messages[-1]["content"] == REPLY

            wait_for("the completed, persisted example reply", completed)
            enter_message(pid, DRAFT)
            # Move keyboard focus out of the composer to avoid a blinking caret.
            applescript(pid, 'key code 48')
            time.sleep(1)  # Native Markdown and window materials finish rendering.
            size = applescript(pid, "return size of window 1")
            if size != f"{args.width}, {args.height}":
                raise RuntimeError(f"Window was clamped to {size}; use a larger display or smaller --width/--height.")
            run(helper, "capture", app, ROOT / f"website/public/fritz-{appearance}.png")
            quit_app()
    finally:
        if pid and app_pid() == pid:
            run(helper, "quit", app)
            wait_for("Fritz cleanup", lambda: app_pid() == 0)
        server.shutdown()
        server.server_close()
        temporary.cleanup()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, sqlite3.Error, subprocess.CalledProcessError) as error:
        print(f"Capture failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        sys.exit(1)
