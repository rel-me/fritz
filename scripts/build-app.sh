#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-debug}"
case "$configuration" in
  debug)
    source scripts/dev-runtime.sh
    cargo build --locked
    xcode_configuration=Debug
    ;;
  release)
    cargo build --locked --release
    xcode_configuration=Release
    app_name=Fritz
    bundle_id=dev.fritz.app
    ;;
  *) echo "CONFIGURATION must be debug or release" >&2; exit 1 ;;
esac

feed_url="${FRITZ_SPARKLE_FEED_URL:-}"
public_key="${FRITZ_SPARKLE_PUBLIC_ED_KEY:-}"
if [[ "$configuration" == debug ]]; then
  feed_url=""
  public_key=""
fi
if [[ -n "$feed_url" || -n "$public_key" ]]; then
  if [[ -z "$feed_url" || -z "$public_key" || "$feed_url" != https://* ]]; then
    echo "error: FRITZ_SPARKLE_FEED_URL (HTTPS) and FRITZ_SPARKLE_PUBLIC_ED_KEY must be set together" >&2
    exit 1
  fi
  key_bytes="$(printf '%s' "$public_key" | base64 -D 2>/dev/null | wc -c | tr -d '[:space:]')"
  if [[ "$key_bytes" != 32 ]]; then
    echo "error: FRITZ_SPARKLE_PUBLIC_ED_KEY must be a base64 Ed25519 public key" >&2
    exit 1
  fi
fi

xcodebuild -quiet -project app/Fritz.xcodeproj -scheme Fritz \
  -configuration "$xcode_configuration" -derivedDataPath dist/DerivedData \
  -destination "platform=macOS,arch=$(uname -m)" \
  -onlyUsePackageVersionsFromResolvedFile \
  FRITZ_PRODUCT_NAME="$app_name" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  MARKETING_VERSION="${FRITZ_VERSION:-0.1.0}" \
  CURRENT_PROJECT_VERSION="${FRITZ_BUILD_NUMBER:-1}" \
  CODE_SIGNING_ALLOWED=NO build

app_bundle="$PWD/dist/$app_name.app"
xcode_bundle="$PWD/dist/DerivedData/Build/Products/$xcode_configuration/$app_name.app"
test -d "$xcode_bundle" || { echo "error: missing $xcode_bundle" >&2; exit 1; }
if [ -d "$app_bundle" ]; then rm -rf "$app_bundle"; fi
ditto "$xcode_bundle" "$app_bundle"
cp "target/$configuration/fritz" "$app_bundle/Contents/Resources/fritz"
cp "target/$configuration/fritz-harness" "$app_bundle/Contents/Resources/fritz-harness"
package_checkouts="$PWD/dist/DerivedData/SourcePackages/checkouts"
mkdir -p "$app_bundle/Contents/Resources/Licenses"
for dependency in textual swiftui-math swift-concurrency-extras; do
  cp "$package_checkouts/$dependency/LICENSE" "$app_bundle/Contents/Resources/Licenses/$dependency.txt"
done
cp "$package_checkouts/textual/LICENSE-3rdparty.csv" "$app_bundle/Contents/Resources/Licenses/"
cp "$package_checkouts/swiftui-math/Sources/SwiftUIMath/mathFonts.bundle/LICENSE" "$app_bundle/Contents/Resources/Licenses/math-fonts.txt"
cp "$package_checkouts/Sparkle/LICENSE" "$app_bundle/Contents/Resources/Licenses/Sparkle.txt"
cp resources/licenses/*.txt "$app_bundle/Contents/Resources/Licenses/"

plist="$app_bundle/Contents/Info.plist"
if [[ "$configuration" == debug ]]; then
  plutil -replace CFBundleName -string "$app_name" "$plist"
  plutil -replace CFBundleDisplayName -string "$app_name" "$plist"
  plutil -insert FritzDataDirectory -string "$data_directory" "$plist"
  plutil -insert FritzKeychainService -string "$keychain_service" "$plist"
fi
if [[ -n "$feed_url" ]]; then
  plutil -insert SUFeedURL -string "$feed_url" "$plist"
  plutil -insert SUPublicEDKey -string "$public_key" "$plist"
  plutil -insert SUEnableAutomaticChecks -bool true "$plist"
fi

signing_identity="${FRITZ_CODE_SIGN_IDENTITY:--}"
sign_options=(--sign "$signing_identity")
if [[ "$signing_identity" != - ]]; then sign_options+=(--options runtime); fi
sparkle="$app_bundle/Contents/Frameworks/Sparkle.framework"
test -d "$sparkle" || { echo "error: Sparkle.framework was not embedded" >&2; exit 1; }
codesign --force --deep "${sign_options[@]}" "$sparkle"
codesign --force "${sign_options[@]}" --identifier dev.fritz.agent \
  --requirements '=designated => identifier "dev.fritz.agent"' "$app_bundle/Contents/Resources/fritz"
codesign --force "${sign_options[@]}" --identifier dev.fritz.harness \
  "$app_bundle/Contents/Resources/fritz-harness"
codesign --force "${sign_options[@]}" --identifier "$bundle_id" \
  "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf '%s\n' "$app_bundle" > dist/.last-built-app
echo "Built $app_bundle"
