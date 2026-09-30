"""Exercise Debug app naming with real Git branches and no GitHub setup."""

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
        self.environment = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin")

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

    def test_primary_checkout_uses_plain_name_without_github_setup(self):
        for branch in ["main", "feature"]:
            with self.subTest(branch=branch):
                self.git("checkout", "-B", branch)
                result = self.resolve()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("app_name=FritzDebug\n", result.stdout)

        self.git("checkout", "--detach")
        detached = self.resolve()
        self.assertEqual(detached.returncode, 0, detached.stderr)
        self.assertRegex(detached.stdout, r"(?m)^app_name=FritzDebug[0-9a-f]{8}$")

    def test_linked_main_uses_plain_debug_name(self):
        primary = self.resolve()
        self.git("switch", "-c", "feature")
        self.use_linked_worktree("main")
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("app_name=FritzDebug\n", result.stdout)
        for output in (primary.stdout, result.stdout):
            self.assertIn("models_directory=/Library/Application Support/Fritz/Data/Models\n", output)

    def test_feature_and_detached_head_share_checkout_name_without_pr(self):
        self.git("branch", "feature")
        self.use_linked_worktree("feature")
        feature = self.resolve()
        self.assertEqual(feature.returncode, 0, feature.stderr)
        self.assertRegex(feature.stdout, r"(?m)^app_name=FritzDebug[0-9a-f]{8}$")

        self.git("checkout", "--detach")
        detached = self.resolve()
        self.assertEqual(detached.returncode, 0, detached.stderr)
        self.assertEqual(detached.stdout, feature.stdout)

    def test_feature_with_pr_uses_number_for_name_and_keeps_checkout_isolation(self):
        self.git("branch", "feature")
        self.use_linked_worktree("feature")
        without_pr = self.resolve()
        gh = self.bin / "gh"
        gh.write_text("#!/bin/sh\nprintf '51\\n'\n")
        gh.chmod(0o755)

        with_pr = self.resolve()
        self.assertEqual(with_pr.returncode, 0, with_pr.stderr)
        self.assertIn("app_name=FritzDebug51\n", with_pr.stdout)
        for prefix in ("bundle_id=", "data_directory=", "keychain_service="):
            self.assertEqual(next(line for line in with_pr.stdout.splitlines() if line.startswith(prefix)),
                             next(line for line in without_pr.stdout.splitlines() if line.startswith(prefix)))


if __name__ == "__main__":
    unittest.main()
