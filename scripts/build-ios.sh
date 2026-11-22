#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

action="${1:-build}"
args=(
  -project app/Fritz.xcodeproj -scheme Fritz-iOS
  -derivedDataPath "${FRITZ_DERIVED_DATA}/iOS"
  -clonedSourcePackagesDirPath "${FRITZ_XCODE_CACHE}/iOS"
)
archive="$PWD/dist/ios/Fritz.xcarchive"
if [[ "$action" == archive || "$action" == upload ]]; then
  : "${FRITZ_IOS_TEAM:?Set FRITZ_IOS_TEAM to the App Store Connect team ID}"
  auth=(-allowProvisioningUpdates)
  if [[ -n "${FRITZ_IOS_API_KEY_PATH:-}" ]]; then
    : "${FRITZ_IOS_API_KEY_ID:?Set the App Store Connect API key ID}"
    : "${FRITZ_IOS_API_ISSUER_ID:?Set the App Store Connect API issuer ID}"
    auth+=(
      -authenticationKeyPath "$FRITZ_IOS_API_KEY_PATH"
      -authenticationKeyID "$FRITZ_IOS_API_KEY_ID"
      -authenticationKeyIssuerID "$FRITZ_IOS_API_ISSUER_ID"
    )
  fi
fi

case "$action" in
  build)
    exec xcodebuild "${args[@]}" -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
    ;;
  archive)
    mkdir -p dist/ios
    settings=("DEVELOPMENT_TEAM=${FRITZ_IOS_TEAM}")
    if [[ -n "${FRITZ_IOS_BUILD_NUMBER:-}" ]]; then
      settings+=("CURRENT_PROJECT_VERSION=${FRITZ_IOS_BUILD_NUMBER}")
    fi
    exec xcodebuild "${args[@]}" -destination 'generic/platform=iOS' -configuration Release \
      -archivePath "$archive" "${auth[@]}" archive "${settings[@]}"
    ;;
  upload)
    if [[ ! -d "$archive" ]]; then
      echo "Missing signed archive. Run make ios-archive first." >&2
      exit 1
    fi
    options="$(mktemp)"
    trap 'rm -f "$options"' EXIT
    plutil -create xml1 "$options"
    plutil -insert method -string app-store-connect "$options"
    plutil -insert destination -string upload "$options"
    plutil -insert signingStyle -string automatic "$options"
    plutil -insert teamID -string "$FRITZ_IOS_TEAM" "$options"
    plutil -insert testFlightInternalTestingOnly -bool YES "$options"
    plutil -insert manageAppVersionAndBuildNumber -bool NO "$options"
    xcodebuild -exportArchive -archivePath "$archive" \
      -exportOptionsPlist "$options" -exportPath "$PWD/dist/ios/upload" "${auth[@]}"
    ;;
  *)
    echo "Usage: $0 [build|archive|upload]" >&2
    exit 2
    ;;
esac
