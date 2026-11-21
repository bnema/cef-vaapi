#!/usr/bin/env bash
# Print the state of a GitHub Release: missing, draft or published.
# Uses explicit API calls so a network error is never read as "missing":
# `gh release view` can report "release not found" when one of its two
# lookups fails. Errors are retried, then fail.
set -euo pipefail

repo="$1"
export RELEASE_TAG="$2"
max_attempts="${RELEASE_STATE_ATTEMPTS:-3}"
retry_delay="${RELEASE_STATE_DELAY:-30}"

err=$(mktemp)
trap 'rm -f "$err"' EXIT

lookup() {
  # releases/tags/<tag> only returns published releases.
  if gh api "repos/$repo/releases/tags/$RELEASE_TAG" --jq .id >/dev/null 2>"$err"; then
    echo published
    return 0
  fi
  grep -q 'HTTP 404' "$err" || return 1

  local drafts
  drafts=$(gh api --paginate "repos/$repo/releases?per_page=100" \
    --jq '.[] | select(.draft and .tag_name == env.RELEASE_TAG) | .id' 2>"$err") || return 1
  if [ -n "$drafts" ]; then echo draft; else echo missing; fi
}

for attempt in $(seq 1 "$max_attempts"); do
  if lookup; then
    exit 0
  fi
  cat "$err" >&2
  if [ "$attempt" -lt "$max_attempts" ]; then
    echo "Release lookup attempt ${attempt} failed; retrying in ${retry_delay}s" >&2
    sleep "$retry_delay"
  fi
done

echo "Release lookup failed after ${max_attempts} attempts" >&2
exit 1
