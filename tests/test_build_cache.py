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
        self.environment.pop("FRITZ_CACHE_ROOT", None)
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

    def test_build_outputs_and_package_caches_follow_their_selected_roots(self):
        for runner_isolated in (False, True):
            with self.subTest(runner_isolated=runner_isolated):
                results = []
                for index in range(2):
                    environment = dict(self.environment)
                    if runner_isolated:
                        environment.update(
                            FRITZ_BUILD_ROOT=str(self.root / f"runner-{index}"),
                            FRITZ_CACHE_ROOT=str(self.root / "shared downloads"))
                    result = subprocess.check_output(self.command(index, sys.executable, "-c",
                        "import json, os; print(json.dumps({key: os.environ[key] for key in "
                        "['CARGO_TARGET_DIR', 'FRITZ_SWIFT_CACHE', 'FRITZ_XCODE_CACHE', "
                        "'FRITZ_SWIFT_BUILD', 'FRITZ_APP_SWIFT_BUILD', 'FRITZ_DERIVED_DATA']}))"), env=environment)
                    results.append(json.loads(result))
                for variable in ("FRITZ_SWIFT_CACHE", "FRITZ_XCODE_CACHE"):
                    self.assertEqual(results[0][variable], results[1][variable])
                if runner_isolated:
                    self.assertNotEqual(results[0]["CARGO_TARGET_DIR"], results[1]["CARGO_TARGET_DIR"])
                else:
                    self.assertEqual(results[0]["CARGO_TARGET_DIR"], results[1]["CARGO_TARGET_DIR"])
                for variable in ("FRITZ_SWIFT_BUILD", "FRITZ_APP_SWIFT_BUILD", "FRITZ_DERIVED_DATA"):
                    self.assertNotEqual(results[0][variable], results[1][variable])
                for index, result in enumerate(results):
                    for variable, path in result.items():
                        self.assertTrue(Path(path).is_dir())
                        if runner_isolated:
                            root = (self.root / "shared downloads" if variable in
                                    ("FRITZ_SWIFT_CACHE", "FRITZ_XCODE_CACHE") else self.root / f"runner-{index}")
                        else:
                            root = self.root / "shared cache"
                        self.assertTrue(Path(path).is_relative_to(root), (variable, path, root))

    def test_runner_builds_overlap_while_using_shared_package_caches(self):
        worker = self.root / "worker.py"
        worker.write_text("from pathlib import Path; import sys, time\n"
                          "Path(sys.argv[1]).touch()\n"
                          "deadline = time.monotonic() + 5\n"
                          "while not Path(sys.argv[2]).exists():\n"
                          " if time.monotonic() >= deadline: raise SystemExit(42)\n"
                          " time.sleep(0.02)\n")
        markers = [self.root / f"started-{index}" for index in range(2)]
        processes = []
        try:
            for index in range(2):
                environment = dict(self.environment,
                    FRITZ_BUILD_ROOT=str(self.root / f"runner-{index}"),
                    FRITZ_CACHE_ROOT=str(self.root / "shared downloads"))
                processes.append(subprocess.Popen(self.command(index, sys.executable, str(worker),
                    str(markers[index]), str(markers[1 - index])), env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            for process in processes:
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, (stdout + stderr).decode())
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=10)

    @unittest.skipUnless(sys.platform == "darwin", "compiler cache configuration requires macOS")
    def test_runners_share_compiler_storage_and_server_identity(self):
        tools = self.root / "tools"
        tools.mkdir()
        mise = tools / "mise"
        mise.write_text("#!/bin/sh\nprintf '%s\\n' /usr/bin/true\n")
        mise.chmod(0o755)
        probe = ("import json, os, sys; print(json.dumps(dict("
                 "rust=os.environ['SCCACHE_DIR'], server=os.environ['SCCACHE_SERVER_UDS'], "
                 "xcode=sys.argv[1:])))")
        results = []
        for index in range(2):
            environment = dict(self.environment,
                FRITZ_BUILD_ROOT=str(self.root / f"runner-{index}"),
                FRITZ_CACHE_ROOT=str(self.root / "shared downloads"),
                PATH=f"{tools}{os.pathsep}{os.environ['PATH']}")
            output = subprocess.check_output(self.command(index, "bash", "-c",
                'set -e; source "$1"; configure_compiler_cache; exec "$2" -c "$3" "${xcode_cache_settings[@]}"',
                "compiler-cache-probe", str(ROOT / "scripts/compiler-cache.sh"), sys.executable, probe),
                env=environment)
            results.append(json.loads(output))
        self.assertEqual(results[0], results[1])
        self.assertEqual(Path(results[0]["rust"]), self.root / "shared downloads/compiler-cache/rust")
        self.assertIn(f"COMPILATION_CACHE_CAS_PATH={self.root / 'shared downloads/compiler-cache/xcode'}",
                      results[0]["xcode"])

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
        for script in self.scripts:
            subprocess.run(["git", "init", "-q", str(script.parent.parent)], check=True)
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("cargo", "swift", "xcodebuild", "cmake"):
            tool = tools / name
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o755)
        mise = tools / "mise"
        mise.write_text('#!/bin/sh\nif [ "$1" = exec ]; then shift 2; exec "$@"; fi\nexit 0\n')
        mise.chmod(0o755)
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
