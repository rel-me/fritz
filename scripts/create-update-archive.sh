#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=dist/Fritz.app
test -d "$app" || { echo "error: build the Release app first" >&2; exit 1; }
identity="$(codesign -dvvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ "$identity" != "Developer ID Application:"* ]]; then
  echo "error: Sparkle distribution needs a Developer ID signed Release app" >&2
  exit 1
fi
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: set FRITZ_VERSION and a monotonic FRITZ_BUILD_NUMBER" >&2
  exit 1
fi
mkdir -p dist/updates
archive="dist/updates/Fritz-$version.dmg"
if [[ -e "$archive" ]]; then
  echo "error: update archive already exists at $archive" >&2
  exit 1
fi
# Keep release-only Python tools in the build cache, with locked wheel hashes.
python_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
tools="${FRITZ_BUILD_ROOT:-$HOME/Builds/Fritz}/release-tools/dmg-python-$python_version"
requirements="$PWD/scripts/dmg-requirements.txt"
if [[ ! -x "$tools/bin/python3" ]]; then
  python3 -m venv "$tools"
fi
if ! cmp -s "$requirements" "$tools/.requirements"; then
  "$tools/bin/python3" -m pip install --disable-pip-version-check --index-url https://pypi.org/simple \
    --require-hashes --only-binary=:all: -r "$requirements"
  cp "$requirements" "$tools/.requirements"
fi
work="$(mktemp -d "$PWD/dist/updates/.dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$tools/bin/python3" - "$work/installer.dmg" <<'PYBUILD'
import signal
import sys
import dmgbuild

signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
dmgbuild.build_dmg(sys.argv[1], 'Fritz', settings_file='scripts/dmg-settings.py',
                   detach_retries=3)
PYBUILD
hdiutil verify "$work/installer.dmg" >/dev/null
mv "$work/installer.dmg" "$archive"
echo "Created $archive"
