#!/usr/bin/env bash
set -euo pipefail
cd "${SRCROOT}/.."

case "${PLATFORM_NAME}" in
  iphoneos) target=aarch64-apple-ios ;;
  iphonesimulator) target=aarch64-apple-ios-sim ;;
  *) echo "Unsupported Fritz iOS build platform: ${PLATFORM_NAME}" >&2; exit 1 ;;
esac

# Xcode launched from Finder uses a smaller PATH than an interactive shell.
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${PATH}"
export SDKROOT="$(xcrun --sdk "${PLATFORM_NAME}" --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET

if [[ "${FRITZ_BUILD_CACHE_ACTIVE:-}" != "$PWD" ]]; then
  exec mise exec -- python3 scripts/build-cache.py "$0"
fi

mise exec -- cargo build --locked --release --package fritz-ios --target "$target"
library="${CARGO_TARGET_DIR}/${target}/release/libfritz_ios.a"
output="${DERIVED_FILE_DIR}/libfritz_ios.a"
mkdir -p "${DERIVED_FILE_DIR}"
if ! cmp -s "$library" "$output"; then
  cp "$library" "$output"
fi
