#!/usr/bin/env python3
"""Opt-in live tool evaluations through Fritz's staged private harness protocol."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shlex
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CORPUS = Path(__file__).with_name("tool_cases.json")
TOOLS = {"list_files", "read_file", "create_file", "edit_file", "run_command"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_key(path):
    """Parse a literal assignment without sourcing or executing the keys file."""
    values = []
    for line in path.expanduser().read_text().splitlines():
        match = re.match(r"^\s*(?:export\s+)?OPENAI_API_KEY\s*=\s*(.*)$", line)
        if match:
            words = shlex.split(match[1], comments=True)
            if len(words) != 1 or not words[0] or any(c in words[0] for c in "`$\n\r"):
                raise ValueError("OPENAI_API_KEY must be a nonempty literal assignment")
            values.append(words[0])
    if len(values) != 1:
        raise ValueError("Expected exactly one OPENAI_API_KEY assignment in the key file")
    return values[0]


def load_cases(path):
    corpus = json.loads(path.read_text())
    if corpus["version"] != 2 or not corpus["cases"]:
        raise ValueError("Unsupported or empty corpus")
    ids = set()
    for case in corpus["cases"]:
        if not re.fullmatch(r"[a-z0-9-]+", case["id"]) or case["id"] in ids:
            raise ValueError("Case IDs must be unique lowercase names")
        ids.add(case["id"])
        for field in ("files", "expected_files", "expected_json_files"):
            for name in case.get(field, {}):
                p = Path(name)
                if p.is_absolute() or ".." in p.parts or not p.parts:
                    raise ValueError("Fixture paths must be relative and within the project")
        for field in ("required_tools", "allowed_tools"):
            if not set(case.get(field, [])) <= TOOLS:
                raise ValueError("Unknown tool in corpus")
    return corpus


def run_harness(binary, envelope, env, deadline):
    """Keep private stdin open; EOF cancels only this owned harness and its tools."""
    events = []
    messages = queue.Queue()
    started = time.monotonic()
    status = None
    try:
        child = subprocess.Popen([str(binary), "chat"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 text=True, env=env)
    except OSError:
        return {"status": "runner_error", "events": [], "exit_code": None,
                "latency_seconds": round(time.monotonic() - started, 3)}

    def read():
        try:
            for line in child.stdout:
                try:
                    event = json.loads(line)
                    if not isinstance(event, dict) or not isinstance(event.get("type"), str):
                        raise ValueError("Invalid event shape")
                    messages.put(event)
                except ValueError:
                    messages.put({"type": "runner_error", "message": "Invalid harness JSON"})
                    break
        finally:
            messages.put(None)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        child.stdin.write(json.dumps(envelope) + "\n")
        child.stdin.flush()
        while True:
            remaining = deadline - (time.monotonic() - started)
            if remaining <= 0:
                status = "timeout"
                break
            try:
                event = messages.get(timeout=remaining)
            except queue.Empty:
                status = "timeout"
                break
            if event is None:
                status = "runner_error"
                break
            events.append(event)
            if event.get("type") in ("result", "error", "cancelled", "runner_error"):
                status = event["type"]
                break
    except KeyboardInterrupt:
        status = "cancelled"
    except (OSError, ValueError):
        status = "runner_error"
    finally:
        try:
            child.stdin.close()
        except OSError:
            pass
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        reader.join(timeout=2)
        child.stdout.close()
    # Preserve usage and partial activity produced while cancellation was draining.
    while not messages.empty():
        event = messages.get_nowait()
        if event is not None:
            events.append(event)
    if status == "result" and child.returncode != 0:
        status = "runner_error"
    return {"status": status, "events": events, "exit_code": child.returncode,
            "latency_seconds": round(time.monotonic() - started, 3)}


def parse_json(text):
    text = text.strip()
    if text.startswith("```json\n") and text.endswith("```"):
        text = text[8:-3]
    elif text.startswith("```\n") and text.endswith("```"):
        text = text[4:-3]
    return json.loads(text)


def calls_and_answer(events):
    calls, pending = [], {}
    answer = ""
    protocol_errors = []
    for event in events:
        kind = event.get("type")
        if kind == "activity" and event.get("message", "").startswith("Thinking · step "):
            answer = ""
        elif kind == "delta":
            answer += event.get("text", "")
        elif kind == "tool_start":
            call = {"name": event["name"], "success": None, "result": ""}
            try:
                call["args"] = json.loads(event["details"])
            except (ValueError, KeyError):
                call["args"] = {}
            if event["toolCallId"] in pending:
                protocol_errors.append("duplicate tool call ID")
            pending[event["toolCallId"]] = call
            calls.append(call)
        elif kind == "tool_end":
            call = pending.pop(event["toolCallId"], None)
            if call is None or call["name"] != event["name"]:
                protocol_errors.append("tool result without matching start")
            else:
                call.update(success=event["success"], result=event.get("details", ""))
    if pending:
        protocol_errors.append("unfinished tool calls")
    return calls, answer.strip(), protocol_errors


def matches(call, expected):
    return (call["name"] == expected["name"]
            and call["success"] == expected.get("success", True)
            and all(call["args"].get(k) == v for k, v in expected.get("args", {}).items())
            and expected.get("result_contains", "") in call["result"])


def grade(case, project, run):
    """Independent outcomes plus explicit tool coverage; never trust success prose."""
    checks = []

    def check(name, passed, rationale):
        checks.append({"check": name, "passed": bool(passed), "rationale": rationale})

    check("terminal", run["status"] == "result", f"Harness outcome: {run['status']}")
    calls, answer, protocol_errors = calls_and_answer(run["events"])
    check("tool_protocol", not protocol_errors, "; ".join(protocol_errors) or "All tool starts have matching results")
    expected_files = {**case["files"], **case.get("expected_files", {})}
    expected_json = case.get("expected_json_files", {})
    expected_names = set(expected_files) | set(expected_json)
    paths = list(project.rglob("*"))
    actual_names = {p.relative_to(project).as_posix() for p in paths if not p.is_dir() or p.is_symlink()}
    expected_dirs = {parent.as_posix() for name in expected_names for parent in Path(name).parents if parent != Path('.')}
    actual_dirs = {p.relative_to(project).as_posix() for p in paths if p.is_dir() and not p.is_symlink()}
    check("file_inventory", actual_names == expected_names and actual_dirs == expected_dirs,
          f"Missing: {sorted(expected_names - actual_names)}; unexpected: {sorted(actual_names - expected_names)}; directory inventory matches: {actual_dirs == expected_dirs}")
    hashes = {}
    for name in sorted(expected_names | actual_names):
        path = project / name
        if path.is_symlink() or not path.is_file():
            check(f"file:{name}", False, "Missing, nonregular, or symlink file")
            continue
        hashes[name] = digest(path)
        try:
            content = path.read_text()
            passed = json.loads(content) == expected_json[name] if name in expected_json else content == expected_files.get(name)
        except (ValueError, UnicodeError):
            passed = False
        check(f"file:{name}", passed, "Matches independent expected content" if passed else "Content differs from expected outcome")
    if "answer_json" in case:
        try:
            correct = parse_json(answer) == case["answer_json"]
        except ValueError:
            correct = False
        check("answer", correct, "Final answer must equal the specified facts as JSON")
    else:
        check("answer_present", bool(answer), "A final response must follow tool execution; prose quality is not scored")
    successful = {c["name"] for c in calls if c["success"] is True}
    missing = set(case["required_tools"]) - successful
    check("tool_coverage", not missing, f"Missing successful tools: {sorted(missing)}")
    unexpected = {c["name"] for c in calls} - set(case.get("allowed_tools", TOOLS))
    check("permitted_tools", not unexpected, f"Unexpected tools: {sorted(unexpected)}")
    errors = sum(c["success"] is False for c in calls)
    expected_errors = case.get("expected_tool_errors", 0)
    check("tool_errors", errors == expected_errors, f"Expected {expected_errors}; observed {errors}")
    cursor = 0
    for index, expected in enumerate(case.get("trace", [])):
        found = next((i for i in range(cursor, len(calls)) if matches(calls[i], expected)), None)
        check(f"trace:{index + 1}", found is not None, f"Required ordered tool evidence: {expected}")
        cursor = len(calls) if found is None else found + 1
    usages = [e["usage"] for e in run["events"] if e.get("type") == "usage"]
    model_calls = sum(e.get("type") == "activity" and e.get("message", "").startswith("Thinking · step ") for e in run["events"])
    # Missing usage stays unknown, including on partial provider failures.
    tokens = {k: sum(u[k] for u in usages if isinstance(u.get(k), int))
              if usages and all(isinstance(u.get(k), int) for u in usages) else None
              for k in ("input_tokens", "output_tokens", "total_tokens")}
    return {"passed": all(c["passed"] for c in checks), "checks": checks,
            "answer": answer, "calls": calls, "file_sha256": hashes,
            "model_calls": model_calls, "tool_errors": errors, "usage": usages,
            "reported_tokens": tokens, "usage_complete": len(usages) == model_calls and model_calls > 0,
            "cost_usd": None}


def save_report(path, value, key):
    # Never serialize the request envelope. Redact the credential defensively from events.
    serialized = json.dumps(value, indent=2, ensure_ascii=False).replace(key, "[REDACTED]")
    temporary = path.with_suffix(".tmp")
    temporary.write_text(serialized + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="gpt-6-luna")
    parser.add_argument("--key-file", type=Path, default=Path.home() / ".aikeys")
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "dist/Fritz.app/Contents/Resources")
    parser.add_argument("--output", type=Path, help="New report directory; existing directories are refused")
    parser.add_argument("--case", action="append", dest="case_ids")
    parser.add_argument("--repetitions", type=int, default=2)
    parser.add_argument("--deadline", type=int, default=180, help="Seconds per attempt, including all model and tool calls")
    parser.add_argument("--max-turns", type=int, default=12)
    parser.add_argument("--list", action="store_true", help="List cases without loading credentials or calling a provider")
    args = parser.parse_args()
    corpus = load_cases(CORPUS)
    if args.list:
        for case in corpus["cases"]:
            print(f"{case['id']}: {case['purpose']}")
        return 0
    if not 1 <= args.repetitions <= 10 or not 1 <= args.max_turns <= 40 or not 1 <= args.deadline <= 600:
        parser.error("Use 1–10 repetitions, 1–40 turns, and a 1–600 second deadline")
    cases = [c for c in corpus["cases"] if not args.case_ids or c["id"] in args.case_ids]
    if args.case_ids and set(args.case_ids) - {c["id"] for c in cases}:
        parser.error("Unknown case ID; use --list")
    binary = args.bin_dir.resolve() / "fritz-harness"
    if not binary.is_file():
        parser.error("Staged harness missing; run CONFIGURATION=release make build first")
    key = read_key(args.key_file)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    output = (args.output or ROOT / "dist/evals" / run_id).resolve()
    output.mkdir(parents=True, exist_ok=False)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))
    report = {"run_id": run_id, "corpus_version": corpus["version"], "corpus_sha256": digest(CORPUS),
              "runner_sha256": digest(Path(__file__)), "source_commit": revision, "source_dirty": dirty,
              "binary": str(binary), "binary_sha256": digest(binary),
              "provider": "openai", "endpoint": "https://api.openai.com/v1/responses",
              "requested_model": args.model, "resolved_model": None,
              "settings": {"repetitions": args.repetitions, "deadline_seconds": args.deadline,
                           "max_turns": args.max_turns, "max_tool_calls": 64, "max_output_tokens_per_turn": 8192,
                           "reasoning_effort": "provider default", "temperature": "provider default"},
              "planned_attempts": len(cases) * args.repetitions, "attempts": []}
    save_report(output / "summary.json", report, key)
    print(f"Reports: {output}", flush=True)
    cancelled = False
    for case in cases:
        for repetition in range(1, args.repetitions + 1):
            attempt_id = f"{case['id']}-{repetition}"
            with tempfile.TemporaryDirectory(prefix="workspace-", dir=output) as directory:
                root = Path(directory)
                project = root / "project"
                project.mkdir()
                for name, content in case["files"].items():
                    path = project / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(content)
                connection_id = str(uuid.uuid4())
                envelope = {"connection": {"id": connection_id, "name": "Tool evaluation", "provider": "openai", "modelId": args.model},
                            "request": {"connectionId": connection_id, "model": args.model,
                                        "messages": [{"role": "user", "content": case["prompt"]}],
                                        "projectPath": str(project) if case.get("folder", True) else None,
                                        "maxTurns": args.max_turns}, "apiKey": key}
                env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL")}
                env.update(FRITZ_DATA_DIR=str(root / "data"), FRITZ_KEYCHAIN_SERVICE=f"dev.fritz.eval.{uuid.uuid4()}")
                run = run_harness(binary, envelope, env, args.deadline)
                verdict = grade(case, project, run)
                attempt = {"attempt_id": attempt_id, "case_id": case["id"], "repetition": repetition,
                           "purpose": case["purpose"], "prompt": case["prompt"], **run, **verdict}
                save_report(output / f"{attempt_id}.json", attempt, key)
            report["attempts"].append({k: v for k, v in attempt.items() if k not in ("events", "calls", "prompt", "answer", "file_sha256")})
            report["passed"] = sum(a["passed"] for a in report["attempts"])
            report["statuses"] = dict(Counter(a["status"] for a in report["attempts"]))
            report["complete"] = len(report["attempts"]) == report["planned_attempts"]
            save_report(output / "summary.json", report, key)
            failed = [c["check"] for c in verdict["checks"] if not c["passed"]]
            print(f"{'PASS' if verdict['passed'] else 'FAIL'} {attempt_id}: {run['status']}, {run['latency_seconds']}s, {verdict['model_calls']} model calls; failed checks: {failed}", flush=True)
            if run["status"] == "cancelled":
                cancelled = True
                break
        if cancelled:
            break
    return 0 if report.get("complete") and report.get("passed") == report["planned_attempts"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        # Exceptions from credential parsing must not echo credential contents.
        print(f"Evaluation setup failed ({type(error).__name__}); check paths, key assignment, and corpus.", flush=True)
        raise SystemExit(2)
