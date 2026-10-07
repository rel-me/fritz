#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
channel="${1:-}"
case "$channel" in
  beta|staging) ;;
  *) echo "error: use make beta or make staging" >&2; exit 64 ;;
esac
# Resolve the repository's Rust toolchain before release preparation or npm work.
cargo --version
export FRITZ_DISTRIBUTION=1
explicit_version="${FRITZ_VERSION:+--explicit-version}"
explicit_build="${FRITZ_BUILD_NUMBER:+--explicit-build}"
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
published_appcast="$(mktemp "${TMPDIR:-/tmp}/fritz-published-appcast.XXXXXX")"
trap 'rm -f "$published_appcast"' EXIT
status="$(curl --silent --show-error --location --retry 2 --max-time 30 \
  --output "$published_appcast" --write-out '%{http_code}' "$FRITZ_SPARKLE_FEED_URL")"
case "$status" in
  200) ;;
  404) rm -f "$published_appcast" ;; # First publication has no feed yet.
  *) echo "error: cannot read published appcast (HTTP $status)" >&2; exit 1 ;;
esac
selection_args=("$FRITZ_VERSION" "$FRITZ_BUILD_NUMBER" "$published_appcast")
if [[ -n "$explicit_version" ]]; then selection_args+=("$explicit_version"); fi
if [[ -n "$explicit_build" ]]; then selection_args+=("$explicit_build"); fi
next="$(python3 scripts/next-release.py "${selection_args[@]}")"
read -r FRITZ_VERSION FRITZ_BUILD_NUMBER <<< "$next"
export FRITZ_VERSION FRITZ_BUILD_NUMBER
archive="dist/updates/Fritz-$FRITZ_VERSION.dmg"
echo "Preparing Fritz $FRITZ_VERSION ($FRITZ_BUILD_NUMBER) for $channel."

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
