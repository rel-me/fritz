#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
if [[ "${FRITZ_BUILD_CACHE_ACTIVE:-}" != "$PWD" ]]; then
  exec python3 scripts/build-cache.py "$PWD/scripts/build-app.sh" "$@"
fi

configuration="${CONFIGURATION:-debug}"
source scripts/release-config.sh
case "$configuration" in
  debug)
    source scripts/dev-runtime.sh
    cargo_args=(build --locked)
    xcode_configuration=Debug
    ;;
  release)
    cargo_args=(build --locked --release)
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

source scripts/compiler-cache.sh
configure_compiler_cache
mkdir -p dist
app_bundle="$PWD/dist/$app_name.app"
signing_identity="${FRITZ_CODE_SIGN_IDENTITY:--}"
reuse_settings=("configuration=$configuration" "name=$app_name" "bundle=$bundle_id"
  "version=$FRITZ_VERSION" "build_number=$FRITZ_BUILD_NUMBER" "identity=$signing_identity"
  "feed=$feed_url" "public_key=$public_key" "data=${data_directory:-}"
  "models=${models_directory:-}" "keychain=${keychain_service:-}")
local_build_settings=()
if [[ "${FRITZ_DISTRIBUTION:-0}" != 1 ]]; then
  local_build_settings=(ONLY_ACTIVE_ARCH=YES)
  if python3 scripts/app-build-reuse.py check "$app_bundle" "${reuse_settings[@]}"; then
    printf '%s\n' "$app_bundle" > dist/.last-built-app
    exit 0
  else
    status=$?
    [[ "$status" == 10 ]] || exit "$status"
  fi
else
  # Distribution replaces the same bundle; discard local reuse metadata first.
  rm -f "dist/.build-reuse-$configuration.json"
fi
start_compiler_cache
python3 scripts/parallel-build.py "$PWD/dist/build-logs" \
  cargo "${cargo_args[@]}" ::: \
  xcodebuild -quiet -project app/Fritz.xcodeproj -scheme Fritz \
  -configuration "$xcode_configuration" -derivedDataPath "$FRITZ_DERIVED_DATA" \
  -packageCachePath "$FRITZ_XCODE_CACHE" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -onlyUsePackageVersionsFromResolvedFile \
  FRITZ_PRODUCT_NAME="$app_name" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  MARKETING_VERSION="$FRITZ_VERSION" \
  CURRENT_PROJECT_VERSION="$FRITZ_BUILD_NUMBER" \
  "${xcode_cache_settings[@]}" "${local_build_settings[@]}" CODE_SIGNING_ALLOWED=NO build

xcode_bundle="$FRITZ_DERIVED_DATA/Build/Products/$xcode_configuration/$app_name.app"
test -d "$xcode_bundle" || { echo "error: missing $xcode_bundle" >&2; exit 1; }
if [ -d "$app_bundle" ]; then rm -rf "$app_bundle"; fi
ditto "$xcode_bundle" "$app_bundle"
cp "$CARGO_TARGET_DIR/$configuration/fritz" "$app_bundle/Contents/Resources/fritz"
cp "$CARGO_TARGET_DIR/$configuration/fritz-harness" "$app_bundle/Contents/Resources/fritz-harness"
cp "$CARGO_TARGET_DIR/$configuration/fritz-decision-harness" "$app_bundle/Contents/Resources/fritz-decision-harness"
package_checkouts="$FRITZ_DERIVED_DATA/SourcePackages/checkouts"
mkdir -p "$app_bundle/Contents/Resources/Licenses"
cp Packages/Bonsplit/LICENSE "$app_bundle/Contents/Resources/Licenses/Bonsplit.txt"
cp LICENSE "$app_bundle/Contents/Resources/Licenses/Fritz-AGPL-3.0.txt"
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
  plutil -insert FritzModelsDirectory -string "$models_directory" "$plist"
  plutil -insert FritzKeychainService -string "$keychain_service" "$plist"
fi
if [[ -n "$feed_url" ]]; then
  plutil -insert SUFeedURL -string "$feed_url" "$plist"
  plutil -insert SUPublicEDKey -string "$public_key" "$plist"
  plutil -insert SUEnableAutomaticChecks -bool true "$plist"
fi

sign_options=(--sign "$signing_identity")
if [[ "$signing_identity" != - ]]; then sign_options+=(--options runtime); fi
sparkle="$app_bundle/Contents/Frameworks/Sparkle.framework"
test -d "$sparkle" || { echo "error: Sparkle.framework was not embedded" >&2; exit 1; }
codesign --force --deep "${sign_options[@]}" "$sparkle"
codesign --force "${sign_options[@]}" --identifier dev.fritz.agent \
  --requirements '=designated => identifier "dev.fritz.agent"' "$app_bundle/Contents/Resources/fritz"
codesign --force "${sign_options[@]}" --identifier dev.fritz.harness \
  "$app_bundle/Contents/Resources/fritz-harness"
codesign --force "${sign_options[@]}" --identifier dev.fritz.decision-harness \
  "$app_bundle/Contents/Resources/fritz-decision-harness"
codesign --force "${sign_options[@]}" --identifier "$bundle_id" \
  "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
if [[ "${FRITZ_DISTRIBUTION:-0}" != 1 ]]; then
  python3 scripts/app-build-reuse.py record "$app_bundle" "${reuse_settings[@]}"
fi
printf '%s\n' "$app_bundle" > dist/.last-built-app
echo "Built $app_bundle"
