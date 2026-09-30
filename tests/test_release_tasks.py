import base64
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/promote-update.py"
spec = importlib.util.spec_from_file_location("promote_update", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.archive = root / "Fritz-1.2.3.dmg"
        self.archive.write_bytes(b"unchanged release archive")
        self.appcast = root / "appcast.xml"
        self.prefix = "https://example.com/updates"
        self.signature = base64.b64encode(bytes(range(64))).decode()
        self.write_appcast("beta")

    def write_appcast(self, channel):
        marker = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
        self.appcast.write_text(f"""<?xml version="1.0"?>
<rss xmlns:sparkle="{release.SPARKLE}"><channel>
<item><sparkle:version>9</sparkle:version><sparkle:shortVersionString>1.2.2</sparkle:shortVersionString></item>
<item>{marker}<sparkle:version>10</sparkle:version>
<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
<enclosure url="{self.prefix}/Fritz-1.2.3.dmg" length="{self.archive.stat().st_size}"
 sparkle:edSignature="{self.signature}"/></item>
</channel></rss>""")

    def test_promotes_only_current_item_without_touching_archive(self):
        original_archive = self.archive.read_bytes()
        self.assertTrue(release.promote(self.appcast, self.archive, "1.2.3", "10", self.prefix))
        self.assertEqual(self.archive.read_bytes(), original_archive)
        tree = ET.parse(self.appcast)
        items = tree.getroot().findall("./channel/item")
        self.assertEqual(len(items), 2)
        self.assertIsNone(items[1].find(f"{{{release.SPARKLE}}}channel"))
        self.assertEqual(items[1].find("enclosure").get(f"{{{release.SPARKLE}}}edSignature"),
                         self.signature)
        self.assertFalse(release.promote(self.appcast, self.archive, "1.2.3", "10", self.prefix))

    def test_rejects_mismatched_archive_without_changing_feed(self):
        original_feed = self.appcast.read_bytes()
        self.archive.write_bytes(b"different length")
        with self.assertRaisesRegex(ValueError, "length"):
            release.promote(self.appcast, self.archive, "1.2.3", "10", self.prefix)
        self.assertEqual(self.appcast.read_bytes(), original_feed)

    def test_rejects_wrong_channel_without_changing_feed(self):
        self.write_appcast("staging")
        original_feed = self.appcast.read_bytes()
        with self.assertRaisesRegex(ValueError, "channel"):
            release.promote(self.appcast, self.archive, "1.2.3", "10", self.prefix)
        self.assertEqual(self.appcast.read_bytes(), original_feed)


class PrereleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="fritz prerelease ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("prerelease.sh", "release-config.sh", "build-cache.py", "next-release.py"):
            shutil.copy2(SCRIPT.parent / name, scripts / name)
        (self.root / "Cargo.toml").write_text('version = "0.1.1"\n')
        (self.root / "app").mkdir()
        (self.root / "app/project.yml").write_text('CURRENT_PROJECT_VERSION: 2\n')
        self.updates = self.root / "dist/updates"
        self.updates.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                                FRITZ_BUILD_ROOT=str(self.root / "cache"))
        for key in ("FRITZ_VERSION", "FRITZ_BUILD_NUMBER", "FRITZ_DISTRIBUTION",
                    "FRITZ_BUILD_CACHE_ACTIVE"):
            self.environment.pop(key, None)
        derived = subprocess.check_output(
            [sys.executable, str(scripts / "build-cache.py"), "--derived-data"],
            env=self.environment, text=True).strip()
        key_tool = Path(derived) / "SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
        key_tool.parent.mkdir(parents=True)
        self.executable(key_tool, "import os\nprint(os.environ['FRITZ_SPARKLE_PUBLIC_ED_KEY'])\n")
        website = self.root / "website"
        (website / "node_modules").mkdir(parents=True)
        (website / "package-lock.json").write_text('{}')
        (website / "node_modules/.package-lock.json").write_text('{}')
        self.remote = self.root / "remote.xml"
        self.remote.write_text(self.feed(("0.1.2", "3", "beta")))
        self.executable(self.bin / "curl", """import os, pathlib, shutil, sys
if os.environ.get('CURL_FAILURE'):
    print('curl: timed out', file=sys.stderr)
    sys.exit(28)
if pathlib.Path('remote.xml').exists():
    shutil.copyfile('remote.xml', sys.argv[sys.argv.index('--output') + 1])
    print('200', end='')
else:
    print(os.environ.get('HTTP_STATUS', '404'), end='')
""")
        self.executable(self.bin / "codesign", "import sys\nprint('Authority=Developer ID Application: Test', file=sys.stderr)\n")
        for name in ("xcrun", "npx"):
            self.executable(self.bin / name, "")
        self.executable(scripts / "build-app.sh", """import json, os, plistlib
from pathlib import Path
version, build = os.environ['FRITZ_VERSION'], os.environ['FRITZ_BUILD_NUMBER']
Path('built.json').write_text(json.dumps([version, build]))
contents = Path('dist/Fritz.app/Contents')
contents.mkdir(parents=True, exist_ok=True)
(contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': version, 'CFBundleVersion': build}))
""")
        self.executable(scripts / "create-update-archive.sh", """import os
from pathlib import Path
Path('dist/updates/Fritz-' + os.environ['FRITZ_VERSION'] + '.dmg').write_bytes(b'new archive')
""")
        self.executable(scripts / "prepare-update.sh", """import json, sys
from pathlib import Path
Path('prepared.json').write_text(json.dumps([sys.argv[1], Path('dist/updates/appcast.xml').read_text() if Path('dist/updates/appcast.xml').exists() else None]))
""")
        self.executable(scripts / "publish-update.sh", "import sys\nfrom pathlib import Path\nPath('published').write_text(sys.argv[1])\n")

    def executable(self, path, code):
        path.write_text(f"#!{sys.executable}\n" + code)
        path.chmod(0o755)

    def feed(self, *items):
        records = ''.join(f"<item><sparkle:version>{build}</sparkle:version>"
                          f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
                          + (f"<sparkle:channel>{channel}</sparkle:channel>" if channel else "") + "</item>"
                          for version, build, channel in items)
        return f'<rss xmlns:sparkle="{release.SPARKLE}"><channel>{records}</channel></rss>'

    def run_release(self, channel, **overrides):
        return subprocess.run(["/bin/bash", str(self.root / "scripts/prerelease.sh"), channel],
                              env=dict(self.environment, **overrides), capture_output=True, text=True)

    def test_next_version_across_local_and_published_channels(self):
        # A stale source version and mismatched appcast previously stopped staging.
        old = self.updates / "Fritz-0.1.1.dmg"
        old.write_bytes(b'immutable old archive')
        (self.updates / "appcast.xml").write_text(self.feed(("0.1.2", "3", "beta")))
        self.remote.write_text(self.feed(("0.1.4", "5", None), ("0.1.3", "4", "staging"),
                                         ("0.1.2", "3", None)))
        for channel, expected in (("staging", ["0.1.5", "6"]), ("beta", ["0.1.6", "7"])):
            with self.subTest(channel=channel):
                result = self.run_release(channel)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((self.root / "built.json").read_text()), expected)
                self.assertEqual((self.root / "published").read_text(), channel)
                prepared_channel, feed = json.loads((self.root / "prepared.json").read_text())
                self.assertEqual(prepared_channel, channel)
                items = ET.fromstring(feed).findall('./channel/item')
                self.assertEqual({i.findtext(f'{{{release.SPARKLE}}}version') for i in items}, {'3', '4', '5'})
                self.assertIsNone(next(i for i in items if i.findtext(
                    f'{{{release.SPARKLE}}}version') == '3').find(f'{{{release.SPARKLE}}}channel'))
                self.assertEqual(old.read_bytes(), b'immutable old archive')

    def test_clean_checkout_and_first_publication(self):
        for remote, expected in ((True, ["0.1.3", "4"]), (False, ["0.1.1", "2"])):
            with self.subTest(remote=remote):
                if not remote:
                    self.remote.unlink()
                    shutil.rmtree(self.root / "dist")
                    self.updates.mkdir(parents=True)
                result = self.run_release("beta")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((self.root / "built.json").read_text()), expected)

    def test_explicit_version_and_build_overrides(self):
        result = self.run_release("staging", FRITZ_VERSION="1.0.0", FRITZ_BUILD_NUMBER="20")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / "built.json").read_text()), ["1.0.0", "20"])

    def test_higher_source_defaults_and_partial_overrides(self):
        (self.root / "Cargo.toml").write_text('version = "0.2.0"\n')
        (self.root / "app/project.yml").write_text('CURRENT_PROJECT_VERSION: 10\n')
        for overrides, expected in (({}, ["0.2.0", "10"]),
                                    ({"FRITZ_VERSION": "0.3.0"}, ["0.3.0", "11"]),
                                    ({"FRITZ_BUILD_NUMBER": "20"}, ["0.3.1", "20"])):
            with self.subTest(overrides=overrides):
                result = self.run_release("beta", **overrides)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((self.root / "built.json").read_text()), expected)

    def test_rejects_collisions_and_unreadable_feed_before_building(self):
        for overrides, error in (
            ({"FRITZ_VERSION": "0.1.2"}, "FRITZ_VERSION"),
            ({"FRITZ_BUILD_NUMBER": "3"}, "FRITZ_BUILD_NUMBER"),
            ({"CURL_FAILURE": "1"}, "curl"),
            ({"HTTP_STATUS": "503"}, "HTTP 503"),
            ({}, "appcast"),
        ):
            with self.subTest(overrides=overrides):
                if not overrides:
                    self.remote.write_text('invalid XML')
                elif "HTTP_STATUS" in overrides:
                    self.remote.unlink()
                result = self.run_release("staging", **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertFalse((self.root / "built.json").exists())
                self.assertFalse((self.root / "published").exists())


class PublicationTests(unittest.TestCase):
    def test_publishes_staged_version_and_retries_promotion_without_build_overrides(self):
        with tempfile.TemporaryDirectory(prefix="fritz publication ") as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("publish-update.sh", "promote-release.sh", "promote-update.py",
                         "release-config.sh", "build-cache.py"):
                shutil.copy2(SCRIPT.parent / name, scripts / name)
            (root / "Cargo.toml").write_text('version = "0.1.1"\n')
            (root / "app").mkdir()
            (root / "app/project.yml").write_text('CURRENT_PROJECT_VERSION: 2\n')
            contents = root / "dist/Fritz.app/Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "3",
            }))
            updates = root / "dist/updates"
            updates.mkdir()
            archive = updates / "Fritz-0.1.2.dmg"
            archive.write_bytes(b"immutable notarized archive")
            (updates / "Fritz-0.1.1.dmg").write_bytes(b"previous release")
            signature = base64.b64encode(bytes(range(64))).decode()
            appcast = updates / "appcast.xml"
            appcast.write_text(f"""<rss xmlns:sparkle="{release.SPARKLE}"><channel><item>
<sparkle:channel>beta</sparkle:channel><sparkle:version>3</sparkle:version>
<sparkle:shortVersionString>0.1.2</sparkle:shortVersionString>
<enclosure url="https://fritz.rel.me/updates/Fritz-0.1.2.dmg"
 length="{archive.stat().st_size}" sparkle:edSignature="{signature}"/>
</item></channel></rss>""")
            website = root / "website"
            (website / "node_modules").mkdir(parents=True)
            (website / "wrangler.jsonc").write_text(json.dumps({
                "routes": [{"pattern": "fritz.rel.me"}],
            }))
            (website / "package-lock.json").write_text('{}')
            (website / "node_modules/.package-lock.json").write_text('{}')
            bin_dir = root / "bin"
            bin_dir.mkdir()
            environment = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                               FRITZ_BUILD_ROOT=str(root / "cache"),
                               FRITZ_RELEASE_BASE_URL="https://fritz.rel.me",
                               FRITZ_UPDATE_DOWNLOAD_URL_PREFIX="https://fritz.rel.me/updates",
                               FRITZ_SPARKLE_FEED_URL="https://fritz.rel.me/appcast.xml")
            for name in ("FRITZ_VERSION", "FRITZ_BUILD_NUMBER"):
                environment.pop(name, None)
            derived = subprocess.check_output(
                [sys.executable, str(scripts / "build-cache.py"), "--derived-data"],
                env=environment, text=True).strip()
            sign_update = Path(derived) / "SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
            sign_update.parent.mkdir(parents=True)

            def executable(path, code):
                path.write_text(f"#!{sys.executable}\n" + code)
                path.chmod(0o755)

            executable(sign_update, f"import sys\nif '--verify' not in sys.argv: print({signature!r})\n")
            for name in ("xcrun", "codesign", "hdiutil"):
                executable(bin_dir / name, "")
            uploaded = root / "uploaded.xml"
            commands = root / "uploads.jsonl"
            executable(bin_dir / "npx", f"""import json, pathlib, shutil, sys
with open({str(commands)!r}, 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if 'fritz-updates/appcast.xml' in sys.argv:
    source = next(arg.removeprefix('--file=') for arg in sys.argv if arg.startswith('--file='))
    shutil.copyfile(source, {str(uploaded)!r})
""")
            executable(bin_dir / "curl", f"""import shutil, sys
if '-o' in sys.argv:
    shutil.copyfile({str(uploaded)!r}, sys.argv[sys.argv.index('-o') + 1])
else:
    print('Content-Length: {archive.stat().st_size}')
""")
            original_archive = archive.read_bytes()
            for invocation in ("publish-staging", "publish-beta", "promote", "retry-promote"):
                with self.subTest(invocation=invocation):
                    commands.unlink(missing_ok=True)
                    uploaded.unlink(missing_ok=True)
                    if invocation.startswith("publish-"):
                        channel = invocation.removeprefix("publish-")
                        tree = ET.parse(appcast)
                        tree.getroot().find(f'./channel/item/{{{release.SPARKLE}}}channel').text = channel
                        tree.write(appcast)
                        args = [str(scripts / "publish-update.sh"), channel]
                    else:
                        args = [str(scripts / "promote-release.sh")]
                    result = subprocess.run(["/bin/bash", *args], env=environment,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    channel = invocation.removeprefix("publish-") if invocation.startswith("publish-") else "release"
                    self.assertIn(f"Published Fritz 0.1.2 (3) {channel} update.", result.stdout)
                    item = ET.parse(uploaded).getroot().find('./channel/item')
                    self.assertEqual(item.findtext(f'{{{release.SPARKLE}}}channel') or 'release', channel)
                    self.assertEqual(item.find('enclosure').get(f'{{{release.SPARKLE}}}edSignature'), signature)
                    operations = [json.loads(line) for line in commands.read_text().splitlines()]
                    dmgs = [args for args in operations if "fritz-updates/updates/Fritz-0.1.2.dmg" in args]
                    self.assertEqual(len(dmgs), 1 if channel != "release" else 0)
                    self.assertEqual(archive.read_bytes(), original_archive)
            # Replacing the staged app must not let an unrelated artifact publish.
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "4",
            }))
            commands.unlink()
            result = subprocess.run(["/bin/bash", str(scripts / "publish-update.sh"), "release"],
                                    env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("appcast build number is '3', expected '4'", result.stderr)
            self.assertFalse(commands.exists())


if __name__ == "__main__":
    unittest.main()
