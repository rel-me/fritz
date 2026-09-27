"""Exercise Debug app naming with real Git branches and controlled PR responses."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/dev-runtime.sh"


class DevRuntimeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="fritz debug name ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.script = self.root / "scripts/dev-runtime.sh"
        self.script.parent.mkdir()
        shutil.copyfile(SCRIPT, self.script)
        self.git("init", "-b", "main")
        self.git("add", "scripts/dev-runtime.sh")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "commit", "--allow-empty", "-m", "Initial")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text('#!/bin/bash\nprintf "%s" "$TEST_PR_RESPONSE"\nexit "$TEST_PR_STATUS"\n')
        gh.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin",
                                TEST_PR_RESPONSE="", TEST_PR_STATUS="0")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def resolve(self):
        return subprocess.run(["/bin/bash", str(self.script), "--print"],
                              env=self.environment, capture_output=True, text=True)

    def use_linked_worktree(self, branch):
        linked = self.root / "linked checkout"
        self.git("worktree", "add", str(linked), branch)
        self.root = linked
        self.script = self.root / "scripts/dev-runtime.sh"

    def test_primary_checkout_needs_neither_github_cli_nor_origin(self):
        (self.bin / "gh").unlink()
        for branch in ["main", "feature"]:
            with self.subTest(branch=branch):
                self.git("checkout", "-B", branch)
                result = self.resolve()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("app_name=FritzDebug\n", result.stdout)

    def test_linked_main_needs_neither_github_cli_nor_origin(self):
        self.git("switch", "-c", "feature")
        self.use_linked_worktree("main")
        (self.bin / "gh").unlink()
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("app_name=FritzDebug\n", result.stdout)

    def test_feature_branch_requires_one_resolved_open_pr(self):
        self.git("branch", "feature")
        self.use_linked_worktree("feature")
        self.git("remote", "add", "origin", "https://github.com/example/fritz.git")
        for response, status, expected in [
            ("42\n", "0", "app_name=FritzDebug42\n"),
            ("", "0", "requires an open PR"),
            ("42\n43\n", "0", "expected exactly one open PR"),
            ("invalid", "0", "expected exactly one open PR"),
            ("0", "0", "expected exactly one open PR"),
            ("42", "1", "could not resolve the open PR"),
        ]:
            with self.subTest(response=response, status=status):
                self.environment.update(TEST_PR_RESPONSE=response, TEST_PR_STATUS=status)
                result = self.resolve()
                if expected.startswith("app_name="):
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(expected, result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr)

        (self.bin / "gh").unlink()
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires GitHub CLI", result.stderr)
        self.git("remote", "remove", "origin")
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires an origin remote", result.stderr)
        self.git("checkout", "--detach")
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a branch", result.stderr)


if __name__ == "__main__":
    unittest.main()
