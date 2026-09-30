#!/usr/bin/env python3
"""Select an unused prerelease version and preserve published appcast history."""

import argparse
import os
import plistlib
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def version_tuple(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError(f"invalid release version: {value!r}")
    return tuple(map(int, value.split(".")))


def build_number(value: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError(f"invalid release build number: {value!r}")
    return int(value)


def read_feed(path: Path) -> ET.ElementTree:
    try:
        tree = ET.parse(path)
        if tree.getroot().tag != "rss" or tree.getroot().find("channel") is None:
            raise ValueError("expected an RSS channel")
        return tree
    except (ET.ParseError, ValueError) as error:
        raise ValueError(f"invalid appcast at {path}: {error}") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("published_appcast", type=Path)
    parser.add_argument("--explicit-version", action="store_true")
    parser.add_argument("--explicit-build", action="store_true")
    args = parser.parse_args()
    version = version_tuple(args.version)
    build = build_number(args.build)
    updates = Path("dist/updates")
    appcast = updates / "appcast.xml"
    local = read_feed(appcast) if appcast.exists() else None
    published = read_feed(args.published_appcast) if args.published_appcast.exists() else None
    versions = []
    builds = []
    for tree in (local, published):
        if tree is not None:
            for item in tree.getroot().findall("./channel/item"):
                versions.append(version_tuple(item.findtext(f"{{{SPARKLE}}}shortVersionString", "")))
                builds.append(build_number(item.findtext(f"{{{SPARKLE}}}version", "")))
    for archive in updates.glob("Fritz-*.dmg"):
        versions.append(version_tuple(archive.name.removeprefix("Fritz-").removesuffix(".dmg")))
    plist = Path("dist/Fritz.app/Contents/Info.plist")
    if plist.exists():
        with plist.open("rb") as source:
            info = plistlib.load(source)
        versions.append(version_tuple(info["CFBundleShortVersionString"]))
        builds.append(build_number(info["CFBundleVersion"]))
    if versions and version <= max(versions):
        if args.explicit_version:
            raise ValueError("FRITZ_VERSION must exceed every local and published app version; "
                             "use make publish-beta or make publish-staging to retry a prepared update")
        major, minor, patch = max(versions)
        version = (major, minor, patch + 1)
    if builds and build <= max(builds):
        if args.explicit_build:
            raise ValueError("FRITZ_BUILD_NUMBER must exceed every local and published build number")
        build = max(builds) + 1

    # Retain items from every channel when publishing from a fresh or stale
    # checkout. Preserve promotions from either feed: a stale local Beta item
    # must not demote a published Release, and a pending local promotion survives.
    if published is not None:
        merged = local if local is not None else published
        channel = merged.getroot().find("channel")
        if local is not None:
            identities = {(i.findtext(f"{{{SPARKLE}}}version"),
                           i.findtext(f"{{{SPARKLE}}}shortVersionString")): i
                          for i in channel.findall("item")}
            for item in published.getroot().findall("./channel/item"):
                identity = (item.findtext(f"{{{SPARKLE}}}version"),
                            item.findtext(f"{{{SPARKLE}}}shortVersionString"))
                if identity not in identities:
                    channel.append(item)
                    identities[identity] = item
                elif not item.findtext(f"{{{SPARKLE}}}channel"):
                    channel.remove(identities[identity])
                    channel.append(item)
                    identities[identity] = item
        items = channel.findall("item")
        for item in items:
            channel.remove(item)
        channel.extend(sorted(items, key=lambda i: build_number(
            i.findtext(f"{{{SPARKLE}}}version", "")), reverse=True))
        updates.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=updates, prefix=".appcast.", delete=False) as output:
                temporary = Path(output.name)
                merged.write(output, encoding="utf-8", xml_declaration=True)
            os.replace(temporary, appcast)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    print(".".join(map(str, version)), build)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
