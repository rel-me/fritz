#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
channel="${1:-}"
case "$channel" in
  beta|staging) ;;
  *) echo "error: use make beta or make staging" >&2; exit 64 ;;
esac
export FRITZ_DISTRIBUTION=1
source scripts/release-config.sh

for variable in FRITZ_VERSION FRITZ_BUILD_NUMBER FRITZ_CODE_SIGN_IDENTITY \
  FRITZ_SPARKLE_FEED_URL FRITZ_SPARKLE_PUBLIC_ED_KEY \
  FRITZ_UPDATE_DOWNLOAD_URL_PREFIX FRITZ_HOMEPAGE_URL FRITZ_NOTARY_PROFILE; do
  if [[ -z "${!variable:-}" ]]; then
    echo "error: $variable is required for make $channel" >&2
    exit 1
  fi
done
if [[ ! "$FRITZ_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
      ! "$FRITZ_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: set a semantic FRITZ_VERSION and a monotonic positive FRITZ_BUILD_NUMBER" >&2
  exit 1
fi
if [[ "$FRITZ_CODE_SIGN_IDENTITY" == - ]]; then
  echo "error: FRITZ_CODE_SIGN_IDENTITY must be a Developer ID Application identity" >&2
  exit 1
fi
if [[ "$FRITZ_SPARKLE_FEED_URL" != https://* ||
      "$FRITZ_UPDATE_DOWNLOAD_URL_PREFIX" != https://* ||
      "$FRITZ_HOMEPAGE_URL" != https://* ]]; then
  echo "error: the feed, download prefix, and homepage must be HTTPS URLs" >&2
  exit 1
fi
archive="dist/updates/Fritz-$FRITZ_VERSION.dmg"
if [[ -e "$archive" ]]; then
  if [[ -f dist/updates/appcast.xml ]]; then
    python3 - "$FRITZ_VERSION" "$FRITZ_BUILD_NUMBER" "$channel" <<'PY'
import sys
import xml.etree.ElementTree as ET

version, build, requested_channel = sys.argv[1:]
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
item = ET.parse('dist/updates/appcast.xml').getroot().find('./channel/item')
if (item is None or item.findtext(f'{sparkle}shortVersionString') != version
        or item.findtext(f'{sparkle}version') != build):
    raise SystemExit(f'error: existing appcast does not match Fritz {version} ({build}); '
                     f'use a new version and build number for a new {requested_channel} update')
channel = item.findtext(f'{sparkle}channel') or 'release'
if channel == 'release':
    raise SystemExit(f'error: Fritz {version} ({build}) is already on the Release channel; '
                     f'increase the version and build number before running make {requested_channel} '
                     'for a new update, or use make promote to retry Release publication')
if channel != requested_channel:
    raise SystemExit(f'error: existing appcast channel is {channel!r}; '
                     f'only a prepared {requested_channel} update can resume publication with make {requested_channel}')
PY
    ./scripts/publish-update.sh "$channel"
    exit 0
  fi
  echo "error: $archive already exists without an appcast; refusing to replace a release artifact" >&2
  exit 1
fi

# Check credentials before spending time on the release build.
xcrun notarytool history --keychain-profile "$FRITZ_NOTARY_PROFILE" >/dev/null
key_tool="$(python3 scripts/build-cache.py --derived-data)/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
test -x "$key_tool" || { echo "error: run make setup to resolve Sparkle tools" >&2; exit 1; }
public_key="$("$key_tool" --account "$FRITZ_SPARKLE_KEY_ACCOUNT" -p)"
[[ "$public_key" == "$FRITZ_SPARKLE_PUBLIC_ED_KEY" ]] || {
  echo "error: Fritz's Sparkle Keychain key does not match the configured public key" >&2
  exit 1
}
if [[ ! -f website/node_modules/.package-lock.json ||
      website/package-lock.json -nt website/node_modules/.package-lock.json ]]; then
  npm --prefix website ci
fi
(
  cd website
  npx --no-install wrangler whoami >/dev/null
  npx --no-install wrangler r2 bucket info fritz-updates >/dev/null
)
CONFIGURATION=release ./scripts/build-app.sh
authority="$(codesign -dvvv dist/Fritz.app 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ "$authority" != "Developer ID Application:"* ]]; then
  echo "error: the staged app is not signed with a Developer ID Application identity" >&2
  exit 1
fi
./scripts/create-update-archive.sh
xcrun notarytool submit "$archive" --keychain-profile "$FRITZ_NOTARY_PROFILE" --wait
xcrun stapler staple "$archive"
xcrun stapler validate "$archive"
./scripts/prepare-update.sh "$channel"
./scripts/publish-update.sh "$channel"
echo "Fritz $FRITZ_VERSION $channel is published at $FRITZ_SPARKLE_FEED_URL."
