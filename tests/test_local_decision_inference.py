"""Offline failures must retain completed local-evaluation receipts and owned-child cleanup."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "tests/local_decision_inference.py"
spec = importlib.util.spec_from_file_location("local_decision_inference", DRIVER)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class LocalDecisionReceipts(unittest.TestCase):
    def test_later_error_retains_earlier_result_usage_and_does_not_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary = directory / "fritz-decision-harness"
            calls = directory / "requests.jsonl"
            binary.write_text("#!/usr/bin/env python3\n" + f'''
import json, pathlib, sys
value = json.loads(sys.stdin.readline())
with pathlib.Path({str(calls)!r}).open("a") as stream:
    stream.write(json.dumps(value) + "\\n")
message = value["request"]["state"]["message"]
if message == "At 9 tonight, remind me to lock the garage.":
    event = {{"type":"result", "result":{{"model":"kev-4b@fixture",
        "usage":{{"input_tokens":37,"output_tokens":0}}, "answers":{{
        "intent":{{"type":"choice","choice":"reminder"}},
        "reminder":{{"type":"noul","noul":0.9}},
        "urgency":{{"type":"score","score":0.2,
            "legend":{{"0":{{"urgency":"not urgent"}},"1":{{"urgency":"urgent"}}}}}}
    }}}}}}
else:
    event = {{"type":"error","message":"injected native failure"}}
print(json.dumps(event), flush=True)
''')
            binary.chmod(0o755)
            process = subprocess.run([sys.executable, str(DRIVER), "--data-dir", str(directory / "Data"),
                                      "--models-dir", str(directory / "Models"), "--model", "kev-4b",
                                      "--bin-dir", str(directory)], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(process.returncode, 0)
            receipts = [json.loads(line) for line in process.stdout.splitlines()]
            self.assertEqual([(r["id"], r["status"]) for r in receipts], [
                ("holdout-01", "in_flight"), ("holdout-01", "passed"),
                ("holdout-02", "in_flight"), ("holdout-02", "failed")])
            first, failure = receipts[1], receipts[3]
            self.assertEqual(first["usage"], {"input_tokens":37,"output_tokens":0})
            self.assertEqual(first["resolved_model"], "kev-4b@fixture")
            self.assertEqual(first["judgment"]["choice"], True)
            self.assertEqual(failure["event"], {"type":"error","message":"injected native failure"})
            self.assertIsNone(failure["usage"])
            self.assertIsNone(failure["resolved_model"])
            for receipt in (first, failure):
                self.assertGreater(receipt["elapsed_seconds"], 0)
                self.assertEqual(receipt["cleanup"]["returncode"], 0)
                self.assertFalse(receipt["cleanup"]["forced_kill"])
                self.assertEqual(receipt["cleanup"]["stderr"], "")
            self.assertEqual(len(calls.read_text().splitlines()), 2)
            self.assertGreater(failure["event_wait_seconds"], failure["child_deadline_seconds"])

    def test_timeout_keeps_failure_when_eof_cleanup_receives_cancellation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary = directory / "child"
            binary.write_text('''#!/usr/bin/env python3
import json, sys
sys.stdin.readline()
sys.stdin.read()
print(json.dumps({"type":"cancelled"}), flush=True)
''')
            binary.chmod(0o755)
            output = io.StringIO()
            with redirect_stdout(output), self.assertRaisesRegex(AssertionError, "timed out"):
                with driver.attempt(binary, dict(os.environ), {"model":"kev-4b", "state":{}, "questions":{}},
                                    directory / "Models", "timeout", "transport", event_wait_seconds=0.02) as (child, receipt):
                    driver.read_event(child, 0.02, receipt)
            records = [json.loads(line) for line in output.getvalue().splitlines()]
            terminal = records[-1]
            self.assertEqual(terminal["status"], "failed")
            self.assertEqual(terminal["error"]["type"], "AssertionError")
            self.assertEqual(json.loads(terminal["cleanup"]["remaining_stdout"]), {"type":"cancelled"})
            self.assertEqual(terminal["cleanup"]["returncode"], 0)
            self.assertFalse(terminal["cleanup"]["forced_kill"])

    def test_malformed_terminal_keeps_original_failure_and_raw_line(self):
        for event in (None, [], {"type":"result", "result":None}, {"type":"result", "result":[]}):
            with self.subTest(event=event), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                binary = directory / "fritz-decision-harness"
                binary.write_text("#!/usr/bin/env python3\nimport sys\nsys.stdin.readline()\n"
                                  + f"print({json.dumps(event)!r}, flush=True)\n")
                binary.chmod(0o755)
                process = subprocess.run([sys.executable, str(DRIVER), "--data-dir", str(directory / "Data"),
                                          "--models-dir", str(directory / "Models"), "--model", "kev-4b",
                                          "--bin-dir", str(directory)], capture_output=True, text=True, timeout=10)
                self.assertNotEqual(process.returncode, 0)
                records = [json.loads(line) for line in process.stdout.splitlines()]
                self.assertEqual(len(records), 2)
                terminal = records[-1]
                self.assertEqual(terminal["status"], "failed")
                self.assertEqual(terminal["error"]["type"], "TypeError")
                self.assertEqual(json.loads(terminal["raw_event_line"]), event)
                self.assertEqual(terminal["cleanup"]["returncode"], 0)
                self.assertFalse(terminal["cleanup"]["forced_kill"])
                self.assertIsNone(terminal["usage"])


if __name__ == "__main__":
    unittest.main()
