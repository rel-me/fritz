#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Fritz development requires macOS and full Xcode (Swift 6.3+)." >&2
  exit 1
fi
for tool in cargo swift xcodebuild cmake python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool. See README.md for Fritz's development requirements." >&2
    exit 1
  fi
done
xcodebuild -version
swift --version
cargo --version
cargo fmt --version
cargo clippy --version

# Resolve the committed versions into checkout-local build directories. Never
# copy another checkout's credentials, app data, targets, or DerivedData.
cargo fetch --locked
swift package --package-path app --force-resolved-versions resolve
xcodebuild -resolvePackageDependencies \
  -project app/Fritz.xcodeproj -scheme Fritz \
  -derivedDataPath dist/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile
echo "Fritz dependencies are ready. Run make dev-open to build and launch."
