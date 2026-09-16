#!/usr/bin/env bash
# Sourced by every scenario: loads the lab and defines verdict helpers over a run dir.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_lab
SPEC_REL="$IMPLEMENTATION/spec-1-1-login-form.md"

# rj <run-dir> <jq-ish python expr over result.json>  e.g. rj "$D" 'r["improvised"]'
rj() { uv run --no-project python -c 'import json,sys; r=json.load(open(sys.argv[1]+"/result.json")); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
# ran <run-dir> <regex> — did any executed Bash command match?
ran() { grep -qE -- "$2" "$1/commands.txt"; }
# errs <run-dir> <regex> — did any tool result (error or not) contain the text?
saw() { grep -qE -- "$2" "$1/tool-results.txt"; }
# story issue titles for the lab prd
story_issues() { issue_titles "prd:$PRD_KEY"; }
# pr_for <branch> → number or empty
pr_for() { gh pr list -R "$REPO_GH" --state all --head "$1" --json number --jq '.[0].number // empty'; }
