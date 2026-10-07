#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
if [[ "${FRITZ_BUILD_CACHE_ACTIVE:-}" != "$PWD" ]]; then
  exec python3 scripts/build-cache.py --setup "$PWD/scripts/setup-worktree.sh" "$@"
fi

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Fritz development requires macOS and full Xcode (Swift 6.3+)." >&2
  exit 1
fi
for tool in mise swift xcodebuild cmake python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool. See README.md for Fritz's development requirements." >&2
    exit 1
  fi
done
mise install rust
xcodebuild -version
swift --version
mise exec -- cargo --version
mise exec -- cargo fmt --version
mise exec -- cargo clippy --version

# Resolve committed versions into ~/Builds/Fritz (or FRITZ_BUILD_ROOT).
mise exec -- cargo fetch --locked
swift package --scratch-path "$FRITZ_SWIFT_BUILD" --cache-path "$FRITZ_SWIFT_CACHE" --force-resolved-versions resolve
swift package --package-path app --scratch-path "$FRITZ_APP_SWIFT_BUILD" --cache-path "$FRITZ_SWIFT_CACHE" --force-resolved-versions resolve
xcodebuild -resolvePackageDependencies \
  -project app/Fritz.xcodeproj -scheme Fritz \
  -derivedDataPath "$FRITZ_DERIVED_DATA" \
  -packageCachePath "$FRITZ_XCODE_CACHE" \
  -onlyUsePackageVersionsFromResolvedFile
echo "Fritz dependencies are ready. Run make dev-open to build and launch."
