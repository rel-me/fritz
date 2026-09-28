#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || true)"
path_hash="$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
app_name="FritzDebug"
if [[ "$branch" != main ]]; then
  app_name="FritzDebug$path_hash"
  if [[ -n "$branch" ]] && command -v gh >/dev/null 2>&1; then
    pr_number="$(cd "$root" && GH_PROMPT_DISABLED=1 gh pr view --json number --jq .number 2>/dev/null || true)"
    if [[ "$pr_number" =~ ^[1-9][0-9]*$ ]]; then
      app_name="FritzDebug$pr_number"
    fi
  fi
fi
bundle_id="dev.fritz.FrizDebug.$path_hash"
data_directory="$HOME/Library/Application Support/FritzDebug-$path_hash/Data"
keychain_service="dev.fritz.provider-credentials.$path_hash"

if [[ "${1:-}" == "--print" ]]; then
  printf 'app_name=%s\nbundle_id=%s\ndata_directory=%s\nkeychain_service=%s\n' \
    "$app_name" "$bundle_id" "$data_directory" "$keychain_service"
fi
