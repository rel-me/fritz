#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export FRITZ_DISTRIBUTION=1
source scripts/release-config.sh

channel="${1:-}"
case "$channel" in
  beta|release) ;;
  *) echo "error: publish-update.sh requires beta or release" >&2; exit 64 ;;
esac

archive="dist/updates/Fritz-$FRITZ_VERSION.dmg"
appcast="dist/updates/appcast.xml"
test -f "$archive" || { echo "error: missing $archive" >&2; exit 1; }
test -f "$appcast" || { echo "error: missing $appcast" >&2; exit 1; }
test -d dist/Fritz.app || { echo "error: missing dist/Fritz.app" >&2; exit 1; }

python3 - "$appcast" "$archive" "$channel" "$FRITZ_VERSION" \
  "$FRITZ_BUILD_NUMBER" "$FRITZ_UPDATE_DOWNLOAD_URL_PREFIX" \
  "$FRITZ_RELEASE_BASE_URL" "$FRITZ_SPARKLE_FEED_URL" <<'PY'
import json
import os
import sys
import urllib.parse
import xml.etree.ElementTree as ET

appcast, archive, channel, version, build, prefix, base, feed = sys.argv[1:]
config = json.load(open('website/wrangler.jsonc', encoding='utf-8'))
hostname = urllib.parse.urlparse(base).hostname
if base != f'https://{hostname}' or config['routes'][0]['pattern'] != hostname:
    raise SystemExit('release URL must match the Fritz Worker custom domain')
if feed != f'{base}/appcast.xml' or prefix != f'{base}/updates':
    raise SystemExit('Fritz feed and download URLs must use the Worker domain')
item = ET.parse(appcast).getroot().find('./channel/item')
if item is None:
    raise SystemExit('appcast has no update item')
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
enclosure = item.find('enclosure')
if enclosure is None:
    raise SystemExit('appcast item has no enclosure')
expected_url = f'{prefix.rstrip("/")}/Fritz-{version}.dmg'
checks = (
    (item.findtext(f'{sparkle}shortVersionString'), version, 'version'),
    (item.findtext(f'{sparkle}version'), build, 'build number'),
    (item.findtext(f'{sparkle}channel') or 'release', channel, 'channel'),
    (enclosure.get('url'), expected_url, 'download URL'),
    (enclosure.get('length'), str(os.path.getsize(archive)), 'archive length'),
)
for actual, expected, label in checks:
    if actual != expected:
        raise SystemExit(f'appcast {label} is {actual!r}, expected {expected!r}')
if not enclosure.get(f'{sparkle}edSignature'):
    raise SystemExit('appcast update is unsigned')
PY

sign_update="dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
test -x "$sign_update" || { echo "error: pinned Sparkle sign_update is unavailable" >&2; exit 1; }
actual_signature="$("$sign_update" --account "$FRITZ_SPARKLE_KEY_ACCOUNT" -p "$archive")"
expected_signature="$(python3 - "$appcast" <<'PY'
import sys
import xml.etree.ElementTree as ET
item = ET.parse(sys.argv[1]).getroot().find('./channel/item/enclosure')
print(item.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'))
PY
)"
[[ "$actual_signature" == "$expected_signature" ]] || {
  echo "error: Sparkle signature does not match $archive" >&2; exit 1;
}
hdiutil verify "$archive" >/dev/null
xcrun stapler validate "$archive" >/dev/null
codesign --verify --deep --strict dist/Fritz.app

if [[ ! -f website/node_modules/.package-lock.json ||
      website/package-lock.json -nt website/node_modules/.package-lock.json ]]; then
  npm --prefix website ci
fi

(
  cd website
  npx --no-install wrangler deploy
  if [[ "$channel" == beta ]]; then
    npx --no-install wrangler r2 object put \
      "fritz-updates/updates/Fritz-$FRITZ_VERSION.dmg" --remote \
      --file="../$archive" --content-type=application/x-apple-diskimage \
      --content-disposition="attachment; filename=\"Fritz-$FRITZ_VERSION.dmg\"" \
      --cache-control='public, max-age=31536000, immutable'
  fi
  npx --no-install wrangler r2 object put fritz-updates/appcast.xml --remote \
    --file="../$appcast" --content-type=application/xml \
    --cache-control=no-store
)

live_appcast="$(mktemp "${TMPDIR:-/tmp}/fritz-appcast.XXXXXX")"
trap 'rm -f "$live_appcast"' EXIT
curl --fail --silent --show-error --location --retry 5 \
  "$FRITZ_SPARKLE_FEED_URL" -o "$live_appcast"
cmp "$appcast" "$live_appcast" || {
  echo "error: live Fritz appcast differs from the signed local appcast" >&2; exit 1;
}
live_headers="$(curl --fail --silent --show-error --head \
  "$FRITZ_UPDATE_DOWNLOAD_URL_PREFIX/Fritz-$FRITZ_VERSION.dmg")"
live_length="$(printf '%s\n' "$live_headers" | tr -d '\r' | awk '
  tolower($1) == "content-length:" { value = $2 }
  END { print value }
')"
[[ "$live_length" == "$(stat -f %z "$archive")" ]] || {
  echo "error: live Fritz archive length differs from $archive" >&2; exit 1;
}
echo "Published Fritz $FRITZ_VERSION ($FRITZ_BUILD_NUMBER) $channel update."
