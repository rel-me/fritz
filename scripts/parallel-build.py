#!/usr/bin/env python3
"""Run independent Rust and Swift builds with owned-process cancellation."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def run(commands, log_directory):
    log_directory.mkdir(parents=True, exist_ok=True)
    jobs = []
    started = time.monotonic()
    try:
        for name, command in zip(('rust', 'swift'), commands, strict=True):
            path = log_directory / (name + '.log')
            log = path.open('w')
            try:
                process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                           start_new_session=True, close_fds=False)
                # Preserve the wrapper's inheritable checkout/shared locks and
                # Make jobserver through compiler children, including cancellation.
            except BaseException:
                log.close()
                raise
            jobs.append((name, process, log, path))
        remaining = jobs.copy()
        while remaining:
            for job in remaining.copy():
                name, process, _, path = job
                status = process.poll()
                if status is None:
                    continue
                remaining.remove(job)
                print(f'{name}: {"finished" if status == 0 else "failed"} '
                      f'after {time.monotonic() - started:.1f}s ({path})', flush=True)
                if status:
                    print(path.read_text()[-8000:], file=sys.stderr)
                    return status if status > 0 else 128 - status
            time.sleep(0.1)
        return 0
    finally:
        # Also terminate descendants after their group leader exits.
        for _, process, _, _ in jobs:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for _, process, log, _ in jobs:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            log.close()


if __name__ == '__main__':
    def interrupted(number, frame):
        raise SystemExit(128 + number)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    args = sys.argv[2:]
    separator = args.index(':::')
    raise SystemExit(run([args[:separator], args[separator + 1:]], Path(sys.argv[1])))
