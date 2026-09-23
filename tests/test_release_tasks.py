import base64
import importlib.util
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


if __name__ == "__main__":
    unittest.main()
