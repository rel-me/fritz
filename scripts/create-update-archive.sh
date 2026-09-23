#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=dist/Fritz.app
test -d "$app" || { echo "error: build the Release app first" >&2; exit 1; }
identity="$(codesign -dv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -z "$identity" ]]; then
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
hdiutil create -quiet -volname Fritz -srcfolder "$app" -format UDZO "$archive"
echo "Created $archive"
