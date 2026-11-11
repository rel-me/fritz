"""Run the protocol suites against the app's single-executable layout."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("FRITZ_TEST_BIN_DIR", ROOT / "target/debug")) / "fritz"

with tempfile.TemporaryDirectory(prefix="fritz-bundled-runtime-") as directory:
    binaries = Path(directory)
    # A real copy keeps current_exe() and child lookup inside this bundle,
    # so standalone Cargo harness targets cannot mask a broken alias.
    shutil.copy2(SOURCE, binaries / "fritz")
    for name in ("fritz-harness", "fritz-decision-harness"):
        (binaries / name).symlink_to("fritz")
    environment = dict(os.environ, FRITZ_TEST_BIN_DIR=str(binaries))
    for suite in ("integration.py", "coding_integration.py", "decision_integration.py"):
        subprocess.run([sys.executable, str(ROOT / "tests" / suite)],
                       env=environment, check=True)
