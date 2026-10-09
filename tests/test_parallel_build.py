"""Check actual overlap and cancellation at the build scheduler boundary."""
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/parallel-build.py'


class ParallelBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=os.environ.get('FRITZ_BUILD_ROOT'))
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def command(self, first, second):
        return [sys.executable, str(SCRIPT), str(self.root / 'logs'),
                sys.executable, '-c', first, ':::', sys.executable, '-c', second]

    def test_independent_builds_overlap_and_preserve_both_logs(self):
        # Both jobs wait on the other's marker: serial scheduling cannot pass.
        source = ('from pathlib import Path; import time\n'
                  'Path({own!r}).touch()\n'
                  'deadline=time.monotonic()+5\n'
                  'while not Path({other!r}).exists():\n'
                  ' if time.monotonic()>deadline: raise SystemExit(42)\n'
                  ' time.sleep(.02)\nprint("completed")\n')
        a, b = str(self.root / 'a'), str(self.root / 'b')
        subprocess.run(self.command(source.format(own=a, other=b),
                                     source.format(own=b, other=a)), check=True)
        for name in ('rust', 'swift'):
            self.assertIn('completed', (self.root / f'logs/{name}.log').read_text())

    def test_failure_and_signal_cancel_the_other_build(self):
        for cancelled in (False, True):
            with self.subTest(cancelled=cancelled):
                marker = self.root / f'started-{cancelled}'
                finished = self.root / f'terminated-{cancelled}'
                waiting = ('from pathlib import Path; import signal, time\n'
                           f'def stop(*args): Path({str(finished)!r}).touch(); raise SystemExit(0)\n'
                           f'signal.signal(signal.SIGTERM, stop); Path({str(marker)!r}).touch()\n'
                           'time.sleep(60)\n')
                fail = (f'from pathlib import Path; import time\n'
                        f'while not Path({str(marker)!r}).exists(): time.sleep(.02)\n'
                        'raise SystemExit(7)\n')
                process = subprocess.Popen(self.command(waiting, waiting if cancelled else fail),
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    if cancelled:
                        deadline = time.monotonic() + 5
                        while not marker.exists() and time.monotonic() < deadline:
                            time.sleep(.02)
                        self.assertTrue(marker.exists())
                        process.send_signal(signal.SIGTERM)
                    stdout, stderr = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 143 if cancelled else 7, stderr.decode())
                    self.assertTrue(finished.exists(), stdout.decode())
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.communicate(timeout=10)

    def test_compiler_children_hold_storage_locks_if_scheduler_is_killed(self):
        # Run the actual storage wrapper and scheduler. Abrupt parent death
        # must not allow a competing worktree to consume unfinished outputs.
        root = SCRIPT.parent.parent
        wrappers = []
        for name in ('first', 'second'):
            wrapper = self.root / name / 'scripts/build-cache.py'
            wrapper.parent.mkdir(parents=True)
            shutil.copy2(root / 'scripts/build-cache.py', wrapper)
            wrappers.append(wrapper)
        environment = dict(os.environ, FRITZ_BUILD_ROOT=str(self.root / 'cache'))
        release = self.root / 'release'
        marker = self.root / 'consumed'
        jobs = []
        for name in ('a', 'b'):
            started = self.root / name
            jobs.append(f'from pathlib import Path; import time\nPath({str(started)!r}).touch()\n'
                        f'while not Path({str(release)!r}).exists(): time.sleep(.02)\n')
        owner = subprocess.Popen([sys.executable, str(wrappers[0]), *self.command(*jobs)],
                                 env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        competitor = None
        try:
            deadline = time.monotonic() + 5
            while not all((self.root / name).exists() for name in ('a', 'b')):
                self.assertLess(time.monotonic(), deadline, 'compiler jobs never started')
                time.sleep(.02)
            owner.kill()
            owner.communicate(timeout=5)
            competitor = subprocess.Popen([sys.executable, str(wrappers[1]), sys.executable, '-c',
                f'from pathlib import Path; Path({str(marker)!r}).touch()'],
                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            with self.assertRaises(subprocess.TimeoutExpired):
                competitor.communicate(timeout=.3)
            self.assertFalse(marker.exists(), 'competing build consumed active outputs')
            release.touch()
            competitor.communicate(timeout=5)
            self.assertEqual(competitor.returncode, 0)
            self.assertTrue(marker.exists())
        finally:
            release.touch()
            if owner.poll() is None:
                owner.terminate()
            owner.communicate(timeout=5)
            if competitor is not None:
                competitor.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main()
