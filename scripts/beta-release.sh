#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

for variable in FRITZ_VERSION FRITZ_BUILD_NUMBER FRITZ_CODE_SIGN_IDENTITY \
  FRITZ_SPARKLE_FEED_URL FRITZ_SPARKLE_PUBLIC_ED_KEY \
  FRITZ_UPDATE_DOWNLOAD_URL_PREFIX FRITZ_HOMEPAGE_URL FRITZ_NOTARY_PROFILE; do
  if [[ -z "${!variable:-}" ]]; then
    echo "error: $variable is required for make beta" >&2
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
  echo "error: $archive already exists; refusing to replace a release artifact" >&2
  exit 1
fi

# Check credentials before spending time on the release build.
xcrun notarytool history --keychain-profile "$FRITZ_NOTARY_PROFILE" >/dev/null
CONFIGURATION=release ./scripts/build-app.sh
authority="$(codesign -dv dist/Fritz.app 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ "$authority" != "Developer ID Application:"* ]]; then
  echo "error: the staged app is not signed with a Developer ID Application identity" >&2
  exit 1
fi
./scripts/create-update-archive.sh
xcrun notarytool submit "$archive" --keychain-profile "$FRITZ_NOTARY_PROFILE" --wait
xcrun stapler staple "$archive"
xcrun stapler validate "$archive"
./scripts/prepare-update.sh beta
echo "Beta is ready: upload $archive and dist/updates/appcast.xml together."
