#!/usr/bin/env bash
# P5 — REAL BMM: /bmad-build on 1-2 while 1-1's branch is RED (ci/outcome=fail pushed last)
# → D02 in the real flow: the 1-2 hook reads the repo-wide latest run (1-1, failure).
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=P5
W1="$(story_worktree 1-1-login-form)"; set_outcome "$W1" fail; ( cd "$W1" && git commit -q --allow-empty -m "P5: make 1-1 red" && git push -q )
log "waiting for the red run on 1-1…"; wait_run "feat/$PRD_KEY/1-1-login-form" 600 >/dev/null || true
W2="$(story_worktree 1-2-logout)"; set_outcome "$W2" pass; ( cd "$W2" && git push -q )
[ -n "$(pr_for "feat/$PRD_KEY/1-2-logout")" ] || gh pr create -R "$REPO_GH" --title "Story 1.2: 1-2-logout" --body "Sprint key: 1-2-logout" --base "feat/$PRD_KEY/prd" --head "feat/$PRD_KEY/1-2-logout" >/dev/null
ANS="story = 1-2-logout (sprint mode); implement a minimal logout() in src/login.py; approve the plan; accept review findings; answer no to any merge question."
D="$("$E2E_ROOT/run-skill.sh" --case $C --cwd "$W2" --skill bmad-build --answers "$ANS" --entry common/post-build-dispatch-interactive.yaml --tag 1-2-with-1-1-red)"
ci="$(cat "$W2/ci-status.json" 2>/dev/null || echo absent)"
if [ "$ci" != absent ] && printf '%s' "$ci" | grep -q red; then verdict $C-D02 CONFIRMED "1-2 (green branch) got ci-status red: the hook read the repo-wide latest run (1-1 red). ci=$ci improvised=$(rj "$D" 'r.get("improvised")')"
else verdict $C-D02 OBSERVED "ci-status=$ci — check gh-runs.json in the snapshot and commands.txt for --branch usage. improvised=$(rj "$D" 'r.get("improvised")')"; fi
set_outcome "$W1" pass; ( cd "$W1" && git push -q )
