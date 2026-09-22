#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-debug}"
case "$configuration" in
  debug) cargo build --locked; xcode_configuration=Debug ;;
  release) cargo build --locked --release; xcode_configuration=Release ;;
  *) echo "CONFIGURATION must be debug or release" >&2; exit 1 ;;
esac
xcodebuild -quiet -project app/Fritz.xcodeproj -scheme Fritz \
  -configuration "$xcode_configuration" -derivedDataPath dist/DerivedData \
  -destination "platform=macOS,arch=$(uname -m)" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
app_bundle="$PWD/dist/Fritz.app"
if [ -d "$app_bundle" ]; then rm -rf "$app_bundle"; fi
ditto "dist/DerivedData/Build/Products/$xcode_configuration/Fritz.app" "$app_bundle"
cp "target/$configuration/fritz" "$app_bundle/Contents/Resources/fritz"
cp "target/$configuration/fritz-harness" "$app_bundle/Contents/Resources/fritz-harness"
package_checkouts="$PWD/dist/DerivedData/SourcePackages/checkouts"
mkdir -p "$app_bundle/Contents/Resources/Licenses"
for dependency in textual swiftui-math swift-concurrency-extras; do
  cp "$package_checkouts/$dependency/LICENSE" "$app_bundle/Contents/Resources/Licenses/$dependency.txt"
done
cp "$package_checkouts/textual/LICENSE-3rdparty.csv" "$app_bundle/Contents/Resources/Licenses/"
cp "$package_checkouts/swiftui-math/Sources/SwiftUIMath/mathFonts.bundle/LICENSE" "$app_bundle/Contents/Resources/Licenses/math-fonts.txt"
cp resources/licenses/*.txt "$app_bundle/Contents/Resources/Licenses/"
codesign --force --sign - --identifier dev.fritz.agent --requirements '=designated => identifier "dev.fritz.agent"' "$app_bundle/Contents/Resources/fritz"
codesign --force --sign - --identifier dev.fritz.harness "$app_bundle/Contents/Resources/fritz-harness"
codesign --force --sign - --identifier dev.fritz.app --requirements '=designated => identifier "dev.fritz.app"' "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
echo "Built $app_bundle"
