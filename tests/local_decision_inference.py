"""Opt-in local decision evaluation. Uses explicitly installed weights; never downloads or calls Jev."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time

# Small, fixed English reminder-intent set, independent of the model outputs.
# This is a smoke/quality gate, not a production calibration dataset.
DEVELOPMENT_CASES = [
    ("Remind me tomorrow morning to take out the trash.", True),
    ("Please set a reminder to call my dentist at 3 pm.", True),
    ("In twenty minutes, remind me to check the oven.", True),
    ("Don't let me forget to bring my passport tomorrow.", True),
    ("Can you remind me next Friday to submit my expenses?", True),
    ("Remind me to water the plants every Sunday.", True),
    ("What is the capital of France?", False),
    ("Summarize this note: the team meeting went well.", False),
    ("I already set a reminder to call my dentist.", False),
    ("Do not create a reminder. Just explain how reminders work.", False),
    ("Translate 'remind me tomorrow' into Spanish.", False),
    ("I took out the trash this morning.", False),
]


HOLDOUT_CASES = [
    ("At 9 tonight, remind me to lock the garage.", True),
    ("Set a reminder for 10am Tuesday: email the accountant.", True),
    ("Remind me two hours before my flight to pack the charger.", True),
    ("I need you to remind me on August 4 to renew my passport.", True),
    ("Tomorrow at lunch, remind me to return the library books.", True),
    ("Please remind me after work to buy milk.", True),
    ("My sister reminded me to mail the letter yesterday.", False),
    ("Cancel my reminder to water the plants.", False),
    ("Move my 2pm reminder to 4pm.", False),
    ("What does the word reminder mean?", False),
    ("Write a poem about forgetting an umbrella.", False),
    ("Add 'set a reminder for laundry' to my notes.", False),
]


def request(message, question_style="explicit", model="laya-en"):
    instructions = "What is the user's current request?" if question_style == "broad" else (
        "Does the message ask the assistant to create a new reminder? "
        "Classify quoted text, translation requests, completed reminders, and explanations as other.")
    return {"model": model, "state": {"message": message}, "questions": {
        "intent": {"type": "choice", "instructions": instructions,
                   "criteria": {"reminder": "Create a reminder for the user", "other": "Any other request or statement"}},
        "reminder": {"type": "noul", "instructions": "Is the user asking to create a reminder?"},
        "urgency": {"type": "score", "instructions": "How urgent is the request?",
                    "criteria": [{"urgency": "not urgent"}, {"urgency": "urgent"}]},
    }}


# Let the child's 120-second terminal deadline arrive before the outer watchdog.
EVENT_WAIT_SECONDS = 125


def read_event(child, timeout=EVENT_WAIT_SECONDS, receipt=None):
    ready, _, _ = select.select([child.stdout], [], [], timeout)
    assert ready, "Decision harness timed out"
    line = child.stdout.readline()
    if receipt is not None:
        receipt["raw_event_line"] = line
    assert line, "Decision harness exited without an event"
    return json.loads(line)


@contextmanager
def attempt(binary, env, value, models_dir, attempt_id, phase, expected=None,
            event_wait_seconds=EVENT_WAIT_SECONDS):
    """Flush an in-flight and terminal receipt even when validation or cleanup fails."""
    started = time.monotonic()
    receipt = {"type": "attempt", "id": attempt_id, "phase": phase,
               "status": "in_flight", "requested_model": value["model"], "request": value,
               "expected_reminder": expected, "models_directory": str(models_dir),
               "child_deadline_seconds": 120, "event_wait_seconds": event_wait_seconds}
    print(json.dumps(receipt), flush=True)
    child = None
    failure = None
    try:
        child = subprocess.Popen([str(binary), "evaluate"], env=env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        receipt["pid"] = child.pid
        child.stdin.write(json.dumps({"backend": {"kind": "ollaya"}, "request": value,
                                     "modelStore": {"directory": str(models_dir), "modelDirectories": {}}}) + "\n")
        child.stdin.flush()
        yield child, receipt
    except BaseException as error:
        failure = {"type": type(error).__name__, "message": str(error)}
        raise
    finally:
        cleanup = {"spawned": child is not None, "forced_kill": False}
        if child is not None:
            try:
                if child.poll() is None and child.stdin is not None:
                    child.stdin.close()
                    child.stdin = None
                try:
                    stdout, stderr = child.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    cleanup["forced_kill"] = True
                    child.kill()
                    stdout, stderr = child.communicate(timeout=10)
                cleanup.update(returncode=child.returncode, remaining_stdout=stdout, stderr=stderr)
            except BaseException as error:
                cleanup["error"] = {"type": type(error).__name__, "message": str(error)}
                if child.poll() is None:
                    cleanup["forced_kill"] = True
                    child.kill()
                    child.wait(timeout=10)
        event = receipt.get("event")
        result = event.get("result") if isinstance(event, dict) else None
        result = result if isinstance(result, dict) else {}
        receipt.update(status="failed" if failure or "error" in cleanup else "passed",
                       elapsed_seconds=time.monotonic() - started, error=failure, cleanup=cleanup,
                       resolved_model=result.get("model"), usage=result.get("usage"))
        print(json.dumps(receipt), flush=True)
        if "error" in cleanup and failure is None:
            raise RuntimeError("Owned decision-child cleanup failed: " + cleanup["error"]["message"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True, type=Path)
    parser.add_argument("--models-dir", required=True, type=Path)
    parser.add_argument("--model", choices=["laya-en", "kev-4b"], default="laya-en")
    parser.add_argument("--bin-dir", default=Path("target/debug"), type=Path)
    parser.add_argument("--suite", choices=["development", "holdout"], default="holdout")
    parser.add_argument("--question-style", choices=["broad", "explicit"], default="explicit")
    args = parser.parse_args()
    cases = DEVELOPMENT_CASES if args.suite == "development" else HOLDOUT_CASES
    models_dir = args.models_dir.resolve()
    env = dict(os.environ, FRITZ_DATA_DIR=str(args.data_dir.resolve()), FRITZ_MODELS_DIR=str(models_dir))
    binary = args.bin_dir.resolve() / "fritz-decision-harness"
    correct = 0
    brier = 0
    timings = []
    results = []
    for index, (message, expected) in enumerate(cases, 1):
        started = time.monotonic()
        with attempt(binary, env, request(message, args.question_style, args.model), models_dir,
                     f"{args.suite}-{index:02}", args.suite, expected) as (child, receipt):
            event = read_event(child, receipt=receipt)
            receipt["event"] = event
            child.wait(timeout=10)
            assert child.returncode == 0 and event["type"] == "result", event
            result = event["result"]
            assert result["model"].startswith(args.model + "@"), result
            answers = result["answers"]
            assert answers["urgency"]["legend"] == {"0": {"urgency": "not urgent"}, "1": {"urgency": "urgent"}}
            assert 0 <= answers["urgency"]["score"] <= 1
            assert result["usage"]["input_tokens"] > 0 and result["usage"]["output_tokens"] == 0
            predicted = answers["intent"]["choice"] == "reminder"
            correct += predicted == expected
            probability = answers["reminder"]["noul"]
            brier += (probability - int(expected)) ** 2
            timings.append(time.monotonic() - started)
            judgment = {"message": message, "expected": expected, "choice": predicted, "noul": probability}
            receipt["judgment"] = judgment
            results.append(judgment)
    summary = {"type": "summary", "model": args.model, "suite": args.suite, "question_style": args.question_style, "cases": len(cases), "choice_accuracy": correct / len(cases),
               "noul_brier": brier / len(cases), "cold_seconds_min": min(timings),
               "cold_seconds_max": max(timings), "results": results}
    print(json.dumps(summary), flush=True)
    # Reject truncation explicitly rather than returning a decision on an unseen suffix.
    with attempt(binary, env, request("A long note. " * 5000, model=args.model), models_dir,
                 "context-limit", "context_rejection") as (child, receipt):
        event = read_event(child, receipt=receipt)
        receipt["event"] = event
        assert event["type"] == "error" and (
            "context" in event["message"] or "the model's limit" in event["message"]), event
        child.wait(timeout=10)
    # Observe native model memory before cancelling, so this exercises native loading/inference,
    # not just stdin cancellation while the checksum is still running.
    for index, cancellation in enumerate(("pipe", "signal") * 3, 1):
        with attempt(binary, env, request("Remind me tomorrow to call my dentist.", model=args.model), models_dir,
                     f"cancellation-{index:02}", cancellation, event_wait_seconds=5) as (child, receipt):
            deadline = time.monotonic() + 60
            while True:
                assert child.poll() is None, "Model completed before cancellation was exercised"
                rss = subprocess.check_output(["ps", "-o", "rss=", "-p", str(child.pid)], text=True).strip()
                if int(rss or 0) > 1_000_000:
                    break
                assert time.monotonic() < deadline, "Did not observe native model loading"
                time.sleep(0.02)
            started = time.monotonic()
            if cancellation == "pipe":
                child.stdin.close()
                child.stdin = None
            else:
                child.send_signal(signal.SIGTERM)
            event = read_event(child, 5, receipt)
            receipt["event"] = event
            assert event["type"] == "cancelled"
            child.wait(timeout=5)
            assert child.returncode == 0, (cancellation, child.returncode, child.stderr.read())
            assert time.monotonic() - started < 5
    print("PASS: real local typed inference, structured scores, context limit, and six native cancellation runs", flush=True)
    assert correct / len(cases) >= 0.8, "Reminder intent failed the initial accuracy gate"
    assert brier / len(cases) <= 0.2, "Reminder probability failed the initial Brier gate"
    print("PASS: reminder quality gate")


if __name__ == "__main__":
    main()
