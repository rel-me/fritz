#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || true)"
if [[ -z "$branch" ]]; then
  echo "error: FrizDebug requires a branch with an open PR" >&2
  exit 69
fi
remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
if [[ -z "$remote" ]] || ! command -v gh >/dev/null; then
  echo "error: FrizDebug needs origin and GitHub CLI to resolve its open PR" >&2
  exit 69
fi
pr_number="$(gh pr list --repo "$remote" --head "$branch" --state open --limit 2 --json number --jq '.[].number')" || {
  echo "error: could not resolve the open PR for $branch" >&2
  exit 69
}
if [[ ! "$pr_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: FrizDebug requires exactly one open PR for $branch" >&2
  exit 69
fi

path_hash="$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
app_name="FrizDebug$pr_number"
bundle_id="dev.fritz.FrizDebug.$path_hash"
data_directory="$HOME/Library/Application Support/FrizDebug-$path_hash/Data"
keychain_service="dev.fritz.provider-credentials.$path_hash"

if [[ "${1:-}" == "--print" ]]; then
  printf 'app_name=%s\nbundle_id=%s\ndata_directory=%s\nkeychain_service=%s\n' \
    "$app_name" "$bundle_id" "$data_directory" "$keychain_service"
fi
