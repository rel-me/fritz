#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${FRITZ_SNAPSHOT_MODE:-compare}" != compare ]]; then
  echo 'error: check-ui-snapshots only compares references; use the documented recording command' >&2
  exit 2
fi
export FRITZ_SNAPSHOT_MODE=compare
export SNAPSHOT_ARTIFACTS="${SNAPSHOT_ARTIFACTS:-$PWD/dist/snapshot-failures}"
mkdir -p "$SNAPSHOT_ARTIFACTS"
swift test --filter SharedControlSnapshots
