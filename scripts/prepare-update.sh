#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
channel="${1:-}"
case "$channel" in
  release|beta|dev) ;;
  *) echo "error: use make appcast CHANNEL=release, beta, or dev" >&2; exit 64 ;;
esac
prefix="${FRITZ_UPDATE_DOWNLOAD_URL_PREFIX:-}"
homepage="${FRITZ_HOMEPAGE_URL:-}"
if [[ "$prefix" != https://* || "$homepage" != https://* ]]; then
  echo "error: FRITZ_UPDATE_DOWNLOAD_URL_PREFIX and FRITZ_HOMEPAGE_URL must be HTTPS URLs" >&2
  exit 1
fi
tool="dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
test -x "$tool" || { echo "error: pinned Sparkle generate_appcast was not resolved" >&2; exit 1; }
test -d dist/updates || { echo "error: create a signed update archive first" >&2; exit 1; }
version="$(plutil -extract CFBundleShortVersionString raw dist/Fritz.app/Contents/Info.plist)"
archive="dist/updates/Fritz-$version.dmg"
test -f "$archive" || { echo "error: no update archive at $archive" >&2; exit 1; }
temporary_appcast="$(mktemp dist/updates/.appcast.XXXXXX)"
trap 'rm -f "$temporary_appcast"' EXIT
if [[ -f dist/updates/appcast.xml ]]; then
  cp dist/updates/appcast.xml "$temporary_appcast"
fi
args=(-o "$temporary_appcast" --download-url-prefix "$prefix" --link "$homepage")
if [[ "$channel" != release ]]; then args+=(--channel "$channel"); fi
"$tool" "${args[@]}" dist/updates
python3 - "$channel" "$temporary_appcast" "$version" "$prefix" "$archive" <<'PY'
import sys
import os
import xml.etree.ElementTree as ET

channel, path, version, prefix, archive = sys.argv[1:]
item = ET.parse(path).getroot().find('./channel/item')
if item is None:
    raise SystemExit('generated appcast has no update item')
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
actual = item.findtext(f'{sparkle}channel') or 'release'
if actual != channel:
    raise SystemExit(f'generated appcast channel is {actual}, expected {channel}')
enclosure = item.find('enclosure')
if enclosure is None or not enclosure.get(f'{sparkle}edSignature'):
    raise SystemExit('generated appcast item is not signed')
if item.findtext(f'{sparkle}shortVersionString') != version:
    raise SystemExit('generated appcast newest item has the wrong version')
if enclosure.get('url') != f'{prefix.rstrip("/")}/Fritz-{version}.dmg':
    raise SystemExit('generated appcast download URL does not match the archive')
if enclosure.get('length') != str(os.path.getsize(archive)):
    raise SystemExit('generated appcast length does not match the archive')
PY
mv -f "$temporary_appcast" dist/updates/appcast.xml
trap - EXIT
echo "Prepared signed $channel appcast in dist/updates/appcast.xml"
