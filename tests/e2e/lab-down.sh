#!/usr/bin/env bash
# Tear the lab down: delete (or archive) the remote repos, stop bmad-loop, prune
# worktrees, remove $LAB and the /tmp files the workflows leave behind.
#   lab-down.sh [--keep-evidence] [--archive]
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
ARCHIVE=0
for a in "$@"; do case "$a" in --archive) ARCHIVE=1;; --keep-evidence) ;; *) die "unknown arg $a";; esac; done
load_lab

if [ -n "${REPO_GH:-}" ]; then
  if [ "$ARCHIVE" = 0 ] && gh auth status 2>&1 | grep -q "delete_repo"; then
    log "deleting GitHub repo $REPO_GH"; gh repo delete "$REPO_GH" --yes || warn "gh repo delete failed"
  else
    warn "gh token lacks delete_repo (or --archive): archiving instead"
    gh repo archive "$REPO_GH" --yes || true
    echo "to delete by hand:  gh auth refresh -h github.com -s delete_repo && gh repo delete $REPO_GH --yes"
  fi
fi
if [ -n "${REPO_GL:-}" ]; then
  if [ "$ARCHIVE" = 0 ]; then log "deleting GitLab project $REPO_GL"; glab repo delete "$REPO_GL" --yes || warn "glab repo delete failed"
  else glab repo archive "$REPO_GL" 2>/dev/null || echo "to delete by hand:  glab repo delete $REPO_GL --yes"; fi
fi

for c in "$LAB"/consumer*; do
  [ -d "$c" ] || continue
  ( cd "$c" && command -v bmad-loop >/dev/null && [ -d .bmad-loop ] && bmad-loop stop >/dev/null 2>&1; git worktree prune 2>/dev/null ) || true
done
log "removing $LAB"
rm -rf "$LAB"
[ "$(lab_id)" = "$LAB_ID" ] && rm -f "$LAB_ROOT/current"
rm -f /tmp/issue-desc*.md /tmp/ensure-mr*.md /tmp/prd-desc.md /tmp/review-findings.md /tmp/dev-story-comment.md
log "done. evidence kept at $EVIDENCE"
