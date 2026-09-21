#!/usr/bin/env bash
# P1 — REAL BMM: /bmad-prd headless in the consumer. Activation (module) detects intent
# from the PRD frontmatter (prd_key present → update/validate → PRD worktree), the skill
# runs, then complete.yaml fires. Run twice: the second run has no PRD change → D07 shape.
#   P1.sh [create|update]   default update (the fixture PRD carries prd_key=labprd)
#
# `create` is unreachable on this consumer and the scenario says so instead of running:
# the module supports ONE PRD per repository (#90) — bmad-prd/activation.yaml reads the
# intent off {planning_artifacts}/prd.md and a file that already carries a prd_key IS the
# update path, whatever key the answers name. The run that proved it spent a full skill
# invocation to end in the update branch with no issue, branch or PR for `labprd2`.
# Testing creation needs a consumer whose prd.md is absent or unkeyed — a fresh lab.
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=P1; MODE="${1:-update}"
if [ "$MODE" = create ]; then
  KEYED="$(grep -m1 '^prd_key:' "$CONSUMER/$PLANNING/prd.md" 2>/dev/null | sed 's/^prd_key: *//')"
  if [ -n "$KEYED" ]; then
    verdict $C-create BLOCKED "the consumer's $PLANNING/prd.md already carries prd_key '$KEYED', so /bmad-prd takes the update path whatever the answers ask for: one PRD per repository (#90). No skill run: it would only re-test P1 update at full cost. Run create against a consumer with no prd.md, or an unkeyed one"
    exit 0
  fi
  # fresh key so the module's activation takes the "create" branch (new worktree + issue + draft PR)
  KEY="labprd2"; ANS="intent = create a NEW PRD from scratch; initiative/PRD key = $KEY; product = a tiny login/logout demo; keep every section minimal (one or two lines); pick the fastest/'Continue' option in every menu; do not run advanced elicitation; if asked whether to update or create, answer create."
else
  ANS="intent = update/validate the existing PRD (prd_key $PRD_KEY); make one tiny edit (append a sentence to the executive summary); pick the fastest/'Continue' option in every menu; do not run advanced elicitation."
fi
D="$("$E2E_ROOT/run-skill.sh" --case $C --cwd "$CONSUMER" --skill bmad-prd --answers "$ANS" --entry bmad-prd/complete.yaml --tag "$MODE")"
issue_titles > "$(case_dir $C)/issues-after-$MODE.txt"
notes="mode=$MODE PRs=$(gh pr list -R "$REPO_GH" --state all --json number --jq length) improvised=$(rj "$D" 'r.get("improvised")')/$(rj "$D" 'r["bash_commands"]') turns=$(rj "$D" 'r["result"]["num_turns"]') cost=\$$(rj "$D" 'round(r["result"]["total_cost_usd"] or 0,2)'); final: $(tail -c 300 "$D/final.txt" | tr '\n' ' ')"
if ran "$D" 'resolve_customization' && ran "$D" 'bmad-prd/complete.yaml|activation.yaml' ; then verdict $C-$MODE OBSERVED "BMM resolved the customization and the module hooks ran. $notes"; else verdict $C-$MODE OBSERVED "check whether the hooks fired (commands.txt). $notes"; fi
