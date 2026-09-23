#!/usr/bin/env python3
"""Promote the current signed beta update without rebuilding its archive."""

import base64
import os
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def validated_item(tree: ET.ElementTree, archive: Path, version: str,
                   build: str, prefix: str) -> tuple[ET.Element, str]:
    items = tree.getroot().findall("./channel/item")
    matches = [item for item in items if item.findtext(f"{{{SPARKLE}}}shortVersionString") == version
               and item.findtext(f"{{{SPARKLE}}}version") == build]
    if len(matches) != 1:
        raise ValueError(f"expected one appcast item for Fritz {version} ({build})")
    item = matches[0]
    channel = item.find(f"{{{SPARKLE}}}channel")
    if channel is not None and channel.text != "beta":
        raise ValueError("current update is not on the beta or Release channel")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("update has no archive enclosure")
    expected_url = f"{prefix.rstrip('/')}/Fritz-{version}.dmg"
    if enclosure.get("url") != expected_url:
        raise ValueError("update download URL does not match the archive")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("update archive length does not match the appcast")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature")
    if not signature:
        raise ValueError("update archive has no Sparkle signature")
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("invalid Sparkle signature length")
    except ValueError as error:
        raise ValueError("invalid Sparkle signature") from error
    return item, signature


def promote(appcast: Path, archive: Path, version: str, build: str, prefix: str) -> bool:
    tree = ET.parse(appcast)
    item, _ = validated_item(tree, archive, version, build, prefix)
    channel = item.find(f"{{{SPARKLE}}}channel")
    if channel is None:
        return False
    item.remove(channel)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=appcast.parent, prefix=".appcast.",
                                         suffix=".xml", delete=False) as output:
            temporary = Path(output.name)
            tree.write(output, encoding="utf-8", xml_declaration=True)
        os.replace(temporary, appcast)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return True


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    updates = root / "dist/updates"
    appcast = updates / "appcast.xml"
    plist = root / "dist/Fritz.app/Contents/Info.plist"
    prefix = os.environ.get("FRITZ_UPDATE_DOWNLOAD_URL_PREFIX", "")
    if not prefix.startswith("https://"):
        raise ValueError("FRITZ_UPDATE_DOWNLOAD_URL_PREFIX must be an HTTPS URL")
    with plist.open("rb") as source:
        info = plistlib.load(source)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    archive = updates / f"Fritz-{version}.dmg"
    if not archive.is_file():
        raise ValueError(f"missing {archive}")
    # Verify the signed archive before changing its channel. The signature covers
    # archive bytes, so promotion does not sign or rebuild the DMG.
    _, signature = validated_item(ET.parse(appcast), archive, version, build, prefix)
    tool = root / "dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
    subprocess.run([str(tool), "--verify", str(archive), signature], check=True)
    subprocess.run(["xcrun", "stapler", "validate", str(archive)], check=True)
    changed = promote(appcast, archive, version, build, prefix)
    state = "Promoted" if changed else "Already promoted"
    print(f"{state} Fritz {version} ({build}) to Release in {appcast}.")
    print(f"Publish the updated {appcast}; keep {archive} at its existing URL.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
