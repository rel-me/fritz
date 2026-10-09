"""Check the build-command boundary without invoking expensive compilers."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build-cache.py"
ROOT = SCRIPT.parent.parent


class BuildCacheTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="fritz build cache ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.environment = dict(os.environ, FRITZ_BUILD_ROOT=str(self.root / "shared cache"))
        self.scripts = []
        for name in ("main", "worktree"):
            script = self.root / name / "scripts/build-cache.py"
            script.parent.mkdir(parents=True)
            shutil.copyfile(SCRIPT, script)
            shutil.copyfile(ROOT / "Makefile", script.parent.parent / "Makefile")
            shutil.copyfile(ROOT / "scripts/setup-worktree.sh", script.parent / "setup-worktree.sh")
            (script.parent / "setup-worktree.sh").chmod(0o755)
            self.scripts.append(script)

    def command(self, index, *args):
        return [sys.executable, str(self.scripts[index]), *args]

    def test_worktrees_share_cargo_but_keep_source_dependent_build_state_separate(self):
        results = []
        for index in range(2):
            result = subprocess.check_output(self.command(index, sys.executable, "-c",
                "import json, os; print(json.dumps({key: os.environ[key] for key in "
                "['CARGO_TARGET_DIR', 'FRITZ_SWIFT_CACHE', 'FRITZ_XCODE_CACHE', "
                "'FRITZ_SWIFT_BUILD', 'FRITZ_APP_SWIFT_BUILD', 'FRITZ_DERIVED_DATA']}))"), env=self.environment)
            results.append(json.loads(result))
        for variable in ("CARGO_TARGET_DIR", "FRITZ_SWIFT_CACHE", "FRITZ_XCODE_CACHE"):
            self.assertEqual(results[0][variable], results[1][variable])
        for variable in ("FRITZ_SWIFT_BUILD", "FRITZ_APP_SWIFT_BUILD", "FRITZ_DERIVED_DATA"):
            self.assertNotEqual(results[0][variable], results[1][variable])
            for result in results:
                self.assertTrue(Path(result[variable]).is_dir())
                self.assertTrue(Path(result[variable]).is_relative_to(self.root / "shared cache"))

    def test_lock_spans_make_command_and_releases_after_failure(self):
        started = self.root / "started"
        release = self.root / "release"
        consumed = self.root / "consumed"
        worker = self.root / "worker.py"
        worker.write_text("import pathlib, sys, time\n"
                          "pathlib.Path(sys.argv[1]).touch()\n"
                          "while not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.02)\n"
                          "sys.exit(7)\n")
        makefile = self.root / "Makefile"
        makefile.write_text(f'all:\n\t@"{sys.executable}" "{worker}" "{started}" "{release}"\n')
        first = subprocess.Popen(self.command(0, "make", "-f", str(makefile)),
                                 env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = None
        try:
            deadline = time.monotonic() + 10
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(started.exists(), "first build never started")
            second = subprocess.Popen(self.command(1, sys.executable, "-c",
                "import pathlib, sys; pathlib.Path(sys.argv[1]).touch()", str(consumed)),
                env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            with self.assertRaises(subprocess.TimeoutExpired):
                second.communicate(timeout=0.3)
            self.assertFalse(consumed.exists(), "competing worktree entered an active build")
            release.touch()
            first.communicate(timeout=10)
            self.assertNotEqual(first.returncode, 0)
            second.communicate(timeout=10)
            self.assertEqual(second.returncode, 0)
            self.assertTrue(consumed.exists())
        finally:
            release.touch()
            first.communicate(timeout=10)
            if second is not None:
                second.communicate(timeout=10)

    @unittest.skipUnless(sys.platform == "darwin", "worktree setup requires macOS")
    def test_setup_waits_for_its_checkout_but_not_another_worktrees_build(self):
        # Toolchain work is outside this lock-routing test; run the real Make
        # and setup entry points with successful dependency-tool commands.
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("cargo", "swift", "xcodebuild", "cmake", "mise"):
            tool = tools / name
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o755)
        environment = dict(self.environment, PATH=f"{tools}{os.pathsep}{os.environ['PATH']}")
        started = self.root / "build-started"
        release = self.root / "build-release"
        build = subprocess.Popen(self.command(0, sys.executable, "-c",
            "import pathlib, sys, time; pathlib.Path(sys.argv[1]).touch(); "
            "\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.02)",
            str(started), str(release)), env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        setups = []
        try:
            deadline = time.monotonic() + 10
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(started.exists(), "build never started")
            for script in self.scripts:
                setups.append(subprocess.Popen(["make", "--no-print-directory", "setup"],
                    cwd=script.parent.parent, env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            with self.assertRaises(subprocess.TimeoutExpired):
                setups[0].communicate(timeout=0.3)
            stdout, stderr = setups[1].communicate(timeout=5)
            self.assertEqual(setups[1].returncode, 0, stderr.decode())
            self.assertIn(b"Fritz dependencies are ready", stdout)
            self.assertIsNone(build.poll(), "setup must complete while the other build is active")
            release.touch()
            build.communicate(timeout=10)
            stdout, stderr = setups[0].communicate(timeout=10)
            self.assertEqual(setups[0].returncode, 0, stderr.decode())
            self.assertIn(b"Fritz dependencies are ready", stdout)
        finally:
            release.touch()
            build.communicate(timeout=10)
            for setup in setups:
                setup.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main()
