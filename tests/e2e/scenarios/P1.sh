#!/usr/bin/env bash
# P1 — REAL BMM: /bmad-prd headless in the consumer. Activation (module) detects intent
# from the PRD frontmatter (prd_key present → update/validate → PRD worktree), the skill
# runs, then complete.yaml fires. Run twice: the second run has no PRD change → D07 shape.
#   P1.sh [create|update]   default update (the fixture PRD carries prd_key=labprd)
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=P1; MODE="${1:-update}"
if [ "$MODE" = create ]; then
  # fresh key so the module's activation takes the "create" branch (new worktree + issue + draft PR)
  KEY="labprd2"; ANS="intent = create a NEW PRD from scratch; initiative/PRD key = $KEY; product = a tiny login/logout demo; keep every section minimal (one or two lines); pick the fastest/'Continue' option in every menu; do not run advanced elicitation; if asked whether to update or create, answer create."
else
  ANS="intent = update/validate the existing PRD (prd_key $PRD_KEY); make one tiny edit (append a sentence to the executive summary); pick the fastest/'Continue' option in every menu; do not run advanced elicitation."
fi
D="$("$E2E_ROOT/run-skill.sh" --case $C --cwd "$CONSUMER" --skill bmad-prd --answers "$ANS" --entry bmad-prd/complete.yaml --tag "$MODE")"
issue_titles > "$(case_dir $C)/issues-after-$MODE.txt"
notes="mode=$MODE PRs=$(gh pr list -R "$REPO_GH" --state all --json number --jq length) improvised=$(rj "$D" 'r.get("improvised")')/$(rj "$D" 'r["bash_commands"]') turns=$(rj "$D" 'r["result"]["num_turns"]') cost=\$$(rj "$D" 'round(r["result"]["total_cost_usd"] or 0,2)'); final: $(tail -c 300 "$D/final.txt" | tr '\n' ' ')"
if ran "$D" 'resolve_customization' && ran "$D" 'bmad-prd/complete.yaml|activation.yaml' ; then verdict $C-$MODE OBSERVED "BMM resolved the customization and the module hooks ran. $notes"; else verdict $C-$MODE OBSERVED "check whether the hooks fired (commands.txt). $notes"; fi
