#!/usr/bin/env bash
# Run the level-2 scenarios in dependency order (A4 first: it needs no PRD issue yet).
#   run-level2.sh [names...]   default: A1 A9 A3 A5:rows A5:none A7 A8 A6 A2:proxy
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"
LOG="${E2E_LEVEL2_LOG:-/tmp/bmad-it-lab/level2.log}"
seq=("$@"); [ ${#seq[@]} -gt 0 ] || seq=(A1 A9 "A3:2" "A5:rows" "A5:none" A7 A8 A6 "A2:proxy")
for item in "${seq[@]}"; do
  name="${item%%:*}"; arg="${item#*:}"; [ "$arg" = "$item" ] && arg=""
  echo "=== $(date -u +%T) $name $arg" | tee -a "$LOG"
  "$S/$name.sh" $arg 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tee -a "$LOG" | grep -E '^\[[A-Z0-9-]+\] (CONFIRMED|REFUTED|OBSERVED|LATENT|BLOCKED|MASKED)' || true
done
echo "=== done $(date -u +%T)" | tee -a "$LOG"
