#!/usr/bin/env bash
# A1 — dev-finish with CI green (baseline). Story worktree with upstream (create-story ran),
# spec status in-review (6.12.0 template: NO H1), sprint-status 1-1=review, ci/outcome=pass.
# Observes: D21 (issue title from a spec without H1), the no_mr shortcut on a first
# dev-finish (CI gate skipped because the PR is created AFTER wait-for-green-ci).
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A1
WT="$(story_worktree 1-1-login-form)"
set_outcome "$WT" pass; write_spec "$WT" in-review none >/dev/null; set_story_status "$WT" 1-1-login-form review; touch_src "$WT" "A1: implement login"
( cd "$WT" && git push -q )
[ -z "$(pr_for "feat/$PRD_KEY/1-1-login-form")" ] || warn "a PR already exists for the story branch — this is not a first dev-finish"
D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --toml bmad-build-auto --var "spec_file=$SPEC_REL" --tag dev-finish-green)"
story_issues > "$(case_dir $C)/issues-after.txt"; cat "$(case_dir $C)/issues-after.txt" >&2
ci="$(cat "$WT/ci-status.json" 2>/dev/null || echo absent)"
title="$(grep -E 'Story 1\.1' "$(case_dir $C)/issues-after.txt" | head -1 | cut -f2)"
notes="ci-status.json=$ci; issue='$title'; PR=#$(pr_for "feat/$PRD_KEY/1-1-login-form"); improvised=$(rj "$D" 'r.get("improvised")')/$(rj "$D" 'r["bash_commands"]') bash; turns=$(rj "$D" 'r["result"]["num_turns"]') cost=\$$(rj "$D" 'round(r["result"]["total_cost_usd"] or 0,2)')"
if [ -n "$title" ] && printf '%s' "$title" | grep -qE 'Story 1\.1: ?$|Story 1\.1: Intent'; then verdict $C-D21 CONFIRMED "ensure-issue.yaml title from a 6.12.0 spec (no '# ' H1): '$title'. $notes"
elif [ -n "$title" ]; then verdict $C-D21 REFUTED "issue title '$title' (agent may have improvised the title). $notes"; else verdict $C-D21 BLOCKED "no story issue created. $notes"; fi
if saw "$D" 'no_mr' || ! ran "$D" 'gh run list'; then verdict $C-nomr OBSERVED "first dev-finish: find-mr → no_mr → CI gate skipped, ci-status green written without looking at CI (ensure-mr runs after wait-for-green-ci). $notes"; else verdict $C-nomr OBSERVED "CI was consulted on the first dev-finish. $notes"; fi
