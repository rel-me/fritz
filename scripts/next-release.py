#!/usr/bin/env python3
"""Select the next Fritz update and preserve published appcast history."""

import argparse
import json
import os
import plistlib
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def parse_version(value: str) -> tuple[tuple[int, int, int], str | None, int]:
    match = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+)(?:-(beta|staging)\.([1-9][0-9]*))?", value)
    if not match:
        raise ValueError(f"invalid release version: {value!r}")
    base, channel, sequence = match.groups()
    return tuple(map(int, base.split("."))), channel, int(sequence or 0)


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


def next_prerelease(base, channel, versions, explicit):
    numeric = max((base for base, suffix, _ in versions if suffix is None), default=None)
    minimum = max((known for known, _, _ in versions), default=base)
    if numeric == minimum:
        major, minor, patch = numeric
        minimum = (major, minor, patch + 1)
    if explicit and base < minimum:
        raise ValueError("FRITZ_VERSION must be at least the next available release base; "
                         "use make publish-beta or make publish-staging to retry a prepared update")
    base = max(base, minimum)
    sequence = max((number for known, suffix, number in versions
                    if (known, suffix) == (base, channel)), default=0) + 1
    return ".".join(map(str, base)) + f"-{channel}.{sequence}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("published_appcast", type=Path)
    parser.add_argument("--channel", choices=["beta", "staging", "release"], required=True)
    parser.add_argument("--explicit-version", action="store_true")
    parser.add_argument("--explicit-build", action="store_true")
    parser.add_argument("--github-inventory", type=Path)
    args = parser.parse_args()
    base, suffix, _ = parse_version(args.version)
    if suffix is not None:
        raise ValueError("FRITZ_VERSION must be a three-part release base")
    if args.channel == "release" and args.explicit_version:
        raise ValueError("make promote selects the version from the published Beta; remove FRITZ_VERSION")
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
                versions.append(parse_version(item.findtext(f"{{{SPARKLE}}}shortVersionString", "")))
                builds.append(build_number(item.findtext(f"{{{SPARKLE}}}version", "")))
    if args.github_inventory:
        for source in json.loads(args.github_inventory.read_text()):
            versions.append(parse_version(source['version']))
            builds.append(build_number(source['build']))
    for directory in (updates, updates / "old_updates"):
        for archive in directory.glob("Fritz-[0-9]*.dmg"):
            versions.append(parse_version(archive.stem.removeprefix("Fritz-")))
    for record in updates.glob("Fritz-[0-9]*.source.json"):
        source = json.loads(record.read_text())
        versions.append(parse_version(source['version']))
        builds.append(build_number(source['build']))
    plist = Path("dist/Fritz.app/Contents/Info.plist")
    if plist.exists():
        with plist.open("rb") as source:
            info = plistlib.load(source)
        builds.append(build_number(info["CFBundleVersion"]))
    if args.channel == "release":
        items = published.getroot().findall("./channel/item") if published is not None else []
        betas = [(build_number(item.findtext(f"{{{SPARKLE}}}version", "")),
                  item.findtext(f"{{{SPARKLE}}}shortVersionString", ""))
                 for item in items if item.findtext(f"{{{SPARKLE}}}channel") == "beta"]
        if not betas:
            raise ValueError("No published Beta to promote.")
        beta_build, beta_version = max(betas)
        base, suffix, _ = parse_version(beta_version)
        if suffix is None:
            if any(build_number(item.findtext(f"{{{SPARKLE}}}version", "")) > beta_build
                   for item in items if not item.findtext(f"{{{SPARKLE}}}channel")):
                raise ValueError("A newer Release is already published; build a new Beta before promoting")
            print(f"legacy {beta_version} {beta_build}")
            return
        if suffix != "beta":
            raise ValueError(f"invalid published Beta version: {beta_version}")
        if any(known >= base for known, suffix, _ in versions if suffix is None):
            raise ValueError("An equal or newer Release version is already reserved; "
                             "use make publish-release to retry a prepared Release")
        version = ".".join(map(str, base))
    else:
        version = next_prerelease(base, args.channel, versions, args.explicit_version)
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
    print(version, build)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
