#!/usr/bin/env bash
# A6 — common/ensure-mr with a rich description body (quotes, backticks, $(…)) through the
# interpreter. Regression check for D09: the body travels as a FILE (`--body-file
# {mr_description_file}`) and {description_body} no longer exists, so nothing of the body
# reaches the shell — the PR must come back carrying the literal $(…), not its output.
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A6
WT="$(story_worktree 1-2-logout)"; ( cd "$WT" && git commit -q --allow-empty -m "A6 probe" && git push -q )
cp "$E2E_ROOT/fixtures/quoting-body.md" /tmp/e2e-a6-body.md
TEXT="Read \`_bmad/_config/custom/bmad-workflow-lang.md\` for the workflow language specification, then INCLUDE \`_bmad/_config/custom/workflows/common/check-config.yaml\` and then execute \`_bmad/_config/custom/workflows/common/ensure-mr.yaml\` IN FULL with these input variables already in scope: mr_repo=\"github.com/$REPO_GH\", source_branch=\"feat/$PRD_KEY/1-2-logout\", target_branch=\"feat/$PRD_KEY/prd\", mr_title=\"Story 1.2: Logout \\\"quoted\\\"\", mr_description_file=\"/tmp/e2e-a6-body.md\", mr_draft=\"false\"."
D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --text "$TEXT" --entry common/ensure-mr.yaml --tag rich-body)"
n="$(pr_for "feat/$PRD_KEY/1-2-logout")"
[ -n "$n" ] && gh pr view "$n" -R "$REPO_GH" --json title,body > "$(case_dir $C)/pr.json"
inj=$(grep -c INJECTED "$(case_dir $C)/pr.json" 2>/dev/null || echo 0); lit=$(grep -c 'echo INJECTED' "$(case_dir $C)/pr.json" 2>/dev/null || echo 0)
notes="PR=#$n \$(…)-executed=$inj literal-kept=$lit improvised=$(rj "$D" 'r.get("improvised")') errors=$(rj "$D" 'r["tool_errors"]'); final: $(tail -c 200 "$D/final.txt" | tr '\n' ' ')"
if [ "$inj" -gt 0 ] && [ "$lit" = 0 ]; then verdict $C-D09 CONFIRMED "the inline --body interpolation let the shell execute \$(echo INJECTED). $notes"
elif [ -z "$n" ]; then verdict $C-D09 OBSERVED "no PR created — see tool-results.txt for the shell error. $notes"
else verdict $C-D09 LATENT "body reached GitHub intact (agent quoted/escaped or used a file). $notes"; fi
[ -n "$n" ] && gh pr close "$n" -R "$REPO_GH" >/dev/null 2>&1 || true
