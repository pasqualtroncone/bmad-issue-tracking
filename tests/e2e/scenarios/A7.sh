#!/usr/bin/env bash
# A7 — dev-finish on a bmad-loop-shaped branch: bmad-loop/r1/1-1-login-form, created from
# the PRD branch with NO upstream (bmad-loop makes the worktree, not the module).
# Regression check for the pair D08 + D22: the phase pushes `-u origin HEAD`, so the
# missing upstream is set by the push itself, and it hands ensure-mr
# source_branch={current_branch}, so --head names the branch that was just pushed — never
# the pattern-derived feat/<prd>/<story>, which under bmad-loop exists nowhere.
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A7
WT="$(story_worktree 1-1-login-form bmad-loop/r1/1-1-login-form --no-upstream)"
set_outcome "$WT" pass; write_spec "$WT" in-review rows >/dev/null; set_story_status "$WT" 1-1-login-form review; touch_src "$WT" "A7: bmad-loop shaped dev"
rm -f "$WT/ci-status.json"
D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --toml bmad-build-auto --var "spec_file=$SPEC_REL" --tag bmad-loop-branch)"
up="$(cd "$WT" && git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1 | head -1)"
ci="$(cat "$WT/ci-status.json" 2>/dev/null || echo absent)"
notes="upstream-after='$up' ci-status.json=$ci improvised=$(rj "$D" 'r.get("improvised")') errors=$(rj "$D" 'r["tool_errors"]'); final: $(tail -c 250 "$D/final.txt" | tr '\n' ' ')"
if saw "$D" 'no upstream branch'; then
  if ran "$D" 'git push (-u|--set-upstream)'; then
    if saw "$D" "could not find|not found|head branch|Head sha can't be blank|does not exist"; then verdict $C-D08-D22 CONFIRMED "D08: a push without -u failed on the missing upstream and the agent had to improvise 'git push -u'; then D22: ensure-mr --head feat/$PRD_KEY/1-1-login-form does not exist on the remote. The phase should push '-u origin HEAD' and pass source_branch={current_branch} itself. $notes"
    else verdict $C-D08 CONFIRMED "D08 hit; the agent improvised -u; D22 not surfaced (check commands.txt). $notes"; fi
  else verdict $C-D08 CONFIRMED "post-dev-complete's push → 'no upstream branch'; the hook halted (no CI gate, no issue update, no ci-status.json). $notes"; fi
else verdict $C-D08 REFUTED "no 'no upstream' error in the trace: the phase pushes '-u origin HEAD', which sets the upstream on a bmad-loop branch, and hands ensure-mr source_branch={current_branch}, so --head names that same branch (D22 cannot surface either). $notes"; fi
( cd "$CONSUMER" && git worktree remove --force "$WT" 2>/dev/null; git branch -D bmad-loop/r1/1-1-login-form >/dev/null 2>&1 ) || true
