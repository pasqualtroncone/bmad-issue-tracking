#!/usr/bin/env bash
# A3 — full sync (/bmad-issue-tracking-sync: prepare.yaml then sync.yaml) from the PRD
# worktree with the fixture sprint-status (7 entries). Expected: D17 halts the sync after
# the FIRST created issue; also observes D15 ({entry} rendering), D19, D21 (titles).
#   A3.sh [repeat]   repeat=2 runs it twice to compare {entry} handling
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A3; N="${1:-1}"
WT="$(prd_worktree)"
TEXT="$(sed -n '/^## Instructions/,/^## Unattended/p' "$MOD/skills/bmad-issue-tracking-sync/SKILL.md" | grep -E '^[0-9]+\. ' )"
for i in $(seq 1 "$N"); do
  story_issues > "$(case_dir $C)/issues-before-$i.txt"
  D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --text "$TEXT" --entry issue-sync/sync.yaml --tag "sync-$i")"
  story_issues > "$(case_dir $C)/issues-after-$i.txt"
  created=$(( $(wc -l < "$(case_dir $C)/issues-after-$i.txt") - $(wc -l < "$(case_dir $C)/issues-before-$i.txt") ))
  entries=$(grep -cE '^  [0-9a-z-]+: ' "$WT/$IMPLEMENTATION/sprint-status.yaml")
  nameerr=0; saw "$D" "NameError: name 'sys' is not defined" && nameerr=1
  notes="run $i: entries=$entries created=$created NameError-seen=$nameerr improvised=$(rj "$D" 'r.get("improvised")')/$(rj "$D" 'r["bash_commands"]') turns=$(rj "$D" 'r["result"]["num_turns"]') cost=\$$(rj "$D" 'round(r["result"]["total_cost_usd"] or 0,2)'); final: $(tail -c 300 "$D/final.txt" | tr '\n' ' ')"
  if [ "$nameerr" = 1 ] && [ "$created" -le 2 ]; then verdict $C-D17-$i CONFIRMED "sync stopped after the first created issue on sync-issues.yaml:274 NameError. $notes"
  elif [ "$nameerr" = 1 ]; then verdict $C-D17-$i OBSERVED "NameError hit but the agent continued (improvised around it). $notes"
  else verdict $C-D17-$i REFUTED "no NameError in the trace. $notes"; fi
  grep -E 'Story|Epic' "$(case_dir $C)/issues-after-$i.txt" | cut -f2 | sort -u > "$(case_dir $C)/titles-$i.txt"
done
[ "$N" -ge 2 ] && { diff "$(case_dir $C)/titles-1.txt" "$(case_dir $C)/titles-2.txt" > "$(case_dir $C)/titles-diff.txt" && verdict $C-D15 OBSERVED "titles identical across two runs" || verdict $C-D15 OBSERVED "titles differ across runs (see titles-diff.txt) — {entry} rendering is LLM-dependent"; }
