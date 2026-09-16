#!/usr/bin/env bash
# A2 — dev-finish with CI RUNNING. Requires the story PR to exist (A1 first, or it is
# created here as create-story would). ci/outcome=sleep:60 → running at the first poll →
# D18 keeps the loop for the full 60×30 s → D03: the Bash tool times out at 600 s.
#   A2.sh proxy    BASH_MAX_TIMEOUT_MS=90000 (tool timeout after 90 s, ≈3-4 min total)
#   A2.sh default  real defaults (600 s tool timeout, ≈12 min)
#   A2.sh patched  wait-for-green-ci.yaml with 'import sys' added + sleep:660 → isolates D03
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A2; PASS="${1:-proxy}"
WT="$(story_worktree 1-1-login-form)"
if [ -z "$(pr_for "feat/$PRD_KEY/1-1-login-form")" ]; then
  ( cd "$WT" && git push -q ) ; gh pr create -R "$REPO_GH" --title "Story 1.1: 1-1-login-form" --body "Sprint key: 1-1-login-form" --base "feat/$PRD_KEY/prd" --head "feat/$PRD_KEY/1-1-login-form" >/dev/null
fi
write_spec "$WT" in-review none >/dev/null; set_story_status "$WT" 1-1-login-form review
case "$PASS" in
  proxy)   set_outcome "$WT" sleep:60;  export E2E_CLAUDE_ENV="BASH_MAX_TIMEOUT_MS=90000 BASH_DEFAULT_TIMEOUT_MS=90000"; export E2E_CLAUDE_TIMEOUT=900;;
  default) set_outcome "$WT" sleep:60;  export E2E_CLAUDE_TIMEOUT=1800;;
  patched) set_outcome "$WT" sleep:660; export E2E_CLAUDE_TIMEOUT=1800
           f="$WT/_bmad/_config/custom/workflows/common/wait-for-green-ci.yaml"; cp "$f" "$f.orig"
           sed -i '/STATUS=\$(uv run --no-project python -c "/a import sys' "$f"; ( cd "$WT" && git add "$f" && git commit -q -m "A2 patched: import sys in wait-for-green-ci" );;
  *) die "pass must be proxy|default|patched";;
esac
touch_src "$WT" "A2 $PASS: trigger CI"; ( cd "$WT" && git push -q )
rm -f "$WT/ci-status.json"
log "CI is now running (sleep outcome); firing the hook immediately"
t0=$(date +%s)
D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --toml bmad-build-auto --var "spec_file=$SPEC_REL" --tag "$PASS")"
wall=$(( $(date +%s) - t0 ))
[ "$PASS" = patched ] && { mv "$WT/_bmad/_config/custom/workflows/common/wait-for-green-ci.yaml.orig" "$WT/_bmad/_config/custom/workflows/common/wait-for-green-ci.yaml"; ( cd "$WT" && git add -A _bmad/_config/custom/workflows/common/wait-for-green-ci.yaml && git commit -q -m "A2 patched: restore" ); }
ci="$(cat "$WT/ci-status.json" 2>/dev/null || echo absent)"
timed_out=0; saw "$D" 'timed out|Command timed out|exceeded.*timeout' && timed_out=1
notes="pass=$PASS wall=${wall}s ci-status.json=$ci tool-timeout-seen=$timed_out improvised=$(rj "$D" 'r.get("improvised")') turns=$(rj "$D" 'r["result"]["num_turns"]') cost=\$$(rj "$D" 'round(r["result"]["total_cost_usd"] or 0,2)')"
case "$PASS" in
  proxy|default)
    if [ "$timed_out" = 1 ]; then verdict $C-$PASS CONFIRMED "D18+D03: the polling RUN never returned before the Bash tool timeout (CI itself finished in ~60 s). $notes"
    else verdict $C-$PASS OBSERVED "no tool timeout seen — inspect commands.txt (did the agent shorten the loop?). $notes"; fi;;
  patched)
    if [ "$timed_out" = 1 ] && [ "$ci" = absent ]; then verdict $C-patched CONFIRMED "D03 alone: with the sys import fixed, an 11-min pipeline still exceeds the 600 s tool cap; no ci-status.json. $notes"
    else verdict $C-patched OBSERVED "$notes"; fi;;
esac
