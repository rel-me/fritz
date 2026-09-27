"""Protect eval verdicts, credential handling, and owned-process cancellation."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("tool_evals", Path(__file__).resolve().parents[1] / "evals/run_tools.py")
evals = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evals)


def tool_events(name, arguments, result, success=True, call_id="one"):
    return [{"type": "tool_start", "toolCallId": call_id, "name": name, "details": json.dumps(arguments)},
            {"type": "tool_end", "toolCallId": call_id, "name": name, "success": success, "details": json.dumps(result)}]


class ToolEvalTests(unittest.TestCase):
    def test_verdict_requires_real_artifacts_and_preserves_unrelated_files(self):
        case = {"files": {"keep.txt": "original\n"}, "expected_json_files": {"total.json": {"total": 37}},
                "required_tools": ["create_file"]}
        events = tool_events("create_file", {"path": "total.json", "content": '{"total":37}'}, {"created": True})
        events += [{"type": "delta", "text": "Done; I verified everything."}]
        run = {"status": "result", "events": events}
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / "keep.txt").write_text("original\n")
            verdict = evals.grade(case, project, run)
            self.assertFalse(verdict["passed"])
            self.assertFalse(next(c for c in verdict["checks"] if c["check"] == "file:total.json")["passed"])
            (project / "total.json").write_text('{"total": 37}\n')
            self.assertTrue(evals.grade(case, project, run)["passed"])
            for mutation in ("wrong_result", "unrelated_edit", "extra_file", "extra_directory", "symlink"):
                with self.subTest(mutation=mutation):
                    (project / "total.json").write_text('{"total": 99}' if mutation == "wrong_result" else '{"total":37}')
                    (project / "keep.txt").write_text("changed" if mutation == "unrelated_edit" else "original\n")
                    extra = project / "unexpected"
                    if mutation == "extra_file":
                        extra.write_text("oops")
                    elif mutation == "extra_directory":
                        extra.mkdir()
                    elif mutation == "symlink":
                        extra.symlink_to(project / "keep.txt")
                    self.assertFalse(evals.grade(case, project, run)["passed"])
                    if extra.is_dir():
                        extra.rmdir()
                    elif extra.exists():
                        extra.unlink()

    def test_recovery_requires_failed_call_then_success_and_scores_only_final_answer(self):
        case = {"files": {}, "required_tools": ["run_command"], "expected_tool_errors": 1,
                "answer_json": {"result": 74}, "trace": [{"name": "run_command", "success": False},
                    {"name": "run_command", "result_contains": "74"}]}
        failed = tool_events("run_command", {"command": "false"}, {"exit_code": 1}, False, "a")
        success = tool_events("run_command", {"command": "printf 74"}, {"exit_code": 0, "stdout": "74"}, True, "b")
        final = [{"type": "activity", "message": "Thinking · step 3"}, {"type": "delta", "text": '{"result":74}'}]
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            for status, middle, passes in [("result", failed + success, True),
                                            ("result", success + failed, False),
                                            ("timeout", failed + success, False),
                                            ("result", failed + success[:1], False),
                                            ("result", failed + success[1:], False)]:
                with self.subTest(status=status, middle=middle):
                    verdict = evals.grade(case, project, {"status": status, "events": [
                        {"type": "delta", "text": "I will check."}, *middle, *final]})
                    self.assertEqual(verdict["passed"], passes)
                    self.assertIsNone(verdict["reported_tokens"]["input_tokens"])
                    self.assertFalse(verdict["usage_complete"])

    def test_key_file_is_literal_and_reports_redact_echoed_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            keys = root / "keys"
            keys.write_text("OTHER_KEY=ignored\nexport OPENAI_API_KEY='synthetic-secret' # comment\n")
            self.assertEqual(evals.read_key(keys), "synthetic-secret")
            report = root / "report.json"
            evals.save_report(report, {"message": "echo synthetic-secret"}, evals.read_key(keys))
            self.assertEqual(json.loads(report.read_text())["message"], "echo [REDACTED]")
            keys.write_text(f"OPENAI_API_KEY=$(touch {root / 'executed'})\n")
            with self.assertRaises(ValueError):
                evals.read_key(keys)
            self.assertFalse((root / "executed").exists())

    def test_deadline_closes_private_pipe_and_retains_partial_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "harness"
            # This fixture tests runner lifecycle only; real tool execution belongs
            # to coding_integration.py and the opt-in live corpus.
            binary.write_text("#!/usr/bin/env python3\nimport json, pathlib, sys\n"
                              "request = json.loads(sys.stdin.readline())\n"
                              "print(json.dumps({'type':'usage','usage':{'input_tokens':19}}), flush=True)\n"
                              "sys.stdin.read()\n"
                              "pathlib.Path(request['receipt']).write_text('EOF observed')\n"
                              "print(json.dumps({'type':'cancelled'}), flush=True)\n")
            binary.chmod(0o700)
            receipt = root / "receipt"
            run = evals.run_harness(binary, {"receipt": str(receipt)}, dict(os.environ), 1)
            self.assertEqual(run["status"], "timeout")
            self.assertEqual(run["exit_code"], 0)
            self.assertEqual(receipt.read_text(), "EOF observed")
            self.assertEqual(run["events"][0]["usage"]["input_tokens"], 19)
            self.assertEqual(run["events"][-1]["type"], "cancelled")


if __name__ == "__main__":
    unittest.main()
