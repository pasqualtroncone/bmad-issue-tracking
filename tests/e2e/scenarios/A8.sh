#!/usr/bin/env bash
# A8 — common/merge-mr through the interpreter on a fresh PR. Regression check for D16:
# `merged` must read true after a successful `gh pr merge`, which exits 0 with empty
# stdout. The `neq` grep below is the S1 record: the operator is gone from the file, so
# any mention in the trace is the agent's, not the workflow's.
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A8
br="a8-merge-$(date +%s)"; ( cd "$CONSUMER" && git checkout -q main && git pull -q --ff-only origin main 2>/dev/null; git checkout -q -b "$br" main && echo "$br" > "$br.txt" && git add "$br.txt" && git commit -q -m "A8 probe" && git push -q -u origin "$br" && git checkout -q main )
n="$(gh pr create -R "$REPO_GH" --title "A8 merge probe" --body "probe" --base main --head "$br" | grep -o '[0-9]*$')"
TEXT="Read \`_bmad/_config/custom/bmad-workflow-lang.md\` for the workflow language specification, then INCLUDE \`_bmad/_config/custom/workflows/common/check-config.yaml\` and then execute \`_bmad/_config/custom/workflows/common/merge-mr.yaml\` IN FULL with input variables mr_iid=\"$n\" and squash=\"true\" already in scope. At the end, print the final values of the variables merged, merge_sha and error."
D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$CONSUMER" --text "$TEXT" --entry common/merge-mr.yaml --tag merge)"
state="$(gh pr view "$n" -R "$REPO_GH" --json state --jq .state)"
merged_var="$(grep -oiE 'merged *[=:] *"?(true|false)' "$D/final.txt" | head -1)"
notes="PR #$n state=$state agent-reported '$merged_var' improvised=$(rj "$D" 'r.get("improvised")'); final: $(tail -c 300 "$D/final.txt" | tr '\n' ' ')"
if [ "$state" = MERGED ] && printf '%s' "$merged_var" | grep -qi false; then verdict $C-D16 CONFIRMED "PR merged on GitHub but merge-mr reports merged=false (stdout-based derivation). $notes"
elif [ "$state" = MERGED ]; then verdict $C-D16 OBSERVED "PR merged; agent reported '$merged_var' (may have reasoned past the rule). $notes"; else verdict $C-D16 OBSERVED "$notes"; fi
grep -iE 'neq' "$D/final.txt" "$D/trace.jsonl" | head -3 > "$(case_dir $C)/neq-mentions.txt" || true
( cd "$CONSUMER" && git pull -q --ff-only origin main 2>/dev/null; git branch -D "$br" >/dev/null 2>&1 ) || true
