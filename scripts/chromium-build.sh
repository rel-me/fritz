#!/bin/bash
# Sourced by build-app.sh for the opt-in Chromium edition.
cef_version="156.0.27+ga10dae3+chromium-156.0.8078.88"
case "$(uname -m)" in
  arm64) cef_platform=macosarm64; cef_sha256=ddb84a6b9c93270655d9aa136b08db933799fbbae60e207f8a37d0e818050e5d ;;
  x86_64) cef_platform=macosx64; cef_sha256=eeee6d06764b51be8b45af04efb675668bc9f83794c2057845f8af271344cac6 ;;
  *) echo "error: unsupported Chromium architecture" >&2; exit 1 ;;
esac
cef_name="cef_binary_${cef_version}_${cef_platform}_minimal"
cef_archive="$PWD/dist/$cef_name.tar.bz2"
cef_root="$PWD/dist/$cef_name"
cef_build="$PWD/dist/chromium-$cef_platform"

prepare_chromium() {
  if [[ ! -f "$cef_archive" ]]; then
    echo "Downloading upstream CEF $cef_version for $cef_platform"
    curl --fail --location --retry 2 --output "$cef_archive.partial" \
      "https://cef-builds.spotifycdn.com/$cef_name.tar.bz2"
    mv "$cef_archive.partial" "$cef_archive"
  fi
  if ! printf '%s  %s\n' "$cef_sha256" "$cef_archive" | shasum -a 256 -c --status; then
    echo "error: CEF archive checksum mismatch; remove $cef_archive and retry" >&2
    return 1
  fi
  if [[ ! -f "$cef_root/.verified-$cef_sha256" ]]; then
    rm -rf "$cef_root"
    tar -xf "$cef_archive" -C "$PWD/dist"
    touch "$cef_root/.verified-$cef_sha256"
  fi
  env -u MAKEFLAGS cmake -S app/Chromium -B "$cef_build" \
    -DCEF_ROOT="$cef_root" -DPROJECT_ARCH="$(uname -m)" -DCMAKE_BUILD_TYPE=Release
  env -u MAKEFLAGS cmake --build "$cef_build" --parallel "$(sysctl -n hw.ncpu)"
}

stage_chromium() {
  local bundle="$1" app_name="$2" bundle_id="$3"
  shift 3
  local sign_options=("$@")
  local frameworks="$bundle/Contents/Frameworks"
  local framework="$frameworks/Chromium Embedded Framework.framework"
  ditto "$cef_root/Release/Chromium Embedded Framework.framework" "$framework"
  cp "$cef_build/libFritzChromium.dylib" "$frameworks/"
  cp "$cef_root/LICENSE.txt" "$bundle/Contents/Resources/Licenses/CEF.txt"
  cp "$cef_root/CREDITS.html" "$bundle/Contents/Resources/Licenses/Chromium-Credits.html"
  local library
  for library in "$framework"/Libraries/*.dylib; do
    codesign --force "${sign_options[@]}" "$library"
  done
  codesign --force "${sign_options[@]}" "$framework"
  codesign --force "${sign_options[@]}" "$frameworks/libFritzChromium.dylib"

  # CEF selects helpers by the main executable name and process suffix.
  local suffix name helper identifier
  local entitlements
  for suffix in '' ' (Alerts)' ' (GPU)' ' (Plugin)' ' (Renderer)'; do
    name="$app_name Helper$suffix"
    helper="$frameworks/$name.app"
    identifier="$bundle_id.helper"
    entitlements=()
    case "$suffix" in
      ' (Alerts)') identifier+=.alerts ;;
      ' (GPU)')
        identifier+=.gpu
        entitlements=(--entitlements app/Chromium/JIT.entitlements)
        ;;
      ' (Plugin)') identifier+=.plugin ;;
      ' (Renderer)')
        identifier+=.renderer
        entitlements=(--entitlements app/Chromium/JIT.entitlements)
        ;;
    esac
    mkdir -p "$helper/Contents/MacOS"
    cp "$cef_build/FritzChromiumHelper" "$helper/Contents/MacOS/$name"
    local plist="$helper/Contents/Info.plist"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string "$name" "$plist"
    plutil -insert CFBundleName -string "$name" "$plist"
    plutil -insert CFBundleIdentifier -string "$identifier" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleVersion -string "$FRITZ_BUILD_NUMBER" "$plist"
    plutil -insert CFBundleShortVersionString -string "$FRITZ_VERSION" "$plist"
    plutil -insert LSUIElement -bool YES "$plist"
    codesign --force "${sign_options[@]}" ${entitlements[@]+"${entitlements[@]}"} "$helper"
  done
}
