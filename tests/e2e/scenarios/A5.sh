#!/usr/bin/env bash
# A5 — review-finish (unattended): spec status done + triage rows; sprint-status 1-1=done.
# Expect: review comment posted, issue status:done + closed, CI gate (PR exists) → ci-status.
#   A5.sh rows        (default) the happy path
#   A5.sh none        no triage rows → post-dev-complete halts ("review never ran") because
#                     post-build-dispatch-auto sets review_producer=bmad-build-auto
#   A5.sh interactive same as rows but through bmad-build.toml (allow_merge=true) with NO user
#                     to answer "Merge the story MR now? (yes/no)" → what does the agent do?
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A5; MODE="${1:-rows}"
WT="$(story_worktree 1-1-login-form)"
set_outcome "$WT" pass
case "$MODE" in rows|interactive) write_spec "$WT" done rows >/dev/null;; none) write_spec "$WT" done none >/dev/null;; *) die "mode rows|none|interactive";; esac
set_story_status "$WT" 1-1-login-form done; touch_src "$WT" "A5 $MODE: review fixes"; ( cd "$WT" && git push -q )
[ -n "$(pr_for "feat/$PRD_KEY/1-1-login-form")" ] || gh pr create -R "$REPO_GH" --title "Story 1.1: 1-1-login-form" --body "Sprint key: 1-1-login-form" --base "feat/$PRD_KEY/prd" --head "feat/$PRD_KEY/1-1-login-form" >/dev/null
log "waiting for the story branch CI to finish so the gate is deterministic"; wait_run "feat/$PRD_KEY/1-1-login-form" 600 >/dev/null || true
rm -f "$WT/ci-status.json"
TOML=bmad-build-auto; [ "$MODE" = interactive ] && TOML=bmad-build
D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --toml $TOML --var "spec_file=$SPEC_REL" --tag "$MODE")"
# EXACT title, not a prefix: 'Story 1.1' also matches 'Story 1.10: Login Form Extended',
# the prefix-collision fixture d19/g06 seeds, and the listing is newest-first — so the
# verdict was read off that issue (OPEN, status:backlog) while the hook had closed the
# right one. The title is the identity create-issue dedupes by, so match it whole.
row="$(story_issues | awk -F'\t' '$2 == "Story 1.1: Login Form"' | head -1)"
n="$(printf '%s' "$row" | cut -f1 | tr -d '#')"
state="$(printf '%s' "$row" | cut -f3,4)"
comments="$([ -n "$n" ] && gh issue view "$n" -R "$REPO_GH" --json comments --jq '.comments | length' || echo 0)"
ci="$(cat "$WT/ci-status.json" 2>/dev/null || echo absent)"
notes="issue=#$n state=$state comments=$comments ci-status.json=$ci merged=$(gh pr list -R "$REPO_GH" --state merged --head "feat/$PRD_KEY/1-1-login-form" --json number --jq 'length') improvised=$(rj "$D" 'r.get("improvised")') turns=$(rj "$D" 'r["result"]["num_turns"]') cost=\$$(rj "$D" 'round(r["result"]["total_cost_usd"] or 0,2)'); final: $(tail -c 250 "$D/final.txt" | tr '\n' ' ')"
case "$MODE" in
  rows) if printf '%s' "$state" | grep -q 'CLOSED' && [ "$comments" -ge 1 ]; then verdict $C-rows OBSERVED "happy path: comment + closed. $notes"; else verdict $C-rows OBSERVED "$notes"; fi;;
  none) if saw "$D" 'Refusing to merge an unreviewed story|review never ran|has no rows'; then verdict $C-none CONFIRMED "review_producer gate halted on the empty triage section. $notes"; else verdict $C-none OBSERVED "$notes"; fi;;
  interactive) if saw "$D" 'Merge the story MR now' || grep -q 'Merge the story MR now' "$D/final.txt"; then verdict $C-interactive OBSERVED "headless agent reached the merge prompt; see final.txt for what it decided (do_merge). $notes"; else verdict $C-interactive OBSERVED "merge prompt not reached. $notes"; fi;;
esac
