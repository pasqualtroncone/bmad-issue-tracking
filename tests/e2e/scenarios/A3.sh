#!/usr/bin/env bash
# A3 — full sync (/bmad-issue-tracking-sync: prepare.yaml then sync.yaml) from the PRD
# worktree with the fixture sprint-status (7 entries). Regression check for D17: the
# counter increment carries its own `import sys`, so the sync must walk every entry
# instead of halting on a NameError after the first created issue. Also observes D15
# ({entry} rendering), D19 and D21 (titles).
#   A3.sh [repeat]   repeat=2 runs it twice to compare {entry} handling
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A3; N="${1:-1}"
WT="$(prd_worktree)"
# the increment's line is located, never spelled out: it has moved once already
INCL="$(grep -n 'n = int(sys.argv\[1\]) + 1' "$WF/common/sync-issues.yaml" | head -1 | cut -d: -f1)"
TEXT="$(sed -n '/^## Instructions/,/^## Unattended/p' "$MOD/skills/bmad-issue-tracking-sync/SKILL.md" | grep -E '^[0-9]+\. ' )"
for i in $(seq 1 "$N"); do
  story_issues > "$(case_dir $C)/issues-before-$i.txt"
  D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --text "$TEXT" --entry issue-sync/sync.yaml --tag "sync-$i")"
  story_issues > "$(case_dir $C)/issues-after-$i.txt"
  created=$(( $(wc -l < "$(case_dir $C)/issues-after-$i.txt") - $(wc -l < "$(case_dir $C)/issues-before-$i.txt") ))
  entries=$(grep -cE '^  [0-9a-z-]+: ' "$WT/$IMPLEMENTATION/sprint-status.yaml")
  nameerr=0; saw "$D" "NameError: name 'sys' is not defined" && nameerr=1
  notes="run $i: entries=$entries created=$created NameError-seen=$nameerr improvised=$(rj "$D" 'r.get("improvised")')/$(rj "$D" 'r["bash_commands"]') turns=$(rj "$D" 'r["result"]["num_turns"]'); final: $(tail -c 300 "$D/final.txt" | tr '\n' ' ')"
  if [ "$nameerr" = 1 ] && [ "$created" -le 2 ]; then verdict $C-D17-$i CONFIRMED "sync stopped after the first created issue on a NameError from the counter increment (sync-issues.yaml:${INCL:-?}). $notes"
  elif [ "$nameerr" = 1 ]; then verdict $C-D17-$i OBSERVED "NameError hit but the agent continued (improvised around it). $notes"
  else verdict $C-D17-$i REFUTED "no NameError in the trace: the increment at sync-issues.yaml:${INCL:-?} imports sys, so the sync walks every entry. $notes"; fi
  grep -E 'Story|Epic' "$(case_dir $C)/issues-after-$i.txt" | cut -f2 | sort -u > "$(case_dir $C)/titles-$i.txt"
done
[ "$N" -ge 2 ] && { diff "$(case_dir $C)/titles-1.txt" "$(case_dir $C)/titles-2.txt" > "$(case_dir $C)/titles-diff.txt" && verdict $C-D15 OBSERVED "titles identical across two runs" || verdict $C-D15 OBSERVED "titles differ across runs (see titles-diff.txt) — {entry} rendering is LLM-dependent"; }
