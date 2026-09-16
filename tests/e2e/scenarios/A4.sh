#!/usr/bin/env bash
# A4 — bmad-prd on_complete twice in the PRD worktree.
#   run 1 (no PRD issue yet, CLEAN tree): the create branch does `git add . && git commit -m`
#          without --allow-empty → D07 halts before push/MR.
#   run 2 (PRD issue exists, prd.md modified): the update branch never commits/pushes →
#          the PRD change stays local (D07b, observation).
# Run BEFORE A3 (which creates the PRD issue through prepare.yaml).
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A4
WT="$(prd_worktree)"
[ -z "$(issue_titles "prd:$PRD_KEY" | grep -F "PRD: $PRD_KEY")" ] || warn "PRD issue already exists: run 1 will take the update branch"
( cd "$WT" && git status --short ) > "$(case_dir $C)/status-run1.txt"
D1="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --toml bmad-prd --var "prd_key=$PRD_KEY" --tag run1-clean)"
notes1="improvised=$(rj "$D1" 'r.get("improvised")') errors=$(rj "$D1" 'r["tool_errors"]') final: $(tail -c 250 "$D1/final.txt" | tr '\n' ' ')"
prd_pr="$(pr_for "feat/$PRD_KEY/prd")"
if saw "$D1" 'nothing to commit' ; then
  # the agent may chain `git add . && git commit … && git push` in ONE call: judge by the outcome (a PR), not by the text
  if [ -n "$prd_pr" ]; then verdict $C-D07 OBSERVED "'nothing to commit' seen but a PRD PR (#$prd_pr) exists — the agent got past the halt. $notes1"
  else verdict $C-D07 CONFIRMED "bmad-prd/complete.yaml:66 'git commit -m' on a clean tree → 'nothing to commit' (exit 1); the hook halted: no push, no draft PR for feat/$PRD_KEY/prd. $notes1"; fi
else verdict $C-D07 REFUTED "no 'nothing to commit' in run 1 (issue existed? see status-run1.txt / commands.txt). $notes1"; fi
# run 2: PRD issue exists (create it if run 1 halted before doing so), prd.md modified
[ -n "$(issue_titles "prd:$PRD_KEY" | grep -F "PRD: $PRD_KEY")" ] || gh issue create -R "$REPO_GH" --title "PRD: $PRD_KEY" --body "**PRD:** $PRD_KEY" --label "prd:$PRD_KEY" --label "type:prd" >/dev/null 2>&1 || { gh label create "prd:$PRD_KEY" -R "$REPO_GH" >/dev/null 2>&1; gh label create "type:prd" -R "$REPO_GH" >/dev/null 2>&1; gh issue create -R "$REPO_GH" --title "PRD: $PRD_KEY" --body "**PRD:** $PRD_KEY" --label "prd:$PRD_KEY" --label "type:prd" >/dev/null; }
printf '\n- FR4: added by A4 run 2 (%s)\n' "$(date -u +%FT%TZ)" >> "$WT/$PLANNING/prd.md"
D2="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --toml bmad-prd --var "prd_key=$PRD_KEY" --tag run2-update)"
dirty="$(cd "$WT" && git status --short | wc -l)"; ahead="$(cd "$WT" && git rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
notes2="dirty-files-after=$dirty commits-ahead=$ahead pushed=$(ran "$D2" 'git push' && echo yes || echo no) improvised=$(rj "$D2" 'r.get("improvised")')"
if [ "$dirty" -gt 0 ] && ! ran "$D2" 'git commit'; then verdict $C-D07b CONFIRMED "update branch of bmad-prd/complete.yaml updates the issue description but never commits/pushes prd.md: the change is left uncommitted in the worktree. $notes2"
else verdict $C-D07b OBSERVED "$notes2"; fi
