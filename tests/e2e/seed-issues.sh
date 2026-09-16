#!/usr/bin/env bash
# Seed N issues labelled prd:<key> into the GitHub lab repo (for D04: >100 results).
#   seed-issues.sh <count> <prd_key>
# Idempotent: counts existing issues with the label and only creates the difference.
# 1.5 s between creations; on 403/429 (secondary rate limit) waits 60 s and retries.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
load_lab
COUNT="${1:-105}"; KEY="${2:-bulkprd}"; LABEL="prd:$KEY"
gh label create "$LABEL" -R "$REPO_GH" --color 0366d6 2>/dev/null || true
have="$(gh issue list -R "$REPO_GH" --state all --label "$LABEL" --limit 500 --json number --jq 'length')"
log "seed: $have issues already carry $LABEL; target $COUNT"
i="$have"
while [ "$i" -lt "$COUNT" ]; do
  n=$((i+1))
  if out="$(gh issue create -R "$REPO_GH" --title "Seed $n ($KEY)" --body "Bulk seed issue $n for the D04 pagination replay." --label "$LABEL" 2>&1)"; then
    i=$n; printf '\r  created %d/%d' "$i" "$COUNT" >&2; sleep 1.5
  else
    if printf '%s' "$out" | grep -qE '403|429|rate limit|abuse'; then warn "rate limited at $n — sleeping 60 s"; sleep 60
    else die "issue create failed: $out"; fi
  fi
done
echo >&2; log "seed: $i issues labelled $LABEL"
echo "$i"
