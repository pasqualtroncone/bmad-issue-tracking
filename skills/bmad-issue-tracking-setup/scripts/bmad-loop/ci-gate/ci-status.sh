#!/usr/bin/env bash
# bmad-loop CI status checker, used as a `[verify]` command.
#
# Reads ci-status.json, written by common/write-ci-status.yaml from the
# dev-finish / review-finish phases of common/post-dev-complete.yaml. That chain
# is reached from the bmad-build-auto on_complete hook, whose entry point is
# common/post-build-dispatch-auto.yaml — no bmad-loop plugin is involved.
# Returns exit 0 if CI is green, exit 1 if red (with diagnostic in output).
# Returns exit 1 if ci-status.json is missing — the on_complete hook did
# NOT write it. This is treated as a fixable failure (retry) rather than an
# env_fault (rc=126), so bmad-loop will run a repair session instead of
# escalating.
#
# This script is deterministic and fast — it just reads a file. The intelligent
# work (polling CI, parsing logs, distinguishing flaky vs real) is done by the
# on_complete hook.
#
# Exit contract (bmad-loop verify.py):
#   - rc=0  -> CI green, proceed
#   - rc=1  -> CI red OR ci-status.json missing, fixable: bmad-loop runs a
#              repair session with the diagnostic as feedback

set -u

worktree="$(pwd)"
ci_status_file="$worktree/ci-status.json"

log() { echo "[ci-status] $*"; }
fail() { echo "[ci-status] FAIL: $*"; exit 1; }

# Check if ci-status.json exists
if [ ! -f "$ci_status_file" ]; then
  fail "ci-status.json not found — bmad-build-auto on_complete hook did not write it (check that the dispatch fired and dev-finish phase wrote ci-status.json)"
fi

# Read status from JSON
status="$(uv run --no-project python -c "import json,sys; print(json.load(open(sys.argv[1]))['status'])" "$ci_status_file" 2>&1)"
if [ $? -ne 0 ]; then
  fail "failed to parse ci-status.json — on_complete hook wrote invalid JSON: $status"
fi

case "$status" in
  green)
    log "CI green"
    exit 0
    ;;
  red)
    # Output the full diagnostic for bmad-loop to capture in feedback/
    log "CI red — diagnostic:"
    cat "$ci_status_file"
    exit 1
    ;;
  *)
    fail "unknown status in ci-status.json: $status"
    ;;
esac