#!/usr/bin/env bash
# A9 — the .bmad-ci-handled marker: the bmad-build-auto hook must do nothing but `pwd` + `cat`.
set -uo pipefail; . "$(dirname "$0")/_lib.sh"; C=A9
WT="$(story_worktree 1-1-login-form)"; write_spec "$WT" in-review rows >/dev/null
echo "bmad-build-converge" > "$WT/.bmad-ci-handled"
D="$("$E2E_ROOT/run-hook.sh" --case $C --worktree "$WT" --toml bmad-build-auto --var "spec_file=$SPEC_REL" --tag marker)"
rm -f "$WT/.bmad-ci-handled"
n="$(rj "$D" 'r["bash_commands"]')"
if [ "${n:-9}" -le 3 ] && ! ran "$D" 'git push|gh (issue|pr|run)'; then verdict $C OBSERVED "marker honoured: $n Bash command(s), no push/issue/PR. improvised=$(rj "$D" 'r.get("improvised")')"
else verdict $C OBSERVED "marker present but $n Bash commands ran — inspect commands.txt"; fi
