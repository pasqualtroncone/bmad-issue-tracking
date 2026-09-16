#!/usr/bin/env bash
# P2 — REAL BMM: /bmad-create-epics-and-stories headless (PRD worktree), Continue in every menu.
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=P2
ANS="use the existing PRD (prd_key $PRD_KEY); choose 'Continue' (or the fastest option) in every menu; keep the epics/stories as they already are in epics.md if one exists; do not add elicitation."
D="$("$E2E_ROOT/run-skill.sh" --case $C --cwd "$CONSUMER" --skill bmad-create-epics-and-stories --answers "$ANS" --entry create-epics-and-stories/complete.yaml --tag run)"
verdict $C OBSERVED "pushed=$(ran "$D" 'git push' && echo yes || echo no) improvised=$(rj "$D" 'r.get("improvised")') turns=$(rj "$D" 'r["result"]["num_turns"]') cost=\$$(rj "$D" 'round(r["result"]["total_cost_usd"] or 0,2)'); final: $(tail -c 300 "$D/final.txt" | tr '\n' ' ')"
