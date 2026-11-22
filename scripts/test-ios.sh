#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

temporary="$(mktemp -d)"
simulator=""
mock_pid=""
cleanup() {
  if [[ -n "$mock_pid" ]]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
  if [[ -n "$simulator" ]]; then
    xcrun simctl shutdown "$simulator" 2>/dev/null || true
    xcrun simctl delete "$simulator"
  fi
  rm -r "$temporary"
}
trap cleanup EXIT

# Use the app's regular provider UI with Fritz's existing keyless mock.
python3 tests/mock_provider.py --port 18743 > "$temporary/mock.log" 2>&1 &
mock_pid=$!
for attempt in {1..50}; do
  if [[ -s "$temporary/mock.log" ]]; then break; fi
  sleep 0.1
done
if [[ "$(cat "$temporary/mock.log")" != 18743 ]]; then
  cat "$temporary/mock.log" >&2
  exit 1
fi

simulator="$(xcrun simctl create 'Fritz iOS Verification' 'iPhone 17 Pro')"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
xcodebuild -project app/Fritz.xcodeproj -scheme Fritz-iOS \
  -derivedDataPath "${FRITZ_DERIVED_DATA}/iOS" \
  -clonedSourcePackagesDirPath "${FRITZ_XCODE_CACHE}/iOS" \
  -destination "id=$simulator" -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 120 test
