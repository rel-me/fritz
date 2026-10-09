"""Exercise local reuse through the CLI with real signed fixture bundles."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin', 'requires codesign and Xcode')
class AppReuseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=os.environ.get('FRITZ_BUILD_ROOT'))
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        scripts = self.root / 'scripts'
        scripts.mkdir()
        shutil.copy2(ROOT / 'scripts/app-build-reuse.py', scripts)
        self.script = scripts / 'app-build-reuse.py'
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.source = self.root / 'source.txt'
        self.source.write_text('before')
        (self.root / '.gitignore').write_text('/dist/\n')
        subprocess.run(['git', '-C', str(self.root), 'add', 'source.txt', 'scripts', '.gitignore'], check=True)
        self.app = self.root / 'dist/Fritz.app'
        resources = self.app / 'Contents/Resources'
        resources.mkdir(parents=True)
        executable = self.app / 'Contents/MacOS/Fritz'
        executable.parent.mkdir()
        for path in [executable, *(resources / name for name in
                      ('fritz', 'fritz-harness', 'fritz-decision-harness'))]:
            shutil.copyfile('/usr/bin/true', path)
            path.chmod(0o755)
            subprocess.run(['codesign', '--force', '--sign', '-', str(path)],
                           check=True, capture_output=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.fritz.fixture', 'CFBundleExecutable': 'Fritz',
            'CFBundleShortVersionString': '0.1.1', 'CFBundleVersion': '2',
            'CFBundlePackageType': 'APPL'}))
        subprocess.run(['codesign', '--force', '--sign', '-', str(self.app)],
                       check=True, capture_output=True)
        self.environment = dict(os.environ, FRITZ_BUILD_CACHE_ACTIVE=str(self.root),
                                FRITZ_DISTRIBUTION='0')
        self.args = ['configuration=release', 'name=Fritz', 'bundle=dev.fritz.fixture',
                     'version=0.1.1', 'build_number=2', 'identity=-', 'feed=', 'public_key=']

    def invoke(self, action, expected=0, **environment):
        result = subprocess.run([sys.executable, str(self.script), action,
                                 str(self.app), *self.args],
                                env=dict(self.environment, **environment), capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_reuses_signed_bundle_but_byte_and_flag_changes_invalidate(self):
        self.invoke('check', 10)
        self.invoke('record')
        self.assertIn('Reusing verified unchanged', self.invoke('check').stdout)
        state = self.root / 'dist/.build-reuse-release.json'
        original = state.read_bytes()
        times = self.source.stat()
        self.source.write_text('edited')  # same size, restored timestamps
        os.utime(self.source, ns=(times.st_atime_ns, times.st_mtime_ns))
        self.invoke('record', 1)  # a mid-build edit must never publish state
        self.assertEqual(state.read_bytes(), original)
        self.invoke('check', 10)
        self.source.write_text('before')
        self.invoke('check')
        self.invoke('check', 10, RUSTFLAGS='-C opt-level=1')

    def test_rejects_mutated_bundle_and_distribution_reuse(self):
        self.invoke('check', 10)
        self.invoke('record')
        (self.app / 'Contents/Resources/unexpected.txt').write_text('changed')
        self.assertIn('contents changed', self.invoke('check', 1).stderr)
        self.assertIn('locked local build', self.invoke('check', 1, FRITZ_DISTRIBUTION='1').stderr)


if __name__ == '__main__':
    unittest.main()
