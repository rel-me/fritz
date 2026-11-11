#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Fritz development requires macOS and full Xcode (Swift 6.3+)." >&2
  exit 1
fi
if ! command -v mise >/dev/null 2>&1; then
  echo "Missing mise. Install mise and full Xcode; see README.md." >&2
  exit 1
fi
if [[ "${FRITZ_BUILD_CACHE_ACTIVE:-}" != "$PWD" ]]; then
  mise trust mise.toml
  mise install
  exec mise exec -- python3 scripts/build-cache.py --setup "$PWD/scripts/setup-worktree.sh" "$@"
fi

for tool in swift xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool. Install full Xcode and select it with xcode-select." >&2
    exit 1
  fi
done
xcodebuild -version
swift --version
cargo --version
cargo fmt --version
cargo clippy --version

# Resolve committed versions into ~/Builds/Machine/Fritz (or FRITZ_BUILD_ROOT).
git submodule update --init --recursive
cargo fetch --locked
python3 scripts/prepare-waproto.py
swift package --scratch-path "$FRITZ_SWIFT_BUILD" --cache-path "$FRITZ_SWIFT_CACHE" --force-resolved-versions resolve
swift package --package-path app --scratch-path "$FRITZ_APP_SWIFT_BUILD" --cache-path "$FRITZ_SWIFT_CACHE" --force-resolved-versions resolve
xcodebuild -resolvePackageDependencies \
  -project app/Fritz.xcodeproj -scheme Fritz \
  -derivedDataPath "$FRITZ_DERIVED_DATA" \
  -packageCachePath "$FRITZ_XCODE_CACHE" \
  -onlyUsePackageVersionsFromResolvedFile
echo "Fritz dependencies are ready. Run make dev-open to build and launch."
