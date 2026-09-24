#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
path_hash="$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
app_name="FritzDebug"
bundle_id="dev.fritz.FrizDebug.$path_hash"
data_directory="$HOME/Library/Application Support/FritzDebug-$path_hash/Data"
keychain_service="dev.fritz.provider-credentials.$path_hash"

if [[ "${1:-}" == "--print" ]]; then
  printf 'app_name=%s\nbundle_id=%s\ndata_directory=%s\nkeychain_service=%s\n' \
    "$app_name" "$bundle_id" "$data_directory" "$keychain_service"
fi
