#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || true)"
if [[ -z "$branch" ]]; then
  echo "error: FritzDebug requires a branch; switch to main or a branch with an open PR before building" >&2
  exit 1
fi
app_name="FritzDebug"
if [[ "$branch" != main ]]; then
  if ! remote="$(git -C "$root" remote get-url origin 2>/dev/null)"; then
    echo "error: FritzDebug requires an origin remote to resolve the branch's open PR" >&2
    exit 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: FritzDebug requires GitHub CLI (gh); install it and run gh auth login before building" >&2
    exit 1
  fi
  if ! pr_number="$(gh pr list --repo "$remote" --head "$branch" --state open --limit 2 --json number --jq '.[].number')"; then
    echo "error: could not resolve the open PR for $branch; check gh authentication and connectivity" >&2
    exit 1
  fi
  if [[ -z "$pr_number" ]]; then
    echo "error: FritzDebug requires an open PR for $branch; push the branch and create its PR before building" >&2
    exit 1
  fi
  if [[ ! "$pr_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: expected exactly one open PR for $branch" >&2
    exit 1
  fi
  app_name="FritzDebug$pr_number"
fi
path_hash="$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
bundle_id="dev.fritz.FrizDebug.$path_hash"
data_directory="$HOME/Library/Application Support/FritzDebug-$path_hash/Data"
keychain_service="dev.fritz.provider-credentials.$path_hash"

if [[ "${1:-}" == "--print" ]]; then
  printf 'app_name=%s\nbundle_id=%s\ndata_directory=%s\nkeychain_service=%s\n' \
    "$app_name" "$bundle_id" "$data_directory" "$keychain_service"
fi
