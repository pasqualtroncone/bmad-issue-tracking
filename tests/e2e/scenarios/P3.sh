#!/usr/bin/env bash
# P3 — REAL BMM: /bmad-sprint-planning headless → real sprint-status.yaml, then the module's
# complete.yaml runs issue-sync/sync (D17, D15, D21 in the real flow).
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=P3
before="$(issue_titles "prd:$PRD_KEY" | wc -l)"
ANS="generate/refresh the sprint status from epics.md; accept defaults; choose 'Continue' in every menu."
D="$("$E2E_ROOT/run-skill.sh" --case $C --cwd "$CONSUMER" --skill bmad-sprint-planning --answers "$ANS" --entry issue-sync/sync.yaml --tag run)"
after="$(issue_titles "prd:$PRD_KEY" | wc -l)"; issue_titles "prd:$PRD_KEY" > "$(case_dir $C)/issues-after.txt"
ne=0; saw "$D" "NameError: name 'sys'" && ne=1
verdict $C OBSERVED "issues before=$before after=$after NameError=$ne improvised=$(rj "$D" 'r.get("improvised")') turns=$(rj "$D" 'r["result"]["num_turns"]'); final: $(tail -c 300 "$D/final.txt" | tr '\n' ' ')"
