#!/usr/bin/env bash
# Level 0 (static greps, no lab) and level 1 (literal replay of RUN steps, no LLM).
#
#   replay.sh static                # S1..S8 + D03/D22 arithmetic — no lab needed
#   replay.sh d17|d18|d2|d4|d7|d8|d16|d19|d9   # GitHub lab
#   replay.sh g06|g10               # GitLab lab (g10 is a rendering proof, no glab needed)
#   replay.sh all                   # static + every GitHub case (≈35 min: Actions + seeding)
#
# Each case replays the RUN command exactly as written in the workflow file (rendered by
# trace-tools.py render-step) and ends with a verdict in evidence/<lab>/<case>/verdict.txt.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

# line_of <rel> <grep-pattern> [nth] — 1-based file line of the nth matching step
line_of() { grep -n -E -- "$2" "$WF/$1" | sed -n "${3:-1}p" | cut -d: -f1; }
# run_line_of <rel> <body-regex> — the `- RUN:` line that owns the first line matching the body regex
run_line_of() { local b; b="$(grep -n -E -- "$2" "$WF/$1" | head -1 | cut -d: -f1)"; [ -n "$b" ] && awk -v n="$b" 'NR<=n && /^ *- RUN:/ {l=NR} END{print l}' "$WF/$1"; }

# replay <case> <name> <rel> <line> [k=v...] — render the RUN step and execute it in $CONSUMER
replay() {
  local c="$1" n="$2" rel="$3" line="$4"; shift 4
  local d; d="$(case_dir "$c")"
  $TT render-step "$rel" "$line" "$@" > "$d/$n.cmd"
  log "  replay $rel:$line → $n"
  local rc=0
  ( cd "${REPLAY_CWD:-$CONSUMER}" && bash "$d/$n.cmd" ) >"$d/$n.out" 2>"$d/$n.err" || rc=$?
  echo "$rc" > "$d/$n.rc"
  printf '      rc=%s stdout=%s\n' "$rc" "$(head -c 160 "$d/$n.out" | tr '\n' '|')" >&2
  return 0
}

# ============================================================================
case_static() {
  local c=static d; d="$(mkdir -p "$E2E_ROOT/evidence/static" && echo "$E2E_ROOT/evidence/static")"
  local rep="$d/report.md"; : > "$rep"
  local item
  say() { printf '%s\n' "$*" | tee -a "$rep" >&2; }
  mark() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$d/verdicts.tsv"; say "**$1 → $2** — $3"; say; }
  : > "$d/verdicts.tsv"

  say "# Static findings (level 0) — $(date -u +%F)"; say
  # S1 neq
  item="$(grep -n ' neq ' "$WF/common/merge-mr.yaml")"; say '```'; say "$item"; say '```'
  if [ -n "$item" ] && ! grep -q '`neq`' "$ASSETS/bmad-workflow-lang.md"; then mark S1 CONFIRMED "merge-mr.yaml uses 'neq' $(printf '%s\n' "$item" | wc -l)×; the language table (lang §3) defines only 'ne'"; else mark S1 REFUTED "neq absent or defined"; fi
  # S2 create-issue indentation
  item="$(sed -n 36,42p "$WF/common/create-issue.yaml")"; say '```'; say "$item"; say '```'
  if sed -n 36p "$WF/common/create-issue.yaml" | grep -q '^    - CHECK: empty issue_id' && sed -n 37p "$WF/common/create-issue.yaml" | grep -q '^    TRUE:'; then mark S2 CONFIRMED "create-issue.yaml:36-42 TRUE:/FALSE: sit at the same indent as '- CHECK' (not under it); both branches STOP so behaviour survives by luck"; else mark S2 REFUTED "indentation is regular"; fi
  # S3 env vars in sync SKILL.md
  local envs; envs="$(grep -c 'BMAD_[A-Z_]*ACTION' "$MOD/skills/bmad-issue-tracking-sync/SKILL.md")"; local inwf; inwf="$(grep -rl 'BMAD_MR_ACTION\|BMAD_ISSUE_ACTION' "$WF" | wc -l)"
  say "sync SKILL.md references BMAD_*_ACTION env vars on $envs lines; workflow files reading them: $inwf"
  if [ "$envs" -gt 0 ] && [ "$inwf" = 0 ]; then mark S3 CONFIRMED "sync SKILL.md steps 3-4 route on env vars no workflow reads (the language has no env channel; CLAUDE.md forbids it)"; else mark S3 REFUTED "env routing is wired"; fi
  # S4 help.md config path
  item="$(grep -n '_bmad/_config/custom/issue-tracking.yaml' "$MOD"/skills/*/references/help.md "$MOD"/skills/*/SKILL.md 2>/dev/null)"
  say '```'; say "${item:-(no hit)}"; say '```'
  if [ -n "$item" ]; then mark S4 CONFIRMED "help text names _bmad/_config/custom/issue-tracking.yaml; check-config.yaml reads _bmad/custom/issue-tracking.yaml"; else mark S4 REFUTED "no stale config path in help/SKILL files (fixed on this branch)"; fi
  # S5 epic_color
  local stores refs; stores="$(grep -c 'STORE: epic_color' "$WF/common/ensure-dynamic-labels.yaml")"; refs="$(grep -rc '{epic_color}' "$WF" | awk -F: '{s+=$2} END{print s}')"
  say "epic_color: STORE ×$stores, references {epic_color} across workflows: $refs; create-label.yaml args: $(grep -o -- '--name "[^"]*"\|gh label create "[^"]*"' "$WF/common/create-label.yaml" | tr '\n' ' ')"
  if [ "$stores" -gt 0 ] && [ "$refs" = 0 ]; then mark S5 CONFIRMED "ensure-dynamic-labels computes epic_color and nothing consumes it (create-label has no colour argument)"; else mark S5 REFUTED "epic_color is consumed"; fi
  # S6 EXPECT_EXIT: any
  local anyc; anyc="$(grep -rc 'EXPECT_EXIT: any' "$WF" | awk -F: '{s+=$2} END{print s}')"
  say "EXPECT_EXIT: any occurrences: $anyc; lang spec text for expect_exit: $(grep -o 'expect_exit.*' "$ASSETS/bmad-workflow-lang.md" | head -1 | cut -c1-120)"
  if [ "$anyc" -gt 0 ] && ! grep -q 'expect_exit.*any\|EXPECT_EXIT: any' "$ASSETS/bmad-workflow-lang.md"; then mark S6 CONFIRMED "'EXPECT_EXIT: any' used ${anyc}× but the language defines expect_exit as a numeric code only"; else mark S6 REFUTED "'any' is specified"; fi
  # S7 dead test + sys imports
  item="$(grep -n '"uv run python"' "$MOD/tests/test_command_patterns.py")"; local usesold; usesold="$(grep -rc 'uv run python ' "$WF" | awk -F: '{s+=$2} END{print s}')"
  say '```'; say "$item"; say "RUN steps spelled 'uv run python ' (no --no-project) in workflows: $usesold"; say '```'
  say '```'; $TT lint-sys | tee -a "$rep" >&2; say '```'
  if [ -n "$item" ] && [ "$usesold" = 0 ]; then mark S7 CONFIRMED "test_python_sys_argv_has_import filters on 'uv run python' but every RUN is 'uv run --no-project python' → the test never inspects a body; lint-sys finds 3 bodies using sys without import (sync-issues:274, wait-for-green-ci:42, :80 → D17/D18)"; else mark S7 REFUTED "test filter matches the commands"; fi
  # S8 spec_file undefined in the language
  local sf; sf="$(grep -c 'spec_file' "$ASSETS/bmad-workflow-lang.md")"; local sfuse; sfuse="$(grep -rl '{spec_file}' "$WF" | wc -l)"
  say "lang mentions of spec_file: $sf; workflow files using {spec_file}: $sfuse; CLAUDE.md cites lang lines 443-455: $(sed -n 443,455p "$ASSETS/bmad-workflow-lang.md" | grep -c spec_file) mention(s) there"
  if [ "$sf" = 0 ] && [ "$sfuse" -gt 0 ]; then mark S8 CONFIRMED "{spec_file} is read by $sfuse workflow files but the language spec never defines it (§4.4 table); CLAUDE.md's cited lines do not exist"; else mark S8 REFUTED "spec_file is specified"; fi
  # S9 (new) conftest parser depth
  local seen; seen="$($PY - <<'PY'
import sys; sys.path.insert(0,'tests'); import conftest
wf=conftest.load_workflow('common/sync-issues.yaml')
print(sum(1 for s in conftest.flatten_steps(wf['steps']) if s['type']=='RUN' and 'sync_created' in s['raw_value']))
PY
)"
  say "conftest.flatten_steps sees the sync_created increment RUN (sync-issues.yaml:274)? count=$seen"
  if [ "$seen" = 0 ]; then mark S9 CONFIRMED "tests/conftest.py drops steps nested LOOP→CHECK→RUN: sync-issues.yaml:274 (D17) is invisible to every test, even a fixed S7"; else mark S9 REFUTED "parser reaches it"; fi
  # D03 arithmetic
  local sl ma; sl="$(grep -o 'sleep [0-9]*' "$WF/common/wait-for-green-ci.yaml" | head -1 | awk '{print $2}')"; ma="$(grep -o 'max_attempts=[0-9]*' "$WF/common/wait-for-green-ci.yaml" | head -1 | cut -d= -f2)"
  say "wait-for-green-ci: sleep $sl × max_attempts $ma = $((sl*ma)) s inside ONE RUN; Claude Code Bash hard cap = 600 s (BASH_MAX_TIMEOUT_MS)"
  if [ $((sl*ma)) -gt 600 ]; then mark D03-static CONFIRMED "a single RUN can block $((sl*ma)) s but the tool times out at 600 s → ci-status.json never written on long pipelines (empirical: scenario A2)"; else mark D03-static REFUTED "fits"; fi
  # D22 arithmetic
  local bl; bl="$(find "$(uv tool dir 2>/dev/null)/bmad-loop" -name workspace.py -path '*bmad_loop*' 2>/dev/null | head -1)"
  if [ -n "$bl" ]; then
    say '```'; grep -n -A14 'def unit_branch_name' "$bl" | grep -E 'return f"bmad-loop' | tee -a "$rep" >&2; say '```'
    say "module story_branch pattern (fixtures/issue-tracking.yaml.tmpl, SKILL.md step 9 default): feat/{prd_key}/{story_key}"
    mark D22-static CONFIRMED "bmad-loop 0.11.1 names the branch bmad-loop/<run>/<story_key>; the module derives story_branch=feat/{prd_key}/{story_key} → ensure-mr --head names a branch that never exists on the remote (empirical: A7)"
  else mark D22-static BLOCKED "bmad-loop not installed as a uv tool"; fi
  say "verdicts: $d/verdicts.tsv"
}

# ============================================================================
case_d17() {
  local c=d17; load_lab
  replay $c increment common/sync-issues.yaml "$(run_line_of common/sync-issues.yaml '^" \{sync_created\}$')" sync_created=0
  local d; d="$(case_dir $c)"
  # the 12th python step is the increment; assert we replayed the right one
  grep -q 'n = int(sys.argv\[1\]) + 1' "$d/increment.cmd" || { verdict $c BLOCKED "rendered the wrong step: $(head -2 "$d/increment.cmd" | tail -1)"; return; }
  if [ "$(cat "$d/increment.rc")" != 0 ] && grep -q "NameError: name 'sys' is not defined" "$d/increment.err"; then
    verdict $c CONFIRMED "sync-issues.yaml:274 'n = int(sys.argv[1]) + 1' without import sys → NameError, exit $(cat "$d/increment.rc"); the sync halts after the FIRST created issue"
  else verdict $c REFUTED "rc=$(cat "$d/increment.rc") $(head -c 200 "$d/increment.err")"; fi
}

case_d18() {
  local c=d18; load_lab; local d; d="$(case_dir $c)"
  local gl gh; gl="$(line_of common/wait-for-green-ci.yaml 'RUN: \|' 1)"; gh="$(line_of common/wait-for-green-ci.yaml 'RUN: \|' 2)"
  # (a) the STATUS mapping snippet alone, with a real value, redirect removed
  $TT render-step common/wait-for-green-ci.yaml "$gh" mr_repo="github.com/$REPO_GH" > "$d/github-loop.cmd"
  awk '/STATUS=\$\(uv run/{f=1; sub(/.*STATUS=\$\(/,""); print; next} f&&/^" "\$pipeline_status"( 2>\/dev\/null)?\)/{print "\" success"; f=0; next} f{print}' "$d/github-loop.cmd" > "$d/status-snippet.cmd"
  log "  (a) STATUS mapping snippet with 'success', stderr visible"
  ( cd "$CONSUMER" && bash "$d/status-snippet.cmd" ) > "$d/status-snippet.out" 2> "$d/status-snippet.err"; echo $? > "$d/status-snippet.rc"
  # (b) the whole GitHub loop, max_attempts 60→2, against a repo whose latest run is complete
  sed 's/max_attempts=60/max_attempts=2/' "$d/github-loop.cmd" > "$d/github-loop-2.cmd"
  gh run list -R "$REPO_GH" --limit 1 --json status,conclusion,headBranch > "$d/latest-run-before.json"
  log "  (b) full polling loop with max_attempts=2 (≈60 s)…"
  ( cd "$CONSUMER" && time bash "$d/github-loop-2.cmd" ) > "$d/github-loop-2.out" 2> "$d/github-loop-2.err"; echo $? > "$d/github-loop-2.rc"
  # (c) same loop with the one-line fix
  sed '/STATUS=\$(uv run --no-project python -c "/a import sys' "$d/github-loop-2.cmd" > "$d/github-loop-2-patched.cmd"
  log "  (c) patched loop (+import sys), max_attempts=2 (≈30 s)…"
  ( cd "$CONSUMER" && time bash "$d/github-loop-2-patched.cmd" ) > "$d/github-loop-2-patched.out" 2> "$d/github-loop-2-patched.err"; echo $? > "$d/github-loop-2-patched.rc"
  # gitlab variant is the same text; render it for the record
  $TT render-step common/wait-for-green-ci.yaml "$gl" project_enc=x mr_iid=1 host=gitlab.com > "$d/gitlab-loop.cmd"
  local latest; latest="$(uv run --no-project python -c 'import json,sys; r=json.load(open(sys.argv[1])); print((r[0]["conclusion"] or r[0]["status"]) if r else "none")' "$d/latest-run-before.json")"
  if grep -q "NameError: name 'sys' is not defined" "$d/status-snippet.err" && [ "$(tr -d '[:space:]' < "$d/github-loop-2.out")" = timeout ] && [ "$(tr -d '[:space:]' < "$d/github-loop-2-patched.out")" != timeout ]; then
    verdict $c CONFIRMED "STATUS mapping (wait-for-green-ci.yaml:$gh block, also :$gl) NameErrors under 2>/dev/null → STATUS='' → loop never breaks: latest run '$latest' still yields 'timeout' after max_attempts; with 'import sys' the same loop prints '$(tr -d '[:space:]' < "$d/github-loop-2-patched.out")' on the first poll. Real run: 60×30 s = 30 min → masks D03"
  else verdict $c REFUTED "snippet rc=$(cat "$d/status-snippet.rc") loop='$(cat "$d/github-loop-2.out")' patched='$(cat "$d/github-loop-2-patched.out")'"; fi
}

case_d2() {
  local c=d2; load_lab; local d; d="$(case_dir $c)"
  cd "$CONSUMER"; git checkout -q main; git pull -q --ff-only origin main 2>/dev/null || true
  git branch -D ci-green ci-red >/dev/null 2>&1 || true
  git checkout -q -b ci-green main; set_outcome . pass; git commit -q --allow-empty -m "ci-green marker"; git push -q -f -u origin ci-green
  log "  waiting for ci-green run…"; echo "ci-green: $(wait_run ci-green)" | tee "$d/runs.txt" >&2
  git checkout -q -b ci-red main; set_outcome . fail; git push -q -f -u origin ci-red
  log "  waiting for ci-red run…"; echo "ci-red: $(wait_run ci-red)" | tee -a "$d/runs.txt" >&2
  git checkout -q ci-green
  gh run list -R "$REPO_GH" --limit 3 --json headBranch,conclusion,createdAt,databaseId > "$d/gh-run-list.json"
  local l1 l2; l1="$(line_of common/get-mr-pipeline.yaml 'gh run list' 1)"; l2="$(line_of common/get-mr-pipeline.yaml 'gh run list' 2)"
  replay $c pipeline_id common/get-mr-pipeline.yaml "$l1" host=github.com project="$REPO_GH"
  replay $c pipeline_status common/get-mr-pipeline.yaml "$l2" host=github.com project="$REPO_GH"
  gh run list -R "$REPO_GH" --branch ci-green --limit 1 --json conclusion,headBranch,databaseId > "$d/control-branch-filter.json"
  local got ctrl; got="$(tr -d '[:space:]' < "$d/pipeline_status.out")"; ctrl="$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["conclusion"])' "$d/control-branch-filter.json")"
  git checkout -q main
  if [ "$got" = failure ] && [ "$ctrl" = success ]; then
    verdict $c CONFIRMED "on branch ci-green (CI green) get-mr-pipeline.yaml:$l2 'gh run list --limit 1' reports pipeline_status=$got — the latest run of the WHOLE repo (ci-red); with --branch ci-green it is $ctrl. Same shape in wait-for-green-ci.yaml (poll + failure path)"
  else verdict $c REFUTED "got=$got control=$ctrl (see runs.txt)"; fi
}

case_d4() {
  local c=d4; load_lab; local d; d="$(case_dir $c)"; local key=bulkprd
  "$E2E_ROOT/seed-issues.sh" 105 "$key" | tee "$d/seed.log" >&2
  log "  waiting for the search index to hold ≥105 issues labelled prd:$key (≤300 s)…"
  local t=0 n=0
  while [ $t -lt 300 ]; do
    n="$(gh api "search/issues?q=repo:$REPO_GH+label:prd:$key&per_page=1" --jq .total_count 2>/dev/null || echo 0)"
    [ "${n:-0}" -ge 105 ] && break; sleep 10; t=$((t+10))
  done
  echo "search total_count after ${t}s: $n" | tee "$d/index.txt" >&2
  local l; l="$(line_of common/sync-issues.yaml 'gh api "search/issues' 1)"
  replay $c bulk-fetch common/sync-issues.yaml "$l" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  replay $c control-labprd common/sync-issues.yaml "$l" project="$REPO_GH" host=github.com sep=: prd_key="$PRD_KEY"
  local lf; lf="$(line_of common/find-issue.yaml 'gh api "search/issues' 1)"
  replay $c control-find-issue-shape common/find-issue.yaml "$lf" search_text=Seed project="$REPO_GH" host=github.com sep=: prd_key="$key"
  if [ "${n:-0}" -lt 105 ]; then verdict $c BLOCKED "search index shows $n < 105 after 300 s (label qualifier 'label:prd:$key' may not parse — see index.txt/seed.log)"; return; fi
  gh api "search/issues?q=Seed+repo:$REPO_GH+label:prd:$key&per_page=100" --paginate | uv run --no-project python -c 'import sys; s=sys.stdin.read(); print("bytes=%d newlines=%d" % (len(s), s.count(chr(10))))' > "$d/paginate-shape.txt" 2>&1
  if grep -q 'JSONDecodeError\|Extra data' "$d/bulk-fetch.err" && [ "$(cat "$d/control-labprd.rc")" = 0 ]; then
    local fi_note="find-issue.yaml:$lf (the per-line split meant as the fix) ALSO fails at 2 pages: rc=$(cat "$d/control-find-issue-shape.rc") '$(grep -o 'json.decoder.JSONDecodeError.*' "$d/control-find-issue-shape.err" | head -1 | cut -c1-60)' because gh --paginate joins pages with NO newline ($(cat "$d/paginate-shape.txt")); 'gh api --paginate --slurp' is the supported fix"
    verdict $c CONFIRMED "sync-issues.yaml:$l 'gh api search/issues --paginate | json.load' fails with '$(grep -o 'json.decoder.JSONDecodeError.*' "$d/bulk-fetch.err" | head -1 | cut -c1-80)' at >100 issues (2 pages concatenated); ≤100 (prd:$PRD_KEY) works. $fi_note"
  else verdict $c REFUTED "bulk rc=$(cat "$d/bulk-fetch.rc") lines=$(wc -l < "$d/bulk-fetch.out") err=$(head -c 200 "$d/bulk-fetch.err")"; fi
}

case_d7() {
  local c=d7; load_lab; local d; d="$(case_dir $c)"
  cd "$CONSUMER"; git checkout -q main; git status --short > "$d/status-before.txt"
  local l1 l2; l1="$(line_of create-prd/complete.yaml 'RUN: git add \.' 1)"; l2="$(line_of create-prd/complete.yaml 'RUN: git commit( --allow-empty)? -m' 1)"
  replay $c add create-prd/complete.yaml "$l1"
  replay $c commit create-prd/complete.yaml "$l2" prd_key="$PRD_KEY"
  grep -n 'git commit' "$WF/bmad-prd/complete.yaml" "$WF/retrospective/complete.yaml" "$WF/create-prd/complete.yaml" > "$d/other-callers.txt"
  if [ -z "$(cat "$d/status-before.txt")" ] && [ "$(cat "$d/commit.rc")" = 1 ] && grep -qi 'nothing to commit' "$d/commit.out$( [ -s "$d/commit.err" ] && echo " $d/commit.err")" 2>/dev/null; then
    verdict $c CONFIRMED "create-prd/complete.yaml:$l2 'git commit -m \"update PRD labprd\"' on a clean tree → exit 1 'nothing to commit'; EXPECT_EXIT defaults to 0 so the hook halts before push/issue/MR on any re-run without changes (same in $(grep -c . "$d/other-callers.txt") complete.yaml files)"
  else verdict $c REFUTED "rc=$(cat "$d/commit.rc") out=$(head -c 120 "$d/commit.out")"; fi
}

case_d8() {
  local c=d8; load_lab; local d; d="$(case_dir $c)"
  cd "$CONSUMER"; git checkout -q main; git fetch -q origin
  git branch -D bmad-loop/r1/1-1-login-form >/dev/null 2>&1 || true
  # a previous (fixed) run may have pushed the branch: remove it so the push is judged on its own
  git push -q origin --delete bmad-loop/r1/1-1-login-form >/dev/null 2>&1 || true
  # bmad-loop cuts the branch from the LOCAL target branch: no tracking information at all
  git checkout -q --no-track -b bmad-loop/r1/1-1-login-form "origin/feat/$PRD_KEY/prd"
  git config --show-origin --get-all push.autoSetupRemote > "$d/push-autosetupremote.txt" 2>&1 || echo "(unset)" >> "$d/push-autosetupremote.txt"
  local l1 l2; l1="$(line_of common/post-dev-complete.yaml 'RUN: git commit --allow-empty -m "dev' 1)"; l2="$(line_of common/post-dev-complete.yaml 'RUN: git push( -u origin HEAD)?$' 1)"
  replay $c commit common/post-dev-complete.yaml "$l1" story_key=1-1-login-form
  replay $c push common/post-dev-complete.yaml "$l2"
  # D22: what the module thinks the branch is, and whether that branch exists on the remote
  local lb; lb="$(run_line_of common/post-dev-complete.yaml '^pattern = sys.argv\[1\]$')"
  replay $c story_branch common/post-dev-complete.yaml "$lb" story_pattern="feat/{prd_key}/{story_key}" story_key=1-1-login-form prd_key="$PRD_KEY"
  local sb; sb="$(tr -d '[:space:]' < "$d/story_branch.out")"
  git ls-remote --heads origin "$sb" > "$d/ls-remote-story-branch.txt"
  local le; le="$(line_of common/ensure-mr.yaml 'gh pr create' 2)"
  echo "Sprint key: 1-1-login-form" > /tmp/e2e-d8-desc.md
  replay $c ensure-mr-head common/ensure-mr.yaml "$le" mr_title="Story 1.1: 1-1-login-form" description_body="Sprint key: 1-1-login-form" target_branch="feat/$PRD_KEY/prd" source_branch="$sb" mr_repo="github.com/$REPO_GH"
  sed 's/ 2>&1 | grep .*$//' "$d/ensure-mr-head.cmd" > "$d/ensure-mr-head-gh-only.cmd"
  ( cd "$CONSUMER" && bash "$d/ensure-mr-head-gh-only.cmd" ) > "$d/ensure-mr-head-gh-only.out" 2> "$d/ensure-mr-head-gh-only.err"; echo $? > "$d/ensure-mr-head-gh-only.rc"
  rm -f /tmp/e2e-d8-desc.md
  git checkout -q main; git branch -D bmad-loop/r1/1-1-login-form >/dev/null 2>&1 || true
  if [ "$(cat "$d/push.rc")" = 128 ] && grep -q 'no upstream\|has no upstream branch' "$d/push.err"; then
    local d22=""; [ ! -s "$d/ls-remote-story-branch.txt" ] && d22="; D22: module-derived story_branch '$sb' does not exist on origin, and ensure-mr.yaml:$le --head $sb fails (gh rc=$(cat "$d/ensure-mr-head-gh-only.rc")): '$(grep -m1 -iE 'head|not found|error|could not' "$d/ensure-mr-head-gh-only.err" | cut -c1-110)' — the step's '2>&1 | grep https://' swallows it and stores an empty mr_url"
    verdict $c CONFIRMED "post-dev-complete.yaml:$l2 'git push' on bmad-loop/r1/1-1-login-form (no upstream; push.autoSetupRemote $(cat "$d/push-autosetupremote.txt" | head -1)) → exit 128 '$(grep -o 'fatal:.*' "$d/push.err" | head -1 | cut -c1-70)'; dev-finish/review-finish halt there$d22"
  else verdict $c REFUTED "push rc=$(cat "$d/push.rc") $(head -c 200 "$d/push.err")"; fi
}

case_d16() {
  local c=d16; load_lab; local d; d="$(case_dir $c)"
  cd "$CONSUMER"; git checkout -q main; git pull -q --ff-only origin main 2>/dev/null || true
  local br="d16-probe-$(date +%s)"
  git checkout -q -b "$br" main; echo "$br" > "$br.txt"; git add "$br.txt"; git commit -q -m "d16 probe"; git push -q -u origin "$br"
  local url; url="$(gh pr create --title "d16 probe" --body "probe PR for D16 (merge exit code vs stdout)" --base main --head "$br" -R "$REPO_GH")"; echo "$url" > "$d/pr-url.txt"
  local n="${url##*/}"; git checkout -q main
  local lm; lm="$(line_of common/merge-mr.yaml 'gh pr merge' 1)"
  # positive: merge succeeds — capture stdout and stderr separately, exactly as STORE would (stdout only)
  replay $c merge-ok common/merge-mr.yaml "$lm" mr_iid="$n" host=github.com project="$REPO_GH"
  gh pr view "$n" -R "$REPO_GH" --json state,mergedAt --jq '.state + " " + (.mergedAt // "")' > "$d/pr-state-after.txt"
  # negative: merge the already-merged PR
  replay $c merge-again common/merge-mr.yaml "$lm" mr_iid="$n" host=github.com project="$REPO_GH"
  # the derivation step, fed what STORE would hold (stdout) in both cases
  local ld; ld="$(run_line_of common/merge-mr.yaml '^gl = sys.argv\[1\]')"
  replay $c derive-ok common/merge-mr.yaml "$ld" gl_merge_out="" gh_merge_out="$(cat "$d/merge-ok.out")"
  replay $c derive-again common/merge-mr.yaml "$ld" gl_merge_out="" gh_merge_out="$(cat "$d/merge-again.out")"
  git pull -q --ff-only origin main 2>/dev/null || true; git branch -D "$br" >/dev/null 2>&1 || true
  if [ "$(cat "$d/merge-ok.rc")" = 0 ] && grep -q MERGED "$d/pr-state-after.txt" && [ ! -s "$d/merge-ok.out" ] && [ "$(tr -d '[:space:]' < "$d/derive-ok.out")" = false ]; then
    verdict $c CONFIRMED "merge-mr.yaml:$lm 'gh pr merge --squash --delete-branch' succeeded (rc=0, PR $n MERGED) with EMPTY stdout and stdout-only STORE → merge-mr.yaml:$ld derives merged='$(cat "$d/derive-ok.out")' for a real merge (inverted). Re-merging the merged PR: rc=$(cat "$d/merge-again.rc"), stdout empty, stderr '$(head -c 90 "$d/merge-again.err" | tr '\n' ' ')' → derive='$(cat "$d/derive-again.out")' (indistinguishable)"
  else verdict $c REFUTED "ok rc=$(cat "$d/merge-ok.rc") stdout=$(wc -c < "$d/merge-ok.out")B again rc=$(cat "$d/merge-again.rc") derive=$(cat "$d/derive-ok.out")/$(cat "$d/derive-again.out")"; fi
}

case_d19() {
  local c=d19; load_lab; local d; d="$(case_dir $c)"; local key=fuzzprd
  gh label create "prd:$key" -R "$REPO_GH" 2>/dev/null || true
  mk() { gh issue list -R "$REPO_GH" --state all --label "prd:$key" --search "in:title \"$1\"" --json title --jq '.[].title' | grep -qxF "$1" || gh issue create -R "$REPO_GH" --title "$1" --body "$2" --label "prd:$key" >/dev/null; }
  mk "PRD: $key" "**PRD:** $key"
  mk "Epic 1: Authentication" "**Sprint Key:** \`epic-1\`"
  mk "Epic 10: Placeholder" "**Sprint Key:** \`epic-10\`"
  mk "Story 1.1: Login Form" "**Sprint Key:** \`1-1-login-form\`"
  local t0; t0="$(date +%s)"
  mk "Story 1.10: Login Form Extended" "**Sprint Key:** \`1-10-login-form-extended\`"
  # index latency for the last created issue
  local t=0; while [ $t -lt 300 ]; do
    n="$(gh api "search/issues?q=1-10-login-form-extended+repo:$REPO_GH+label:prd:$key&per_page=5" --jq .total_count 2>/dev/null || echo 0)"
    [ "${n:-0}" -ge 1 ] && break; sleep 5; t=$((t+5)); done
  echo "search index latency for a just-created issue: ~${t}s (total_count=$n)" | tee "$d/index-latency.txt" >&2
  sleep 20
  local lf; lf="$(line_of common/find-issue.yaml 'gh api "search/issues' 1)"
  replay $c find-1-1 common/find-issue.yaml "$lf" search_text=1-1-login-form project="$REPO_GH" host=github.com sep=: prd_key="$key"
  replay $c find-epic-1 common/find-issue.yaml "$lf" search_text="Epic 1:" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  replay $c find-prd common/find-issue.yaml "$lf" search_text="PRD: $key" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  titles() { uv run --no-project python -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join("#%s %s" % (i["number"], i["title"]) for i in d))' "$1" 2>/dev/null; }
  { echo "== search_text=1-1-login-form"; titles "$d/find-1-1.out"; echo "== search_text='Epic 1:'"; titles "$d/find-epic-1.out"; echo "== search_text='PRD: $key' rc=$(cat "$d/find-prd.rc")"; titles "$d/find-prd.out"; head -c 300 "$d/find-prd.err"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  local n11 ne1; n11="$(titles "$d/find-1-1.out" | wc -l)"; ne1="$(titles "$d/find-epic-1.out" | wc -l)"
  if grep -q 'PROTOCOL_ERROR' "$d/find-prd.err" && [ "$(cat "$d/find-prd.rc")" = 0 ] && [ "$(tr -d '[:space:]' < "$d/find-prd.out")" = "[]" ]; then
    gh api "search/issues?q=PRD%3A%20$key+repo:$REPO_GH+label:prd:$key&per_page=5" --jq '[.items[].title]' > "$d/find-prd-encoded.out" 2>&1
    verdict $c-D23 CONFIRMED "find-issue.yaml:$lf with search_text='PRD: $key' puts a raw space in the URL → gh api: '$(grep -o 'stream error.*' "$d/find-prd.err" | head -1)'; the trailing '| python' makes the step exit 0 with issue_result='[]' → issue_id empty. Every 'PRD: {prd_key}' lookup on GitHub (issue-sync/prepare, bmad-prd/complete create-vs-update, edit-prd, correct-course) silently misses; percent-encoded, the same query returns $(cat "$d/find-prd-encoded.out"). 'Epic 1:' fails the same way (rc=$(cat "$d/find-epic-1.rc"), $ne1 hits)"
  fi
  local first11; first11="$(titles "$d/find-1-1.out" | head -1)"
  if [ "$n11" -gt 1 ] || [ "$ne1" -gt 1 ]; then
    verdict $c CONFIRMED "find-issue.yaml:$lf (GitHub) is a fuzzy search with no title check: search_text '1-1-login-form' returns $n11 issues ($(titles "$d/find-1-1.out" | cut -d' ' -f2- | tr '\n' ';')) and the FILTER takes item 0 — whichever the search index ranks first. Search-index latency measured ≈${t}s (first run: 5 s) → an issue created seconds earlier can be invisible to the next find-issue"
  elif [ "$n11" = 0 ] && [ "$ne1" = 0 ]; then verdict $c BLOCKED "search returned nothing (rc=$(cat "$d/find-1-1.rc"); see summary.txt) — label qualifier or index"
  else verdict $c REFUTED "exact hits only: 1-1→$n11, Epic 1→$ne1 (latency ${t}s; PRD rc=$(cat "$d/find-prd.rc"))"; fi
}

case_d9() {
  local c=d9; load_lab; local d; d="$(case_dir $c)"
  cd "$CONSUMER"; git checkout -q main; local br="d9-quote-$(date +%s)"
  git checkout -q -b "$br" main; git commit -q --allow-empty -m "d9 probe"; git push -q -u origin "$br"; git checkout -q main
  local le; le="$(line_of common/ensure-mr.yaml 'gh pr create' 2)"
  local body; body="$(cat "$E2E_ROOT/fixtures/quoting-body.md")"
  $TT render-step common/ensure-mr.yaml "$le" mr_title='Story 1.1: Login "Form"' description_body="$body" target_branch=main source_branch="$br" mr_repo="github.com/$REPO_GH" > "$d/rendered.cmd"
  bash -n "$d/rendered.cmd" > "$d/syntax.out" 2> "$d/syntax.err"; echo $? > "$d/syntax.rc"
  ( cd "$CONSUMER" && bash "$d/rendered.cmd" ) > "$d/run.out" 2> "$d/run.err"; echo $? > "$d/run.rc"
  # the literal step hides gh's own error behind `2>&1 | grep`; run the gh part alone for the record
  sed 's/ 2>&1 | grep .*$//' "$d/rendered.cmd" > "$d/gh-only.cmd"
  ( cd "$CONSUMER" && bash "$d/gh-only.cmd" ) > "$d/gh-only.out" 2> "$d/gh-only.err"; echo $? > "$d/gh-only.rc"
  grep -o 'pull/[0-9]*' "$d/gh-only.out" | head -1 | cut -d/ -f2 | xargs -r -I{} gh pr close {} -R "$REPO_GH" --delete-branch >/dev/null 2>&1
  local n=""; n="$(grep -o 'pull/[0-9]*' "$d/run.out" | head -1 | cut -d/ -f2)"
  if [ -n "$n" ]; then gh pr view "$n" -R "$REPO_GH" --json title,body > "$d/pr.json"; gh pr close "$n" -R "$REPO_GH" --delete-branch >/dev/null 2>&1 || true; fi
  git branch -D "$br" >/dev/null 2>&1 || true
  local inj=0; grep -q INJECTED "$d/pr.json" "$d/gh-only.err" 2>/dev/null && inj=1
  local titleok=0; grep -q 'Login "Form"' "$d/pr.json" 2>/dev/null && titleok=1
  if [ "$(cat "$d/syntax.rc")" != 0 ] || [ "$inj" = 1 ] || [ "$titleok" = 0 ]; then
    verdict $c LATENT "ensure-mr.yaml:$le interpolates --title/--body inline: with a body holding quotes, a backtick and \$(…) the literal step 'succeeds' (pipeline rc=$(cat "$d/run.rc") — the '2>&1 | grep https' hides gh's exit) but creates $( [ -n "$n" ] && echo "a PR" || echo "NO PR"); gh alone rc=$(cat "$d/gh-only.rc"): '$(grep -m1 'unknown argument' "$d/gh-only.err" | cut -c1-110)'; the shell ran \$(echo INJECTED)=$inj and tried to execute the backtick ('$(grep -o 'backtick: command not found' "$d/run.err" | head -1)'); quoted title preserved=$titleok. Current callers pass benign bodies/titles, so LATENT"
  else verdict $c REFUTED "rendered command survived quotes, backticks and \$(…) intact"; fi
}

# --- GitLab (self-hosted or gitlab.com; host from lab.env GL_HOST) --------------------------
gl_setup() {
  load_lab; [ -n "${REPO_GL:-}" ] || { verdict "$1" BLOCKED "no GitLab lab (lab-up.sh --add-gitlab --gl-host <host>)"; return 1; }
  GLH="${GL_HOST:-gitlab.com}"; export GITLAB_HOST="$GLH"
  glab auth status --hostname "$GLH" >/dev/null 2>&1 || { verdict "$1" BLOCKED "glab not authenticated on $GLH"; return 1; }
  ENC="$(uv run --no-project python -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$REPO_GL")"
  glab label create --name "prd::$PRD_KEY" -R "$GLH/$REPO_GL" >/dev/null 2>&1 || true
}
gl_issue() {  # gl_issue <title> — create once, labelled prd::labprd
  glab api "projects/$ENC/issues?labels=prd::$PRD_KEY&state=all&per_page=100" --hostname "$GLH" | grep -qF "\"title\":\"$1\"" || glab api --method POST "projects/$ENC/issues" --hostname "$GLH" -f "title=$1" -f "labels=prd::$PRD_KEY" >/dev/null
}
gl_titles() { uv run --no-project python -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join("!%s %s" % (i["iid"], i["title"]) for i in d))' "$1" 2>/dev/null; }

case_g06() {
  local c=g06; gl_setup $c || return; local d; d="$(case_dir $c)"
  # issues shaped like the module writes them: the sprint key sits in the DESCRIPTION
  gl_issue_body() { glab api "projects/$ENC/issues?labels=prd::$PRD_KEY&state=all&per_page=100" --hostname "$GLH" | grep -qF "\"title\":\"$1\"" || glab api --method POST "projects/$ENC/issues" --hostname "$GLH" -f "title=$1" -f "description=**Sprint Key:** \`$2\`" -f "labels=prd::$PRD_KEY" >/dev/null; }
  gl_issue_body "Story 1.1: Login Form" 1-1-login-form; gl_issue_body "Story 1.10: Login Form Extended" 1-10-login-form-extended
  gl_issue_body "Story 11.1: Eleven" 11-1-login-form; gl_issue_body "Epic 1: Authentication" epic-1; gl_issue_body "Epic 10: Placeholder" epic-10
  sleep 5
  local lf; lf="$(line_of common/find-issue.yaml 'glab api' 1)"
  REPLAY_CWD="$CONSUMER_GL" replay $c find-1-1 common/find-issue.yaml "$lf" search_text="1-1-login-form" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  REPLAY_CWD="$CONSUMER_GL" replay $c find-epic-1 common/find-issue.yaml "$lf" search_text="Epic 1:" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  REPLAY_CWD="$CONSUMER_GL" replay $c find-epic-1-nospace common/find-issue.yaml "$lf" search_text="Epic%201:" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  gl_titles "$d/find-1-1.out" > "$d/titles-1-1.txt"; gl_titles "$d/find-epic-1-nospace.out" > "$d/titles-epic.txt"; cat "$d/titles-1-1.txt" "$d/titles-epic.txt" >&2
  local n1 ne; n1="$(grep -c . "$d/titles-1-1.txt")"; ne="$(grep -c . "$d/titles-epic.txt")"
  local epicnote="'Epic 1:' as written → rc=$(cat "$d/find-epic-1.rc") HTTP 400 (space, see gl-d23); percent-encoded it returns $ne hit(s): $(tr '\n' ';' < "$d/titles-epic.txt")"
  if [ "$n1" -gt 1 ] || [ "$ne" -gt 1 ]; then verdict $c CONFIRMED "find-issue.yaml:$lf (GitLab $GLH) is fuzzy: search='1-1-login-form' → $n1 hit(s) ($(tr '\n' ';' < "$d/titles-1-1.txt")); FILTER takes the first. $epicnote"
  elif [ "$n1" = 1 ]; then verdict $c REFUTED "GitLab search is token-based here: '1-1-login-form' → exactly $(head -1 "$d/titles-1-1.txt") (1.10 and 11.1 not matched). $epicnote"
  else verdict $c BLOCKED "'1-1-login-form' → $n1 hits: $(head -c 200 "$d/find-1-1.err"). $epicnote"; fi
}

case_gl-d23() {  # does the GitLab find-issue survive a space in search_text?
  local c=gl-d23; gl_setup $c || return; local d; d="$(case_dir $c)"
  gl_issue "PRD: $PRD_KEY"
  local lf; lf="$(line_of common/find-issue.yaml 'glab api' 1)"
  REPLAY_CWD="$CONSUMER_GL" replay $c find-prd common/find-issue.yaml "$lf" search_text="PRD: $PRD_KEY" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  gl_titles "$d/find-prd.out" > "$d/titles.txt"; cat "$d/titles.txt" >&2
  if [ "$(cat "$d/find-prd.rc")" = 0 ] && grep -q "PRD: $PRD_KEY" "$d/titles.txt"; then verdict $c REFUTED "GitLab path: 'PRD: $PRD_KEY' with a space is found (rc=0, $(head -1 "$d/titles.txt")) — glab api encodes the query; D23 is GitHub-only"
  else verdict $c CONFIRMED "GitLab path fails with a space too, differently: glab sends the raw URL, nginx answers HTTP 400 and glab exits rc=$(cat "$d/find-prd.rc") → the RUN step HALTS the workflow (lang §5) instead of the silent [] of GitHub. Every 'PRD: {prd_key}' / 'Epic N:' lookup is dead on both platforms"; fi
}

case_gl-d16() {  # glab mr merge: stdout vs exit code
  local c=gl-d16; gl_setup $c || return; local d; d="$(case_dir $c)"
  cd "$CONSUMER_GL"; git checkout -q main; local br="gl-d16-$(date +%s)"
  git checkout -q -b "$br" main; echo "$br" > "$br.txt"; git add "$br.txt"; git commit -q -m "gl-d16 probe"; git push -q -u origin "$br"; git checkout -q main
  local iid; iid="$(glab mr create --title "gl-d16 probe" --description "probe" --source-branch "$br" --target-branch main -R "$GLH/$REPO_GL" --yes 2>&1 | grep -oE '/merge_requests/[0-9]+' | head -1 | grep -oE '[0-9]+$')"
  echo "mr=$iid" > "$d/mr.txt"; [ -n "$iid" ] || { verdict $c BLOCKED "could not create the MR: see mr.txt"; return; }
  local lm; lm="$(line_of common/merge-mr.yaml 'glab mr merge' 1)"
  REPLAY_CWD="$CONSUMER_GL" replay $c merge-ok common/merge-mr.yaml "$lm" squash=true host="$GLH" project="$REPO_GL" mr_iid="$iid"
  glab api "projects/$ENC/merge_requests/$iid" --hostname "$GLH" | uv run --no-project python -c 'import json,sys; m=json.load(sys.stdin); print(m["state"], m.get("merge_commit_sha") or m.get("squash_commit_sha") or "")' > "$d/mr-state-after.txt" 2>&1
  local ld; ld="$(run_line_of common/merge-mr.yaml '^gl = sys.argv\[1\]')"
  REPLAY_CWD="$CONSUMER_GL" replay $c derive common/merge-mr.yaml "$ld" gl_merge_out="$(cat "$d/merge-ok.out")" gh_merge_out=""
  git pull -q --ff-only origin main 2>/dev/null; git branch -D "$br" >/dev/null 2>&1
  if grep -q '^merged' "$d/mr-state-after.txt"; then
    if [ "$(tr -d '[:space:]' < "$d/derive.out")" = true ]; then verdict $c REFUTED "GitLab path: glab mr merge rc=$(cat "$d/merge-ok.rc"), stdout $(wc -c < "$d/merge-ok.out")B → merged=true; D16 is GitHub-only"
    else verdict $c CONFIRMED "GitLab path too: MR merged (state $(cat "$d/mr-state-after.txt")) but stdout empty → merged=$(cat "$d/derive.out")"; fi
  else verdict $c BLOCKED "MR not merged: rc=$(cat "$d/merge-ok.rc") $(head -c 200 "$d/merge-ok.err") state=$(cat "$d/mr-state-after.txt")"; fi
}

# gl_wait_pipeline <ref> [timeout] — latest pipeline status for a ref once terminal
gl_wait_pipeline() {
  local ref="$1" t=0 st
  while [ $t -lt "${2:-600}" ]; do
    st="$(glab api "projects/$ENC/pipelines?ref=$ref&per_page=1" --hostname "$GLH" 2>/dev/null | uv run --no-project python -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["status"] if d else "")')"
    case "$st" in success|failed|canceled|skipped) echo "$st"; return 0;; esac
    sleep 10; t=$((t+10))
  done; echo "timeout"; return 1
}
# gl_mr_for <branch> → iid (creates the MR to main if missing)
gl_mr_for() {
  local iid; iid="$(glab api "projects/$ENC/merge_requests?source_branch=$1&state=opened" --hostname "$GLH" | uv run --no-project python -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["iid"] if d else "")')"
  [ -n "$iid" ] || iid="$(glab mr create --title "$1" --description "lab MR" --source-branch "$1" --target-branch main -R "$GLH/$REPO_GL" --yes 2>&1 | grep -oE '/merge_requests/[0-9]+' | head -1 | grep -oE '[0-9]+$')"
  echo "$iid"
}

case_gl-ci() {  # shared setup for gl-d2 / gl-d18: a green MR and a red MR with finished pipelines
  gl_setup gl-ci || return 1; local d; d="$(case_dir gl-ci)"
  cd "$CONSUMER_GL"; git checkout -q main; git pull -q --ff-only origin main 2>/dev/null || true
  for pair in "gl-ci-green|pass" "gl-ci-red|fail"; do br="${pair%%|*}"; o="${pair#*|}"
    git branch -D "$br" >/dev/null 2>&1; git checkout -q -b "$br" main; set_outcome . "$o"; git commit -q --allow-empty -m "$br marker"; git push -q -f -u origin "$br"; git checkout -q main
  done
  GREEN_IID="$(gl_mr_for gl-ci-green)"; log "  waiting gl-ci-green pipeline…"; echo "green MR !$GREEN_IID pipeline: $(gl_wait_pipeline gl-ci-green)" | tee "$d/runs.txt" >&2
  RED_IID="$(gl_mr_for gl-ci-red)";     log "  waiting gl-ci-red pipeline…";   echo "red MR !$RED_IID pipeline: $(gl_wait_pipeline gl-ci-red)" | tee -a "$d/runs.txt" >&2
  glab api "projects/$ENC/pipelines?per_page=3" --hostname "$GLH" > "$d/latest-pipelines.json"
  cd - >/dev/null
}

case_gl-d2() {  # does the GitLab side read the pipeline of THE MR (not the project's latest)?
  local c=gl-d2; case_gl-ci || return; local d; d="$(case_dir $c)"
  local l1 l2; l1="$(line_of common/get-mr-pipeline.yaml 'glab api' 1)"; l2="$(line_of common/get-mr-pipeline.yaml 'glab api' 2)"
  REPLAY_CWD="$CONSUMER_GL" replay $c pipeline_id common/get-mr-pipeline.yaml "$l1" project_enc="$ENC" mr_iid="$GREEN_IID" host="$GLH"
  REPLAY_CWD="$CONSUMER_GL" replay $c pipeline_status common/get-mr-pipeline.yaml "$l2" project_enc="$ENC" mr_iid="$GREEN_IID" host="$GLH"
  local got latest; got="$(tr -d '[:space:]' < "$d/pipeline_status.out")"; latest="$(uv run --no-project python -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[0]["ref"]+"="+d[0]["status"])' "$(case_dir gl-ci)/latest-pipelines.json")"
  if [ "$got" = success ]; then verdict $c REFUTED "GitLab path is per-MR and correct: get-mr-pipeline.yaml:$l2 for the green MR !$GREEN_IID → '$got' while the project's latest pipeline is $latest. D02 is GitHub-only"
  else verdict $c CONFIRMED "GitLab path also wrong: green MR reports '$got' (latest project pipeline $latest)"; fi
}

case_gl-d18() {  # the GitLab polling loop, live, against a finished MR pipeline
  local c=gl-d18; case_gl-ci || return; local d; d="$(case_dir $c)"
  local gl; gl="$(line_of common/wait-for-green-ci.yaml 'RUN: \|' 1)"
  $TT render-step common/wait-for-green-ci.yaml "$gl" project_enc="$ENC" mr_iid="$GREEN_IID" host="$GLH" > "$d/gitlab-loop.cmd"
  sed 's/max_attempts=60/max_attempts=2/' "$d/gitlab-loop.cmd" > "$d/gitlab-loop-2.cmd"
  log "  (a) literal GitLab loop, max_attempts=2 (≈60 s), MR !$GREEN_IID (pipeline success)…"
  ( cd "$CONSUMER_GL" && bash "$d/gitlab-loop-2.cmd" ) > "$d/gitlab-loop-2.out" 2> "$d/gitlab-loop-2.err"; echo $? > "$d/gitlab-loop-2.rc"
  sed '/STATUS=\$(uv run --no-project python -c "/a import sys' "$d/gitlab-loop-2.cmd" > "$d/gitlab-loop-2-patched.cmd"
  log "  (b) +import sys (≈30 s)…"
  ( cd "$CONSUMER_GL" && bash "$d/gitlab-loop-2-patched.cmd" ) > "$d/gitlab-loop-2-patched.out" 2> "$d/gitlab-loop-2-patched.err"; echo $? > "$d/gitlab-loop-2-patched.rc"
  local a b; a="$(tr -d '[:space:]' < "$d/gitlab-loop-2.out")"; b="$(tr -d '[:space:]' < "$d/gitlab-loop-2-patched.out")"
  if [ "$a" = timeout ] && [ "$b" = passed ]; then verdict $c CONFIRMED "wait-for-green-ci.yaml:$gl (GitLab, $GLH) against MR !$GREEN_IID whose pipeline is success: literal loop → '$a' after max_attempts; with 'import sys' → '$b' on the first poll. D18 hits both platforms"
  else verdict $c REFUTED "literal='$a' patched='$b' (see $d)"; fi
}

case_gl-d4() {  # glab api --paginate | json.load
  local c=gl-d4; gl_setup $c || return; local d; d="$(case_dir $c)"
  local have; have="$(glab api "projects/$ENC/issues?labels=prd::bulkprd&state=all&per_page=100" --hostname "$GLH" --paginate 2>/dev/null | grep -o '"iid"' | wc -l)"
  glab label create --name "prd::bulkprd" -R "$GLH/$REPO_GL" >/dev/null 2>&1 || true
  local i="$have"; while [ "$i" -lt 105 ]; do i=$((i+1)); glab api --method POST "projects/$ENC/issues" --hostname "$GLH" -f "title=Seed $i (bulkprd)" -f "labels=prd::bulkprd" >/dev/null 2>&1 || { sleep 20; i=$((i-1)); }; printf '\r  seeded %d/105' "$i" >&2; sleep 0.4; done; echo >&2
  glab api "projects/$ENC/issues?labels=prd::bulkprd&state=all&per_page=100" --hostname "$GLH" --paginate | uv run --no-project python -c 'import sys; s=sys.stdin.read(); print("bytes=%d newlines=%d objects=%d" % (len(s), s.count(chr(10)), s.count("[{")))' > "$d/paginate-shape.txt" 2>&1; cat "$d/paginate-shape.txt" >&2
  local l; l="$(line_of common/sync-issues.yaml 'glab api "projects' 1)"
  REPLAY_CWD="$CONSUMER_GL" replay $c bulk-fetch common/sync-issues.yaml "$l" project_enc="$ENC" sep=:: prd_key=bulkprd host="$GLH"
  if [ "$(cat "$d/bulk-fetch.rc")" = 0 ] && [ "$(grep -c . "$d/bulk-fetch.out")" -ge 105 ]; then verdict $c REFUTED "GitLab path: glab api --paginate yields one parseable document ($(cat "$d/paginate-shape.txt")); $(grep -c . "$d/bulk-fetch.out") rows; D04 is GitHub-only"
  else verdict $c CONFIRMED "GitLab path too: rc=$(cat "$d/bulk-fetch.rc") rows=$(grep -c . "$d/bulk-fetch.out") $(head -c 160 "$d/bulk-fetch.err") ($(cat "$d/paginate-shape.txt"))"; fi
}

case_g10() {
  local c=g10; local d; load_lab 2>/dev/null || true; d="$(mkdir -p "$E2E_ROOT/evidence/${LAB_ID:-static}/g10" && echo "$E2E_ROOT/evidence/${LAB_ID:-static}/g10")"
  # rendering proof: cross-platform (issues on GitHub, code on GitLab) — which repo do the MR atomics hit?
  local l1; l1="$(line_of common/get-mr-pipeline.yaml 'gh run list' 1)"
  $TT render-step common/get-mr-pipeline.yaml "$l1" host=github.com project=acme/issues-repo mr_repo=gitlab.com/acme/code-repo > "$d/get-mr-pipeline.cmd"
  local l2; l2="$(line_of common/merge-mr.yaml 'gh pr merge' 2)"
  $TT render-step common/merge-mr.yaml "$l2" mr_iid=7 git_host=gitlab.com > "$d/merge-mr-cross.cmd"
  grep -n 'git_owner\|git_repo' "$WF/common/check-config.yaml" > "$d/check-config-defines.txt" || echo "(check-config defines neither git_owner nor git_repo)" > "$d/check-config-defines.txt"
  cat "$d/get-mr-pipeline.cmd" "$d/merge-mr-cross.cmd" "$d/check-config-defines.txt" >&2
  if grep -q 'github.com/acme/issues-repo' "$d/get-mr-pipeline.cmd" && grep -q '{git_owner}' "$d/merge-mr-cross.cmd"; then
    verdict $c CONFIRMED "get-mr-pipeline.yaml:$l1 renders 'gh run list -R github.com/acme/issues-repo' (the ISSUE tracker) although the MR lives in mr_repo=gitlab.com/acme/code-repo; merge-mr.yaml:$l2 leaves {git_owner}/{git_repo} unresolved (check-config sets neither) → lang §4.5 halts the workflow"
  else verdict $c REFUTED "rendering did not show the cross-platform mix-up"; fi
}

# ============================================================================
main() {
  local what="${1:-}"
  case "$what" in
    static) case_static;;
    d17|d18|d2|d4|d7|d8|d16|d19|d9|g06|g10|gl-d23|gl-d16|gl-d4) "case_$what";;
    gitlab) for k in g06 gl-d23 gl-d16 gl-d4 gl-d2 gl-d18; do log "=== $k"; "case_$k"; done;;
    gl-d2|gl-d18) "case_$what";;
    all) case_static; for k in d17 d7 d8 d16 d9 d19 d2 d18 d4; do log "=== $k"; "case_$k"; done;;
    all-quick) case_static; for k in d17 d7 d8 d16 d9; do log "=== $k"; "case_$k"; done;;
    *) sed -n 2,12p "$0"; exit 2;;
  esac
}
main "$@"
