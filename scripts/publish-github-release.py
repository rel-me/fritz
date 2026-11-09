#!/usr/bin/env python3
"""Publish the prepared Fritz DMG to GitHub, preserving immutable assets on retry."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


REPOSITORY = "rel-me/fritz"


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


def api(path):
    result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/{path}".rstrip("/")],
                            text=True, capture_output=True)
    if result.returncode:
        if "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def check_access():
    repository = api("")
    if not repository or not repository.get("permissions", {}).get("push"):
        raise RuntimeError(f"GitHub publication requires write access to {REPOSITORY}; run gh auth login.")


def find_release(tag):
    result = subprocess.run(["gh", "release", "view", tag, "--repo", REPOSITORY,
                             "--json", "isDraft,isPrerelease,targetCommitish,assets"],
                            text=True, capture_output=True)
    if result.returncode:
        if result.stderr.strip() == "release not found":
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def file_digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def publish(channel):
    with Path("dist/Fritz.app/Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("The staged app needs a semantic version and a positive build number.")
    archive = Path(f"dist/updates/Fritz-{version}.dmg")
    source = json.loads(archive.with_suffix(".source.json").read_text())
    if source["version"] != version or source["build"] != build:
        raise ValueError("Release source metadata does not match the staged app; rebuild the archive.")
    commit = source["commit"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Release source metadata needs a full Git commit SHA.")
    tag = f"v{version}"
    tagged = api(f"commits/{tag}")
    if tagged and tagged["sha"] != commit:
        raise ValueError(f"GitHub tag {tag} points to a different source commit.")
    release = find_release(tag)
    if release and release["isDraft"] and not tagged and release["targetCommitish"] != commit:
        raise ValueError(f"GitHub draft {tag} targets a different source commit.")
    digest = file_digest(archive)
    with tempfile.TemporaryDirectory(prefix="fritz-github-release-") as directory:
        checksum = Path(directory) / "SHA256SUMS.txt"
        checksum.write_text(f"{digest}  {archive.name}\n")
        files = [archive, checksum, archive.with_suffix(".source.json")]
        existing = {asset["name"]: asset for asset in release["assets"]} if release else {}
        for file in files:
            if file.name in existing:
                expected = "sha256:" + file_digest(file)
                if existing[file.name].get("digest") != expected:
                    raise ValueError(f"GitHub asset {file.name} differs from the prepared artifact; refusing to overwrite it.")
        if not release:
            notes = Path(directory) / "notes.md"
            notes.write_text(
                f"Fritz {version} (build {build}). Source: `{commit}`.\n\n"
                "Download the Developer ID signed, notarized DMG and drag Fritz to Applications. "
                "Requires macOS 15 or later on Apple silicon. Model weights download separately on request.\n\n"
                "`SHA256SUMS.txt` contains the installer checksum.\n")
            gh("release", "create", tag, "--repo", REPOSITORY, "--draft", "--target", commit,
               "--title", f"Fritz {version}", "--notes-file", str(notes),
               f"--prerelease={'true' if channel == 'beta' else 'false'}")
        missing = [str(file) for file in files if file.name not in existing]
        if missing:
            gh("release", "upload", tag, *missing, "--repo", REPOSITORY)
        uploaded = {asset['name']: asset for asset in find_release(tag)['assets']}
        for file in files:
            if uploaded.get(file.name, {}).get('digest') != 'sha256:' + file_digest(file):
                raise ValueError(f"GitHub upload verification failed for {file.name}; retry publication.")
        # Retrying a completed Release must neither demote it nor change latest selection.
        if release and not release["isDraft"] and not release["isPrerelease"]:
            print(f"GitHub {tag} is already a Release; verified its assets.")
            return
        gh("release", "edit", tag, "--repo", REPOSITORY, "--draft=false",
           f"--prerelease={'true' if channel == 'beta' else 'false'}",
           f"--latest={'false' if channel == 'beta' else 'true'}")
    print(f"Published GitHub {channel}: https://github.com/{REPOSITORY}/releases/tag/{tag}")


def inventory():
    pages = json.loads(gh("api", "--paginate", "--slurp",
                          f"repos/{REPOSITORY}/releases?per_page=100"))
    records = []
    for page in pages:
        for release in page:
            tag = release['tag_name']
            if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
                continue
            filename = f"Fritz-{tag[1:]}.source.json"
            if not any(asset['name'] == filename for asset in release['assets']):
                raise ValueError(f"GitHub {tag} has no {filename}; finish or reconcile that release before building another Beta.")
            source = json.loads(gh('release', 'download', tag, '--repo', REPOSITORY,
                                   '--pattern', filename, '--output', '-'))
            if source['version'] != tag[1:]:
                raise ValueError(f"GitHub {tag} source metadata has a different version.")
            records.append(source)
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("channel", choices=["beta", "release"])
    parser.add_argument("--check", action="store_true", help="Check GitHub access before building or publishing.")
    parser.add_argument("--inventory", type=Path, help="Save published GitHub versions/builds for version selection.")
    args = parser.parse_args()
    check_access()
    if args.inventory:
        args.inventory.write_text(json.dumps(inventory()) + '\n')
    elif not args.check:
        publish(args.channel)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"GitHub release publication failed: {error}")
