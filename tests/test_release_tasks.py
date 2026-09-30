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
        self.write_appcast("dev")
        original_feed = self.appcast.read_bytes()
        with self.assertRaisesRegex(ValueError, "channel"):
            release.promote(self.appcast, self.archive, "1.2.3", "10", self.prefix)
        self.assertEqual(self.appcast.read_bytes(), original_feed)


class BetaResumeTests(unittest.TestCase):
    def test_resumes_only_the_matching_beta(self):
        source = SCRIPT.parent
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("beta-release.sh", "release-config.sh"):
                shutil.copy2(source / name, scripts / name)
            publication = root / "published"
            publish = scripts / "publish-update.sh"
            publish.write_text('#!/bin/bash\nprintf "%s" "$1" > published\n')
            publish.chmod(0o755)
            updates = root / "dist/updates"
            updates.mkdir(parents=True)
            archive = updates / "Fritz-1.2.3.dmg"
            archive.write_bytes(b"existing immutable archive")
            environment = dict(os.environ, FRITZ_VERSION="1.2.3", FRITZ_BUILD_NUMBER="10")
            for channel, build, error in (
                ("beta", "10", None),
                (None, "10", "already on the Release channel"),
                ("beta", "9", "does not match Fritz 1.2.3 (10)"),
            ):
                with self.subTest(channel=channel, build=build):
                    publication.unlink(missing_ok=True)
                    marker = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
                    appcast = updates / "appcast.xml"
                    appcast.write_text(f"""<rss xmlns:sparkle="{release.SPARKLE}"><channel><item>
{marker}<sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
</item></channel></rss>""")
                    original = appcast.read_bytes()
                    result = subprocess.run(["/bin/bash", str(scripts / "beta-release.sh")],
                                            env=environment, capture_output=True, text=True)
                    if error is None:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(publication.read_text(), "beta")
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(error, result.stderr)
                        self.assertFalse(publication.exists())
                    self.assertEqual(appcast.read_bytes(), original)
                    self.assertEqual(archive.read_bytes(), b"existing immutable archive")


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
            for invocation in ("publish-beta", "promote", "retry-promote"):
                with self.subTest(invocation=invocation):
                    commands.unlink(missing_ok=True)
                    uploaded.unlink(missing_ok=True)
                    if invocation == "publish-beta":
                        args = [str(scripts / "publish-update.sh"), "beta"]
                    else:
                        args = [str(scripts / "promote-release.sh")]
                    result = subprocess.run(["/bin/bash", *args], env=environment,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    channel = "beta" if invocation == "publish-beta" else "release"
                    self.assertIn(f"Published Fritz 0.1.2 (3) {channel} update.", result.stdout)
                    item = ET.parse(uploaded).getroot().find('./channel/item')
                    self.assertEqual(item.findtext(f'{{{release.SPARKLE}}}channel') or 'release', channel)
                    self.assertEqual(item.find('enclosure').get(f'{{{release.SPARKLE}}}edSignature'), signature)
                    operations = [json.loads(line) for line in commands.read_text().splitlines()]
                    dmgs = [args for args in operations if "fritz-updates/updates/Fritz-0.1.2.dmg" in args]
                    self.assertEqual(len(dmgs), 1 if channel == "beta" else 0)
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
