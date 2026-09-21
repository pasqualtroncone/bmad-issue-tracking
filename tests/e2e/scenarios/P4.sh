#!/usr/bin/env bash
# P4 — REAL BMM: /bmad-build on story 1-1 in its worktree (interactive dispatcher, real spec
# written by the skill → D21 with the real template; D16 if the agent answers yes to merge).
#   P4.sh [story_key]   default 1-1-login-form; ci/outcome=pass
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=P4; KEY="${1:-1-1-login-form}"
WT="$(story_worktree "$KEY")"; set_outcome "$WT" pass; ( cd "$WT" && git push -q )
ANS="story = $KEY (sprint mode, from sprint-status.yaml); implement the minimal change in src/login.py; approve the plan; when the review loop asks, accept the findings and finish; when the module asks 'Merge the story MR now? (yes/no)' answer no."
D="$("$E2E_ROOT/run-skill.sh" --case $C --cwd "$WT" --skill bmad-build --answers "$ANS" --entry common/post-build-dispatch-interactive.yaml --tag "$KEY")"
issue_titles "prd:$PRD_KEY" > "$(case_dir $C)/issues-after.txt"
ls "$WT/$IMPLEMENTATION"/spec-* > "$(case_dir $C)/specs.txt" 2>&1
# EXACT title, not a prefix (#85, the A5.sh fix of #80): `Story 1.1.` also matches
# `Story 1.10: Login Form Extended`, the prefix-collision fixture d19/g06 seeds, and the
# listing is newest-first — so the line reported the wrong issue (OPEN, status:backlog)
# while the hook had worked on the right one. The title is the identity create-issue
# dedupes by, so it is rebuilt from the key and matched whole.
TITLE="$(uv run --no-project python -c 'import sys; p=sys.argv[1].split("-"); print("Story %s.%s: %s" % (p[0], p[1], " ".join(w.capitalize() for w in p[2:])))' "$KEY")"
ROW="$(awk -F'\t' -v t="$TITLE" '$2 == t' "$(case_dir $C)/issues-after.txt" | head -1)"
verdict $C OBSERVED "spec(s): $(tr '\n' ' ' < "$(case_dir $C)/specs.txt"); story issue '$TITLE': ${ROW:-(no issue with that title)}; ci-status=$(cat "$WT/ci-status.json" 2>/dev/null || echo absent); improvised=$(rj "$D" 'r.get("improvised")') turns=$(rj "$D" 'r["result"]["num_turns"]')"
