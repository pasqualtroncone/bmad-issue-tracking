#!/usr/bin/env bash
# Level 0 (static greps, no lab) and level 1 (literal replay of RUN steps, no LLM).
#
#   replay.sh static                # S1..S8 + D03/D22 arithmetic — no lab needed
#   replay.sh d17|d18|d2|d4|d7|d8|d15|d16|d19|d21|d24|d9|r1|r3|r7  # GitHub lab (d15/d21/d29 are local)
#   replay.sh d29                  # static: the dev-finish INCLUDE order (no lab)
#   replay.sh g06|g10|d26|d03       # GitLab lab (g10 is a rendering proof, no glab needed)
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
# run_line_of_n <rel> <body-regex> <nth> — same, for the nth match (two platform steps can
# share a STORE name, and only their order tells them apart)
run_line_of_n() { local b; b="$(grep -n -E -- "$2" "$WF/$1" | sed -n "${3:-1}p" | cut -d: -f1)"; [ -n "$b" ] && awk -v n="$b" 'NR<=n && /^ *- RUN:/ {l=NR} END{print l}' "$WF/$1"; }

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
  # S2 create-issue indentation — the block is located by grep, not by a fixed line number:
  # it moved from 36-42 to 62-68 when the GitHub lookup became a parsing RUN (#2/#33) and a
  # hardcoded `sed -n 36,42p` would have quietly reported REFUTED for the wrong reason.
  local s2l; s2l="$(grep -n '^    - CHECK: empty issue_id' "$WF/common/create-issue.yaml" | head -1 | cut -d: -f1)"
  item="$(sed -n "${s2l:-1},$(( ${s2l:-1} + 6 ))p" "$WF/common/create-issue.yaml")"; say '```'; say "$item"; say '```'
  if [ -n "$s2l" ] && sed -n "$((s2l+1))p" "$WF/common/create-issue.yaml" | grep -q '^    TRUE:'; then mark S2 CONFIRMED "create-issue.yaml:$s2l-$((s2l+6)) TRUE:/FALSE: sit at the same indent as '- CHECK' (not under it); both branches STOP so behaviour survives by luck"; else mark S2 REFUTED "indentation is regular"; fi
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
  # D03 arithmetic — what matters is the worst case of ONE poll RUN, since that is what the
  # Bash tool has to survive. The old locator multiplied sleep × max_attempts because the whole
  # 30-min wait WAS one RUN; now the wait is a LOOP in the workflow language, so the same product
  # is computed per round (sleep × polls_per_round) and the round count only reports the budget.
  local d03; d03="$($PY - "$WF/common/wait-for-green-ci.yaml" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
sleeps = [int(x) for x in re.findall(r"\bsleep (\d+)", t)] or [0]
polls = [int(x) for x in re.findall(r"\b(?:polls_per_round|max_attempts)=(\d+)", t)] or [0]
m = re.search(r'poll_rounds, value: "([^"]*)"', t)
rounds = len(m.group(1).split("\\n")) if m else 1
one = max(sleeps) * max(polls)
print(one, rounds, one * rounds)
PY
)"
  local one rounds total; read -r one rounds total <<< "$d03"
  say "wait-for-green-ci: the longest single poll RUN blocks sleep × polls = $one s (× $rounds LOOP rounds = $total s of wall clock); Claude Code Bash hard cap = 600 s (BASH_MAX_TIMEOUT_MS)"
  if [ "$one" -gt 600 ]; then mark D03-static CONFIRMED "a single RUN can block $one s but the tool times out at 600 s → ci-status.json never written on long pipelines (empirical: scenario A2)"; else mark D03-static REFUTED "one RUN blocks at most $one s, under the 600 s cap; the $total s wait is $rounds LOOP rounds in the workflow language and ci_status is stored after each"; fi
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
  $TT render-step common/wait-for-green-ci.yaml "$gh" mr_repo="github.com/$REPO_GH" source_branch=ci-green > "$d/github-loop.cmd"
  awk '/STATUS=\$\(uv run/{f=1; sub(/.*STATUS=\$\(/,""); print; next} f&&/^" "\$pipeline_status"( 2>\/dev\/null)?\)/{print "\" success"; f=0; next} f{print}' "$d/github-loop.cmd" > "$d/status-snippet.cmd"
  log "  (a) STATUS mapping snippet with 'success', stderr visible"
  ( cd "$CONSUMER" && bash "$d/status-snippet.cmd" ) > "$d/status-snippet.out" 2> "$d/status-snippet.err"; echo $? > "$d/status-snippet.rc"
  # (b) one GitHub poll round, polls_per_round shortened to 2, against a repo whose latest run is complete
  # (the round used to be the whole 60-attempt loop; #14 split it, so the knob is the per-round count)
  sed -E 's/polls_per_round=[0-9]+/polls_per_round=2/' "$d/github-loop.cmd" > "$d/github-loop-2.cmd"
  gh run list -R "$REPO_GH" --limit 1 --json status,conclusion,headBranch > "$d/latest-run-before.json"
  log "  (b) full polling round with polls_per_round=2 (≈50 s)…"
  ( cd "$CONSUMER" && time bash "$d/github-loop-2.cmd" ) > "$d/github-loop-2.out" 2> "$d/github-loop-2.err"; echo $? > "$d/github-loop-2.rc"
  # (c) same loop with the one-line fix
  sed '/STATUS=\$(uv run --no-project python -c "/a import sys' "$d/github-loop-2.cmd" > "$d/github-loop-2-patched.cmd"
  log "  (c) patched round (+import sys), polls_per_round=2 (≈25 s)…"
  ( cd "$CONSUMER" && time bash "$d/github-loop-2-patched.cmd" ) > "$d/github-loop-2-patched.out" 2> "$d/github-loop-2-patched.err"; echo $? > "$d/github-loop-2-patched.rc"
  # gitlab variant is the same text; render it for the record
  $TT render-step common/wait-for-green-ci.yaml "$gl" project_enc=x mr_iid=1 host=gitlab.com > "$d/gitlab-loop.cmd"
  local latest; latest="$(uv run --no-project python -c 'import json,sys; r=json.load(open(sys.argv[1])); print((r[0]["conclusion"] or r[0]["status"]) if r else "none")' "$d/latest-run-before.json")"
  if grep -q "NameError: name 'sys' is not defined" "$d/status-snippet.err" && [ "$(tr -d '[:space:]' < "$d/github-loop-2.out")" = timeout ] && [ "$(tr -d '[:space:]' < "$d/github-loop-2-patched.out")" != timeout ]; then
    verdict $c CONFIRMED "STATUS mapping (wait-for-green-ci.yaml:$gh block, also :$gl) NameErrors under 2>/dev/null → STATUS='' → loop never breaks: latest run '$latest' still yields 'timeout' after the round's polls; with 'import sys' the same loop prints '$(tr -d '[:space:]' < "$d/github-loop-2-patched.out")' on the first poll. Real run: the whole 30-min budget elapses → masks D03"
  else verdict $c REFUTED "snippet rc=$(cat "$d/status-snippet.rc") loop='$(cat "$d/github-loop-2.out")' patched='$(cat "$d/github-loop-2-patched.out")'"; fi
}

case_d2() {
  local c=d2; load_lab; local d; d="$(case_dir $c)"
  cd "$CONSUMER"; git checkout -q main; git pull -q --ff-only origin main 2>/dev/null || true
  git branch -D ci-green ci-red >/dev/null 2>&1 || true
  # t0 discards the completed runs a previous d2 left on these branches (see wait_run)
  local t0; t0="$(date -u +%FT%TZ)"
  git checkout -q -b ci-green main; set_outcome . pass; git commit -q --allow-empty -m "ci-green marker"; git push -f -u origin ci-green > "$d/push-ci-green.log" 2>&1 || warn "push ci-green failed: $(tail -1 "$d/push-ci-green.log")"
  log "  waiting for ci-green run…"; echo "ci-green: $(wait_run ci-green 600 "$t0")" | tee "$d/runs.txt" >&2
  git checkout -q -b ci-red main; set_outcome . fail; git push -f -u origin ci-red > "$d/push-ci-red.log" 2>&1 || warn "push ci-red failed: $(tail -1 "$d/push-ci-red.log")"
  log "  waiting for ci-red run…"; echo "ci-red: $(wait_run ci-red 600 "$t0")" | tee -a "$d/runs.txt" >&2
  git checkout -q ci-green
  gh run list -R "$REPO_GH" --limit 3 --json headBranch,conclusion,createdAt,databaseId > "$d/gh-run-list.json"
  # locator: anchored on '- RUN:' — the fixed step now carries a '# … gh run list …' comment
  # above it, which a bare 'gh run list' grep would return as step 1. The '^' is gone since
  # #15: the GitHub steps moved inside `CHECK: git_platform eq "gitlab"`'s FALSE branch (an
  # MR/CI step follows the git remote, and the PLATFORM: they used to carry names the issue
  # tracker), so they are indented. '- RUN:' still cannot match a comment line.
  # variables: the step reads {mr_repo}/{source_branch} (set by check-mr-ci) where it used to
  # read {host}/{project} and no branch at all.
  local l1 l2; l1="$(line_of common/get-mr-pipeline.yaml '- RUN: gh run list' 1)"; l2="$(line_of common/get-mr-pipeline.yaml '- RUN: gh run list' 2)"
  replay $c pipeline_id common/get-mr-pipeline.yaml "$l1" host=github.com project="$REPO_GH" mr_repo="github.com/$REPO_GH" source_branch=ci-green
  replay $c pipeline_status common/get-mr-pipeline.yaml "$l2" host=github.com project="$REPO_GH" mr_repo="github.com/$REPO_GH" source_branch=ci-green
  gh run list -R "$REPO_GH" --branch ci-green --limit 1 --json conclusion,headBranch,databaseId > "$d/control-branch-filter.json"
  local got ctrl; got="$(tr -d '[:space:]' < "$d/pipeline_status.out")"; ctrl="$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["conclusion"])' "$d/control-branch-filter.json")"
  git checkout -q main
  if [ "$got" = failure ] && [ "$ctrl" = success ]; then
    verdict $c CONFIRMED "on branch ci-green (CI green) get-mr-pipeline.yaml:$l2 'gh run list --limit 1' reports pipeline_status=$got — the latest run of the WHOLE repo (ci-red); with --branch ci-green it is $ctrl. Same shape in wait-for-green-ci.yaml (poll + failure path)"
  else verdict $c REFUTED "got=$got control=$ctrl (see runs.txt) — on branch ci-green get-mr-pipeline.yaml:$l2 reads the run of THAT branch ('--branch ci-green -R mr_repo'), not the repo's newest run (ci-red)"; fi
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
  replay $c ensure-mr-head common/ensure-mr.yaml "$le" mr_title="Story 1.1: 1-1-login-form" mr_description_file=/tmp/e2e-d8-desc.md target_branch="feat/$PRD_KEY/prd" source_branch="$sb" mr_repo="github.com/$REPO_GH"
  sed 's/ 2>&1 | grep .*$//' "$d/ensure-mr-head.cmd" > "$d/ensure-mr-head-gh-only.cmd"
  ( cd "$CONSUMER" && bash "$d/ensure-mr-head-gh-only.cmd" ) > "$d/ensure-mr-head-gh-only.out" 2> "$d/ensure-mr-head-gh-only.err"; echo $? > "$d/ensure-mr-head-gh-only.rc"
  rm -f /tmp/e2e-d8-desc.md
  git checkout -q main; git branch -D bmad-loop/r1/1-1-login-form >/dev/null 2>&1 || true
  if [ "$(cat "$d/push.rc")" = 128 ] && grep -q 'no upstream\|has no upstream branch' "$d/push.err"; then
    local d22=""; [ ! -s "$d/ls-remote-story-branch.txt" ] && d22="; D22: module-derived story_branch '$sb' does not exist on origin, and ensure-mr.yaml:$le --head $sb fails (gh rc=$(cat "$d/ensure-mr-head-gh-only.rc")): '$(grep -m1 -iE 'head|not found|error|could not' "$d/ensure-mr-head-gh-only.err" | cut -c1-110)' — the create is the step's own exit code now, so the caller halts instead of storing an empty mr_url"
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
  # locator anchored on 'RUN:' — the file header now names `gh pr merge` while explaining why
  # its stdout cannot be the signal, and a bare grep would return that comment as step 1
  local lm; lm="$(line_of common/merge-mr.yaml 'RUN: gh pr merge' 1)"
  # positive: merge succeeds — capture stdout and stderr separately, exactly as STORE would (stdout only)
  replay $c merge-ok common/merge-mr.yaml "$lm" mr_iid="$n" host=github.com project="$REPO_GH"
  gh pr view "$n" -R "$REPO_GH" --json state,mergedAt --jq '.state + " " + (.mergedAt // "")' > "$d/pr-state-after.txt"
  # D30 (#43): the SHA lookup the atomic runs right after the merge. `gh api` takes the
  # host through --hostname; with the host inside the path it answers 404, and the step
  # carries no EXPECT_EXIT: any — so a REAL merge was followed by a halt with merge_sha
  # empty. Rendered here against the PR that was just merged: the SHA must come back.
  local lsha; lsha="$(line_of common/merge-mr.yaml 'RUN: gh api "repos/' 1)"
  replay $c merge-sha common/merge-mr.yaml "$lsha" mr_iid="$n" host=github.com project="$REPO_GH"
  # the pre-fix shape against the same merged PR, for the record
  gh api "repos/github.com/$REPO_GH/pulls/$n" --jq .merge_commit_sha > "$d/merge-sha-hostinpath.out" 2> "$d/merge-sha-hostinpath.err"
  echo $? > "$d/merge-sha-hostinpath.rc"
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
  # --- R2 (#48): the derive step names BOTH outputs, each branch sets only one ---
  # lang §4.5 halts on the reference to the other — after the irreversible merge CLI ran.
  # The file now SETs both to "" before the platform CHECKs, so the rendered derive command
  # can carry no unresolved {placeholder}, and an empty output still fills its argv slot.
  local seeds; seeds="$(grep -c -E '^- SET: \{ variable: g[lh]_merge_out, value: "" \}' "$WF/common/merge-mr.yaml")"
  local firstcheck; firstcheck="$(grep -n -E '^- CHECK: git_platform' "$WF/common/merge-mr.yaml" | head -1 | cut -d: -f1)"
  local lastseed; lastseed="$(grep -n -E '^- SET: \{ variable: g[lh]_merge_out, value: "" \}' "$WF/common/merge-mr.yaml" | tail -1 | cut -d: -f1)"
  grep -o '{[a-z_]*}' "$d/derive-ok.cmd" | sort -u > "$d/derive-unresolved.txt" || true
  local unres; unres="$(grep -c . "$d/derive-unresolved.txt")"
  # the GitLab shape of the same step (only gl_merge_out set) must read 'true', not shift
  # the empty gh argument into slot 1
  replay $c derive-gl-only common/merge-mr.yaml "$ld" gl_merge_out="Merged merge request !7" gh_merge_out=""
  local dgl; dgl="$(tr -d '[:space:]' < "$d/derive-gl-only.out")"
  { echo "merge-mr.yaml seeds gl_merge_out/gh_merge_out with \"\": $seeds (want 2), last seed at line $lastseed, first platform CHECK at line $firstcheck"
    echo "unresolved placeholders left in the rendered derive: $unres $(tr '\n' ' ' < "$d/derive-unresolved.txt")"
    echo "derive with only the GitLab output set → '$dgl' (want true)"; } > "$d/r2-summary.txt"; cat "$d/r2-summary.txt" >&2
  if [ "$seeds" = 2 ] && [ -n "$firstcheck" ] && [ "$lastseed" -lt "$firstcheck" ] && [ "$unres" = 0 ] && [ "$dgl" = true ]; then
    verdict $c-R2 REFUTED "merge-mr.yaml SETs both gl_merge_out and gh_merge_out to \"\" (lines up to $lastseed) before the first platform CHECK (line $firstcheck), so the derive step at :$ld references no undefined variable: the rendered command leaves 0 placeholders and reads 'true' from the GitLab output alone ('$dgl') as well as from the GitHub one. Under lang §4.5 the pre-fix step halted on every merge, after the irreversible CLI, leaving merged/error unset"
  else
    verdict $c-R2 CONFIRMED "merge-mr.yaml:$ld still references an output no branch defines: seeds=$seeds (want 2) lastseed=$lastseed firstcheck=$firstcheck unresolved=$unres ($(tr '\n' ' ' < "$d/derive-unresolved.txt")) gl-only derive='$dgl'"
  fi
  local sha; sha="$(tr -d '[:space:]' < "$d/merge-sha.out")"
  if [ "$(cat "$d/merge-sha.rc")" = 0 ] && [ -n "$sha" ]; then
    verdict $c-D30 REFUTED "merge-mr.yaml:$lsha reads the merge SHA of the just-merged PR #$n: rc=0, merge_commit_sha=$sha. The host travels in --hostname, not in the path; the pre-fix path shape (repos/github.com/$REPO_GH/pulls/$n) answers rc=$(cat "$d/merge-sha-hostinpath.rc") '$(head -c 90 "$d/merge-sha-hostinpath.err" | tr '\n' ' ')', and with no EXPECT_EXIT: any that 404 halted the workflow after a successful merge"
  else
    verdict $c-D30 CONFIRMED "merge-mr.yaml:$lsha does not read the merge SHA of the merged PR #$n: rc=$(cat "$d/merge-sha.rc") out='$sha' err='$(head -c 120 "$d/merge-sha.err" | tr '\n' ' ')' — the step has no EXPECT_EXIT: any, so the workflow halts right after a successful merge with merge_sha empty"
  fi
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
  # Since #44 the two search_text shapes live in two steps: a key-shaped lookup goes to
  # the REST list endpoint (read-your-writes consistent), a title shape keeps the
  # index-backed search API. Each replay below targets the step the runtime would pick
  # for the search_text it passes.
  local lr; lr="$(line_of common/find-issue.yaml 'gh api "repos/' 1)"
  # The step searches AND chooses: its stdout is the selected issue number, or empty. The
  # raw search is captured separately (raw-*.txt) because the QUERY is deliberately
  # unchanged — it is still fuzzy, and the evidence has to keep showing that. The verdict
  # therefore reads the selected id, not the number of hits: "the wrong issue is picked".
  replay $c find-1-1 common/find-issue.yaml "$lr" search_text=1-1-login-form project="$REPO_GH" host=github.com sep=: prd_key="$key"
  replay $c find-epic-1 common/find-issue.yaml "$lf" search_text="Epic 1:" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  replay $c find-prd common/find-issue.yaml "$lf" search_text="PRD: $key" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  raw() { gh api "search/issues" --method GET -f "q=$1 repo:$REPO_GH label:prd:$key" -f "per_page=100" --jq '[.items[] | "#\(.number) \(.title)"] | join("; ")' 2>/dev/null; }
  raw "1-1-login-form" > "$d/raw-1-1.txt"; raw "Epic 1:" > "$d/raw-epic-1.txt"; raw "PRD: $key" > "$d/raw-prd.txt"
  # `repos/.../issues` returns pull requests too, and the R5 probe below puts a PR titled
  # "PRD: $key" on that very list: without `.pull_request == null` the EXPECTED value would
  # become the PR's number and every verdict here would read the wrong way round.
  want() { gh api "repos/$REPO_GH/issues?state=all&per_page=100&labels=prd:$key" --paginate --jq ".[] | select(.pull_request == null) | select(.title == \"$1\") | .number" 2>/dev/null | head -1; }
  local w11 we1 wprd g11 ge1 gprd
  w11="$(want "Story 1.1: Login Form")"; we1="$(want "Epic 1: Authentication")"; wprd="$(want "PRD: $key")"
  g11="$(tr -d '[:space:]' < "$d/find-1-1.out")"; ge1="$(tr -d '[:space:]' < "$d/find-epic-1.out")"; gprd="$(tr -d '[:space:]' < "$d/find-prd.out")"
  { echo "== search_text=1-1-login-form  selected=#${g11:-(empty)} want=#${w11:-?}  raw hits: $(cat "$d/raw-1-1.txt")"
    echo "== search_text='Epic 1:'       selected=#${ge1:-(empty)} want=#${we1:-?}  raw hits: $(cat "$d/raw-epic-1.txt")"
    echo "== search_text='PRD: $key'     selected=#${gprd:-(empty)} want=#${wprd:-?} rc=$(cat "$d/find-prd.rc")  raw hits: $(cat "$d/raw-prd.txt")"
    head -c 300 "$d/find-prd.err"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  if grep -q 'PROTOCOL_ERROR' "$d/find-prd.err" && [ "$(cat "$d/find-prd.rc")" = 0 ] && [ -z "$gprd" ]; then
    gh api "search/issues?q=PRD%3A%20$key+repo:$REPO_GH+label:prd:$key&per_page=5" --jq '[.items[].title]' > "$d/find-prd-encoded.out" 2>&1
    verdict $c-D23 CONFIRMED "find-issue.yaml:$lf with search_text='PRD: $key' puts a raw space in the URL → gh api: '$(grep -o 'stream error.*' "$d/find-prd.err" | head -1)'; the trailing '| python' makes the step exit 0 with an empty selection → issue_id empty. Every 'PRD: {prd_key}' lookup on GitHub (issue-sync/prepare, bmad-prd/complete create-vs-update, edit-prd, correct-course) silently misses; percent-encoded, the same query returns $(cat "$d/find-prd-encoded.out"). 'Epic 1:' fails the same way (rc=$(cat "$d/find-epic-1.rc"), selected #${ge1:-(empty)})"
  elif [ "$(cat "$d/find-prd.rc")" = 0 ] && [ -n "$gprd" ] && [ "$gprd" = "$wprd" ]; then
    gh api "search/issues?q=PRD%3A%20$key+repo:$REPO_GH+label:prd:$key&per_page=5" --jq '[.items[].title]' > "$d/find-prd-encoded.out" 2>&1
    verdict $c-D23 REFUTED "find-issue.yaml:$lf with search_text='PRD: $key' → rc=0 and the PRD issue #$gprd 'PRD: $key' is selected, no PROTOCOL_ERROR: the space never reaches the URL. The encoded control returns $(cat "$d/find-prd-encoded.out"). 'Epic 1:' → rc=$(cat "$d/find-epic-1.rc"), selected #${ge1:-(empty)}"
  else
    verdict $c-D23 BLOCKED "neither shape: rc=$(cat "$d/find-prd.rc") selected='$gprd' want='$wprd' raw='$(cat "$d/raw-prd.txt")' err=$(head -c 160 "$d/find-prd.err")"
  fi
  if [ -z "$w11" ] || [ -z "$we1" ]; then
    verdict $c BLOCKED "the seeded issues are not on the repo (want Story 1.1='$w11' Epic 1='$we1'); raw search: $(cat "$d/raw-1-1.txt") / $(cat "$d/raw-epic-1.txt")"
  elif [ "$g11" != "$w11" ] || [ "$ge1" != "$we1" ]; then
    verdict $c CONFIRMED "find-issue.yaml:$lr/$lf (GitHub) picks the wrong issue: search_text '1-1-login-form' selects #${g11:-(empty)} but Story 1.1 is #$w11, and 'Epic 1:' selects #${ge1:-(empty)} but Epic 1 is #$we1. The query returns $(cat "$d/raw-1-1.txt") / $(cat "$d/raw-epic-1.txt") and the choice follows the index rank. Search-index latency measured ≈${t}s"
  else
    verdict $c REFUTED "find-issue.yaml:$lr/$lf (GitHub) picks by identity, not by index rank: '1-1-login-form' → #$g11 'Story 1.1: Login Form' (its **Sprint Key** body marker) and 'Epic 1:' → #$ge1 'Epic 1: Authentication' (exact title prefix, 'Epic 10:' excluded), although the unchanged query still returns $(cat "$d/raw-1-1.txt") / $(cat "$d/raw-epic-1.txt"). Search-index latency measured ≈${t}s"
  fi
  # --- D20 (#44): an issue created NOW must be findable by its key on the next call ---
  # This is the half the three lookups above cannot show: they run against issues the
  # index has long since absorbed. The probe creates one and asks for it immediately.
  local fresh="9-9-fresh-$(date +%s)"
  gh issue create -R "$REPO_GH" --title "Story 9.9: Fresh probe ${fresh##*-}" \
    --body "**Sprint Key:** \`$fresh\`" --label "prd:$key" > "$d/fresh-url.txt" 2>&1
  local fu fn; fu="$(tail -1 "$d/fresh-url.txt")"; fn="${fu##*/}"
  local t0 dt; t0="$(date +%s)"
  replay $c find-fresh common/find-issue.yaml "$lr" search_text="$fresh" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  dt=$(( $(date +%s) - t0 ))
  # what the index-backed search API knows about the same issue at the same instant
  gh api "search/issues?q=$fresh+repo:$REPO_GH+label:prd:$key&per_page=5" --jq .total_count > "$d/fresh-search-count.txt" 2>&1
  local gf; gf="$(tr -d '[:space:]' < "$d/find-fresh.out")"
  echo "fresh issue #$fn key=$fresh -> selected '#${gf:-(empty)}' in ${dt}s; search/issues total_count right after: $(cat "$d/fresh-search-count.txt")" | tee "$d/fresh.txt" >&2
  gh issue close "$fn" -R "$REPO_GH" >/dev/null 2>&1 || true
  if [ -z "$fn" ]; then
    verdict $c-D20 BLOCKED "could not create the probe issue: $(head -c 200 "$d/fresh-url.txt" | tr '\n' ' ')"
  elif [ "$(cat "$d/find-fresh.rc")" = 0 ] && [ "$gf" = "$fn" ]; then
    verdict $c-D20 REFUTED "find-issue.yaml:$lr selects the just-created issue #$fn for its key '$fresh' in ONE step invocation (rc=0, ${dt}s): the key-shaped lookup reads the REST list endpoint and re-checks a miss up to three times, 3 s apart. Neither GitHub endpoint is read-your-writes — search/issues answered total_count=$(cat "$d/fresh-search-count.txt") right after, and the plain list needed 3.7-7.7 s in the timing probe — which is exactly what made sync-issues and a create-story/dev-finish pair in the same minute read an empty issue_id"
  else
    verdict $c-D20 CONFIRMED "find-issue.yaml:$lr does not see the issue it was just told about: #$fn key '$fresh' → selected '#${gf:-(empty)}' rc=$(cat "$d/find-fresh.rc") after ${dt}s; search/issues total_count=$(cat "$d/fresh-search-count.txt"). A flow that creates an issue and looks it up in the same minute skips the status update"
  fi
  # --- R5 (#51): the title-shaped lookup must not adopt a PULL REQUEST ---
  # ensure-mr titles the PRD pull request "PRD: {prd_key}" — the format of the PRD ISSUE —
  # and labels it prd:{key}. search/issues returns issues AND pull requests, so an exact
  # title match could hand back the PR's number and `gh issue edit <pr>` would edit the PR.
  cd "$CONSUMER"; git checkout -q main; git pull -q --ff-only origin main 2>/dev/null || true
  local pbr="d19-prdpr-$(date +%s)"
  git checkout -q -b "$pbr" main; git commit -q --allow-empty -m "d19 R5 probe"
  git push -q -u origin "$pbr" > "$d/r5-push.log" 2>&1 || warn "push $pbr failed"
  git checkout -q main
  gh pr create -R "$REPO_GH" --title "PRD: $key" --body "R5 probe: a PR titled like the PRD issue" \
    --base main --head "$pbr" --label "prd:$key" > "$d/r5-pr-url.txt" 2>&1
  local pru prn; pru="$(tail -1 "$d/r5-pr-url.txt")"; prn="${pru##*/}"
  case "$prn" in ''|*[!0-9]*) prn="";; esac
  # the index has to know about the PR, or there is nothing to be fooled by
  local rt=0 rn=0
  while [ $rt -lt 180 ]; do
    rn="$(gh api "search/issues?q=repo:$REPO_GH+label:prd:$key+is:pr&per_page=1" --jq .total_count 2>/dev/null || echo 0)"
    [ "${rn:-0}" -ge 1 ] && break; sleep 10; rt=$((rt+10))
  done
  echo "PR #${prn:-(none)} indexed after ${rt}s (search is:pr total_count=$rn)" | tee "$d/r5-index.txt" >&2
  replay $c find-prd-with-pr common/find-issue.yaml "$lf" search_text="PRD: $key" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  gh api "search/issues" --method GET -f "q=PRD: $key repo:$REPO_GH label:prd:$key" -f "per_page=100" \
    --jq '[.items[] | "#\(.number) \(if .pull_request then "PR" else "issue" end) \(.title)"] | join("; ")' > "$d/r5-raw.txt" 2>&1
  local gpr; gpr="$(tr -d '[:space:]' < "$d/find-prd-with-pr.out")"
  echo "with the PR present: selected #${gpr:-(empty)} (PRD issue is #$wprd, the PR is #${prn:-?}); raw hits: $(cat "$d/r5-raw.txt")" | tee "$d/r5-summary.txt" >&2
  [ -n "$prn" ] && gh pr close "$prn" -R "$REPO_GH" --delete-branch >/dev/null 2>&1
  git branch -D "$pbr" >/dev/null 2>&1 || true
  if [ -z "$prn" ] || [ "${rn:-0}" -lt 1 ]; then
    verdict $c-R5 BLOCKED "no indexed PR titled 'PRD: $key' to be fooled by: pr='#$prn' search is:pr total_count=$rn after ${rt}s ($(head -c 160 "$d/r5-pr-url.txt" | tr '\n' ' '))"
  elif [ "$gpr" = "$wprd" ]; then
    verdict $c-R5 REFUTED "find-issue.yaml:$lf drops items carrying \`pull_request\`: with PR #$prn titled 'PRD: $key' and labelled prd:$key on the same search ($(cat "$d/r5-raw.txt")), the step still selects the ISSUE #$gpr. Before the filter the exact-title match could return the PR and \`gh issue edit <pr>\` would have edited the pull request instead of the PRD issue"
  else
    verdict $c-R5 CONFIRMED "find-issue.yaml:$lf adopts the pull request: search_text 'PRD: $key' selects #${gpr:-(empty)} while the PRD ISSUE is #$wprd and PR #$prn carries the same title and label ($(cat "$d/r5-raw.txt"))"
  fi
}

case_d24() {  # #2 + #33 — the create-issue lookup on a title that does not exist yet
  # Before the fix there was nothing to replay at level 1: the step was a bare
  # `gh api repos/.../issues --paginate` and the decision was a FILTER `where: title matches`.
  # Its no-match behaviour is a language rule, not a command: lang §5 "FILTER no match on
  # where → Stop workflow", confirmed live by scenario A1 (the hook halted on the first
  # story issue) and reported as #2. #33 is the second half: past 100 issues `--paginate`
  # hands the FILTER concatenated JSON documents it cannot parse.
  local c=d24; load_lab; local d; d="$(case_dir $c)"; local key=d24prd
  gh label create "prd:$key" -R "$REPO_GH" >/dev/null 2>&1 || true
  gh issue list -R "$REPO_GH" --state all --label "prd:$key" --json title --jq '.[].title' | grep -qxF "PRD: $key" \
    || gh issue create -R "$REPO_GH" --title "PRD: $key" --body "**PRD:** $key" --label "prd:$key" >/dev/null
  # REST (not `gh issue list`, whose GraphQL index lags a just-created issue by seconds)
  local want t=0
  while [ $t -lt 60 ]; do
    want="$(gh api "repos/$REPO_GH/issues?state=all&per_page=100&labels=prd:$key" --jq '.[] | select(.title == "PRD: '"$key"'") | .number' 2>/dev/null | head -1)"
    [ -n "$want" ] && break; sleep 5; t=$((t+5))
  done
  echo "expected issue number for 'PRD: $key': #$want (after ${t}s)" | tee "$d/expected.txt" >&2
  local l; l="$(line_of common/create-issue.yaml '^- RUN: set -o pipefail; gh api "repos/' 1)"
  # since #53 the lookup reads the title from /tmp/issue-title.txt (written by the WRITE
  # step at the top of the file) instead of taking it as a rendered argv
  printf '%s' "Story 1.1: Login Form" > /tmp/issue-title.txt
  replay $c absent      common/create-issue.yaml "$l" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  printf '%s' "PRD: $key" > /tmp/issue-title.txt
  replay $c present     common/create-issue.yaml "$l" project="$REPO_GH" host=github.com sep=: prd_key="$key"
  # #33: the same step over the 105-issue label seeded by d4 (>1 page of 100)
  printf '%s' "Story 1.1: Login Form" > /tmp/issue-title.txt
  replay $c bulk-absent common/create-issue.yaml "$l" project="$REPO_GH" host=github.com sep=: prd_key=bulkprd
  gh api "repos/$REPO_GH/issues?state=all&per_page=100&labels=prd:bulkprd" --paginate 2>/dev/null | uv run --no-project python -c "
import json, sys
dec = json.JSONDecoder()
text = sys.stdin.read()
pos, pages = 0, []
while pos < len(text):
    if text[pos].isspace():
        pos += 1
        continue
    page, pos = dec.raw_decode(text, pos)
    pages.append(page)
print('documents=%d issues=%d bytes=%d newlines=%d' % (len(pages), sum(len(p) for p in pages), len(text), text.count(chr(10))))
" > "$d/paginate-shape.txt" 2>&1
  local pages; pages="$(cat "$d/paginate-shape.txt")"; echo "prd:bulkprd --paginate shape: $pages" >&2
  local a p b; a="$(tr -d '[:space:]' < "$d/absent.out")"; p="$(tr -d '[:space:]' < "$d/present.out")"; b="$(tr -d '[:space:]' < "$d/bulk-absent.out")"
  if [ "$(cat "$d/absent.rc")" = 0 ] && [ -z "$a" ] && [ "$p" = "$want" ] && [ "$(cat "$d/bulk-absent.rc")" = 0 ] && [ -z "$b" ]; then
    verdict $c REFUTED "create-issue.yaml:$l returns an EMPTY string (rc=0) for the absent title 'Story 1.1: Login Form' instead of halting, and #$p for 'PRD: $key' — the caller's 'CHECK: empty found_issue_id' now reaches the creation branch. Over the 105-issue label prd:bulkprd it is rc=0 and empty too ($pages): on this ARRAY endpoint gh --paginate merges the pages into ONE document, so #33's 'Extra data' is a search/issues shape (already fixed in sync-issues/find-issue); the raw_decode loop parses either"
  else
    verdict $c CONFIRMED "create-issue.yaml:$l did not behave as a lookup: absent rc=$(cat "$d/absent.rc") out='$a' (want empty); present out='$p' (want '$want'); bulk rc=$(cat "$d/bulk-absent.rc") out='$b' (want empty) err='$(head -c 160 "$d/bulk-absent.err" | tr '\n' ' ')'"
  fi
}

case_r1() {  # #47 — `gh issue create` prints a URL, not JSON: reading `number` off it halts
  # The pre-fix step was `FILTER source: create_result select: number`. lang §5 stops the
  # workflow when a FILTER finds nothing, and it finds nothing in a one-line URL — so the
  # issue was created and the status label, the comment and the MR's issue_ref were all
  # skipped. The next run adopts the issue by exact title, which is why nothing reported it.
  local c=r1; load_lab; local d; d="$(case_dir $c)"; local key=r1prd
  gh label create "prd:$key" -R "$REPO_GH" >/dev/null 2>&1 || true
  local title="R1 probe $(date +%s)"
  printf '**Sprint Key:** `%s`\n' "$title" > "$d/desc.md"
  # locator: the GitHub create step is the SECOND `STORE: create_result` (the first is glab)
  local lc lx
  lc="$(run_line_of_n common/create-issue.yaml 'STORE: create_result' 2)"
  lx="$(run_line_of common/create-issue.yaml 'm = re\.search')"
  [ -n "$lc" ] && [ -n "$lx" ] || { verdict $c BLOCKED "cannot locate the create step ($lc) or the id extraction ($lx) in create-issue.yaml"; return; }
  # since #53 the title travels in /tmp/issue-title.txt (the WRITE step at the top of the
  # file), never on the command line — so the case lays the file down instead of
  # rendering a {title} placeholder
  printf '%s' "$title" > /tmp/issue-title.txt
  replay $c create common/create-issue.yaml "$lc" description_file="$d/desc.md" label_arg="prd:$key" host=github.com project="$REPO_GH"
  local url want; url="$(tail -1 "$d/create.out")"; want="${url##*/}"
  replay $c extract common/create-issue.yaml "$lx" create_result="$(cat "$d/create.out")"
  local got; got="$(tr -d '[:space:]' < "$d/extract.out")"
  # the pre-fix shape against the same output, for the record: a `number` field to select
  uv run --no-project python -c "
import json, sys
try:
    obj = json.loads(open(sys.argv[1], encoding='utf-8').read())
    print('number=' + str(obj.get('number')))
except Exception as e:
    print('not JSON: ' + type(e).__name__)
" "$d/create.out" > "$d/prefix-filter.txt" 2>&1
  { echo "create stdout: $(head -c 200 "$d/create.out" | tr '\n' ' ')"
    echo "issue number from the URL: #${want:-(none)}  extraction step → '#${got:-(empty)}'"
    echo "what a FILTER select: number had to read: $(cat "$d/prefix-filter.txt")"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  [ -n "$want" ] && gh issue close "$want" -R "$REPO_GH" >/dev/null 2>&1
  if [ "$(cat "$d/create.rc")" != 0 ] || [ -z "$want" ]; then
    verdict $c BLOCKED "the create step did not create an issue: rc=$(cat "$d/create.rc") out='$(head -c 160 "$d/create.out")' err='$(head -c 160 "$d/create.err" | tr '\n' ' ')'"
  elif [ "$got" = "$want" ]; then
    verdict $c REFUTED "create-issue.yaml:$lc created issue #$want and printed only its URL ($(head -c 60 "$d/create.out" | tr -d '\n')); create-issue.yaml:$lx reads the trailing integer off it → issue_id='$got'. The pre-fix 'FILTER select: number' had nothing to read ($(cat "$d/prefix-filter.txt")) and lang §5 halted the workflow there, after the issue existed"
  else
    verdict $c CONFIRMED "create-issue.yaml:$lx does not recover the issue number from the create output: created #$want, extracted '#${got:-(empty)}' (rc=$(cat "$d/extract.rc")) from '$(head -c 80 "$d/create.out" | tr -d '\n')'"
  fi
}

case_r3() {  # #49 — an empty run list seconds after a push must not read as "no CI"
  # review-finish pushes and gates in the same breath. `gh run list --branch <src>` answers
  # [] until Actions registers the run; get-mr-pipeline reports `none`, the pre-fix
  # check-mr-ci mapped that to no_ci, wait-for-green-ci STOPped and write-ci-status wrote
  # ci-status.json GREEN while the run that would fail had not started.
  local c=r3; load_lab; local d; d="$(case_dir $c)"
  local ldef lmap lps
  ldef="$(line_of common/check-mr-ci.yaml '- RUN: ls \.github/workflows' 1)"
  lmap="$(run_line_of common/check-mr-ci.yaml 'defined = \(sys\.argv\[2\]')"
  lps="$(line_of common/get-mr-pipeline.yaml '- RUN: gh run list' 2)"
  [ -n "$ldef" ] && [ -n "$lmap" ] && [ -n "$lps" ] || { verdict $c BLOCKED "cannot locate the ci_defined probe ($ldef), the mapping ($lmap) or the run lookup ($lps)"; return; }
  cd "$CONSUMER"; git checkout -q main; git pull -q --ff-only origin main 2>/dev/null || true
  git branch -D ci-green >/dev/null 2>&1 || true
  git checkout -q -b ci-green main; set_outcome . pass
  git commit -q --allow-empty -m "r3 marker $(date +%s)"
  git push -q -f -u origin ci-green > "$d/push.log" 2>&1 || warn "push ci-green failed: $(tail -1 "$d/push.log")"
  # ci-green carries COMPLETED runs from d2, and `gh run list --branch` answers with the
  # newest one until the push registers its own — a stale answer, not the empty list this
  # case is about. The probe therefore rides a branch that has never been built, which is
  # exactly the state a story branch is in on its first dev-finish.
  local fbr="r3-fresh-$(date +%s)"
  git checkout -q -b "$fbr" ci-green
  git commit -q --allow-empty -m "r3 fresh-branch marker"
  git push -q -u origin "$fbr" >> "$d/push.log" 2>&1 || warn "push $fbr failed: $(tail -1 "$d/push.log")"
  # --- live: what the module sees in the first seconds after that push ---
  local t0; t0="$(date +%s)"
  replay $c pipeline_status common/get-mr-pipeline.yaml "$lps" mr_repo="github.com/$REPO_GH" source_branch="$fbr"
  replay $c pipeline_status_ci_green common/get-mr-pipeline.yaml "$lps" mr_repo="github.com/$REPO_GH" source_branch=ci-green
  replay $c ci_defined common/check-mr-ci.yaml "$ldef"
  local ps def; ps="$(tr -d '[:space:]' < "$d/pipeline_status.out")"; def="$(tr -d '[:space:]' < "$d/ci_defined.out")"
  replay $c mapping common/check-mr-ci.yaml "$lmap" pipeline_status="$ps" ci_defined="$def"
  local dt; dt=$(( $(date +%s) - t0 ))
  local live; live="$(tr -d '[:space:]' < "$d/mapping.out")"
  # --- deterministic: the same mapping on the two answers `none` can mean ---
  replay $c map-none-defined  common/check-mr-ci.yaml "$lmap" pipeline_status=none ci_defined=true
  replay $c map-none-noci     common/check-mr-ci.yaml "$lmap" pipeline_status=none ci_defined=false
  replay $c map-failure       common/check-mr-ci.yaml "$lmap" pipeline_status=failure ci_defined=true
  local mnd mnn mf
  mnd="$(tr -d '[:space:]' < "$d/map-none-defined.out")"
  mnn="$(tr -d '[:space:]' < "$d/map-none-noci.out")"
  mf="$(tr -d '[:space:]' < "$d/map-failure.out")"
  # the pre-fix rule over the same live answer, for the record
  uv run --no-project python -c "
import sys
ps = sys.argv[1].strip()
print('passed' if ps == 'success' else 'failed' if ps in ('failed', 'failure') else 'running' if ps in ('running', 'pending', 'queued', 'in_progress') else 'no_ci')
" "$ps" > "$d/prefix-mapping.txt" 2>&1
  git checkout -q main
  git push -q origin --delete "$fbr" >/dev/null 2>&1 || true
  git branch -D "$fbr" >/dev/null 2>&1 || true
  { echo "push → first lookup on the never-built branch $fbr after ${dt}s: pipeline_status='$ps', ci_defined='$def' → ci_status='$live' (pre-fix rule: $(cat "$d/prefix-mapping.txt"))"
    echo "same instant on ci-green (which already carries d2's completed runs): pipeline_status='$(tr -d '[:space:]' < "$d/pipeline_status_ci_green.out")'"
    echo "mapping(none, defined=true)  → '$mnd' (want running)"
    echo "mapping(none, defined=false) → '$mnn' (want no_ci)"
    echo "mapping(failure)             → '$mf'  (want failed)"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  if [ "$def" != true ]; then
    verdict $c BLOCKED "the consumer has no .github/workflows/*.yml (ci_defined='$def'), so there is no 'run not registered yet' to observe"
  elif [ "$live" != no_ci ] && [ "$mnd" = running ] && [ "$mnn" = no_ci ] && [ "$mf" = failed ]; then
    verdict $c REFUTED "check-mr-ci.yaml:$lmap reads an empty run list as a run that has not started: ${dt}s after pushing the never-built branch $fbr the lookup at get-mr-pipeline.yaml:$lps answered pipeline_status='$ps' and the mapping returned '$live', not no_ci (the pre-fix rule returned $(cat "$d/prefix-mapping.txt")). The discriminator is the CI definition on the branch (check-mr-ci.yaml:$ldef → '$def'): mapping(none, defined) = '$mnd' and mapping(none, undefined) = '$mnn', so a genuinely CI-less repo is still green at no cost, and a real failure is still '$mf'"
  else
    verdict $c CONFIRMED "check-mr-ci.yaml:$lmap still calls an unregistered run 'no CI': ${dt}s after the push pipeline_status='$ps' ci_defined='$def' → '$live'; mapping(none,true)='$mnd' (want running), mapping(none,false)='$mnn' (want no_ci), mapping(failure)='$mf' (want failed)"
  fi
}

case_r7() {  # #53 — a title carrying a quote or $(…) must reach the tracker intact
  # Same class as D09: the title was interpolated inside double quotes in the lookup, in a
  # python argv and in `gh issue create --title "{title}"`. Story titles come from
  # user-typed spec frontmatter, so a double quote split the command (syntax error → the
  # hook halts on every dev-finish of that story) and a $(…) was EXECUTED.
  local c=r7; load_lab; local d; d="$(case_dir $c)"; local key=r7prd
  gh label create "prd:$key" -R "$REPO_GH" >/dev/null 2>&1 || true
  local title
  title='R7 "quoted" $(echo INJECTED) `backtick` probe '"$(date +%s)"
  printf '%s' "$title" > /tmp/issue-title.txt
  printf '**Sprint Key:** `r7probe`\n' > "$d/desc.md"
  local lc; lc="$(run_line_of_n common/create-issue.yaml 'STORE: create_result' 2)"
  [ -n "$lc" ] || { verdict $c BLOCKED "cannot locate the GitHub create step in create-issue.yaml"; return; }
  # {title} is still offered to the renderer on purpose: the step must no longer NAME it,
  # exactly as case_d9 checks for {description_body}. A render that resolved it would put
  # the hostile text back on the command line and this case would see it.
  $TT render-step common/create-issue.yaml "$lc" title="$title" description_file="$d/desc.md" label_arg="prd:$key" host=github.com project="$REPO_GH" > "$d/rendered.cmd"
  bash -n "$d/rendered.cmd" > "$d/syntax.out" 2> "$d/syntax.err"; echo $? > "$d/syntax.rc"
  ( cd "$CONSUMER" && bash "$d/rendered.cmd" ) > "$d/create.out" 2> "$d/create.err"; echo $? > "$d/create.rc"
  local url n; url="$(tail -1 "$d/create.out")"; n="${url##*/}"
  case "$n" in ''|*[!0-9]*) n="";; esac
  # raw, not --json: a JSON blob escapes the very quotes this case is about
  if [ -n "$n" ]; then gh issue view "$n" -R "$REPO_GH" --json title --jq .title > "$d/issue-title.txt" 2>&1; else : > "$d/issue-title.txt"; fi
  local got; got="$(cat "$d/issue-title.txt")"
  # the command line must not carry the title at all
  local online=0; grep -qF 'echo INJECTED' "$d/rendered.cmd" && online=1
  # the substitution ran exactly when INJECTED shows up without its wrapper
  local inj=0
  grep -q INJECTED "$d/create.err" 2>/dev/null && inj=1
  if grep -q INJECTED "$d/issue-title.txt" 2>/dev/null && ! grep -qF '$(echo INJECTED)' "$d/issue-title.txt" 2>/dev/null; then inj=1; fi
  { echo "rendered command carries the title text? $online"
    echo "bash -n rc=$(cat "$d/syntax.rc") $(head -c 120 "$d/syntax.err" | tr '\n' ' ')"
    echo "create rc=$(cat "$d/create.rc") → #${n:-(none)}; err: $(head -c 160 "$d/create.err" | tr '\n' ' ')"
    echo "title sent:  [$title]"
    echo "title stored:[$got]"
    echo "\$(echo INJECTED) executed? $inj"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  [ -n "$n" ] && gh issue close "$n" -R "$REPO_GH" >/dev/null 2>&1
  rm -f /tmp/issue-title.txt
  if [ "$(cat "$d/syntax.rc")" = 0 ] && [ "$(cat "$d/create.rc")" = 0 ] && [ -n "$n" ] \
     && [ "$got" = "$title" ] && [ "$inj" = 0 ] && [ "$online" = 0 ]; then
    verdict $c REFUTED "create-issue.yaml:$lc never puts the title on the command line: the render does not name {title} at all (it is read from /tmp/issue-title.txt and handed to gh as one argv element), bash -n accepts the command, and issue #$n came back with the title '[$got]' byte for byte — the literal \$(echo INJECTED), the backtick and the double quotes all survived (executed=$inj)"
  else
    verdict $c CONFIRMED "create-issue.yaml:$lc takes the title apart: bash -n rc=$(cat "$d/syntax.rc"), create rc=$(cat "$d/create.rc") → issue '#${n:-(none)}', title stored '[$got]' vs sent '[$title]', \$(echo INJECTED) executed=$inj, title on the command line=$online; err '$(head -c 120 "$d/create.err" | tr '\n' ' ')'"
  fi
}

case_d9() {
  local c=d9; load_lab; local d; d="$(case_dir $c)"
  # a previous run's PR dump would answer the title/body questions for this one
  rm -f "$d/pr.json" "$d/pr-title.txt" "$d/pr-body.txt"
  cd "$CONSUMER"; git checkout -q main; local br="d9-quote-$(date +%s)"
  git checkout -q -b "$br" main; git commit -q --allow-empty -m "d9 probe"; git push -q -u origin "$br"; git checkout -q main
  local le; le="$(line_of common/ensure-mr.yaml 'gh pr create' 2)"
  local body; body="$(cat "$E2E_ROOT/fixtures/quoting-body.md")"
  # description_body is still passed: the step must no longer name that placeholder at
  # all (the body travels as a FILE now), so a render that still resolved it would put
  # the quoting-hostile text back on the command line and this case would see it.
  $TT render-step common/ensure-mr.yaml "$le" mr_title='Story 1.1: Login "Form"' description_body="$body" mr_description_file="$E2E_ROOT/fixtures/quoting-body.md" target_branch=main source_branch="$br" mr_repo="github.com/$REPO_GH" > "$d/rendered.cmd"
  bash -n "$d/rendered.cmd" > "$d/syntax.out" 2> "$d/syntax.err"; echo $? > "$d/syntax.rc"
  ( cd "$CONSUMER" && bash "$d/rendered.cmd" ) > "$d/run.out" 2> "$d/run.err"; echo $? > "$d/run.rc"
  # the literal step hides gh's own error behind `2>&1 | grep`; run the gh part alone for the record
  sed 's/ 2>&1 | grep .*$//' "$d/rendered.cmd" > "$d/gh-only.cmd"
  ( cd "$CONSUMER" && bash "$d/gh-only.cmd" ) > "$d/gh-only.out" 2> "$d/gh-only.err"; echo $? > "$d/gh-only.rc"
  grep -o 'pull/[0-9]*' "$d/gh-only.out" | head -1 | cut -d/ -f2 | xargs -r -I{} gh pr close {} -R "$REPO_GH" --delete-branch >/dev/null 2>&1
  local n=""; n="$(grep -o 'pull/[0-9]*' "$d/run.out" | head -1 | cut -d/ -f2)"
  # title and body are also read RAW (--jq): `--json title,body` escapes the quotes of
  # the very title this case is about, so the JSON blob cannot answer "did it survive?"
  if [ -n "$n" ]; then
    gh pr view "$n" -R "$REPO_GH" --json title,body > "$d/pr.json"
    gh pr view "$n" -R "$REPO_GH" --json title --jq .title > "$d/pr-title.txt"
    gh pr view "$n" -R "$REPO_GH" --json body --jq .body > "$d/pr-body.txt"
    gh pr close "$n" -R "$REPO_GH" --delete-branch >/dev/null 2>&1 || true
  fi
  git branch -D "$br" >/dev/null 2>&1 || true
  # "the shell ran $(echo INJECTED)" is not "the word INJECTED is somewhere": a body
  # delivered intact CONTAINS the literal $(echo INJECTED). The substitution executed
  # exactly when INJECTED appears without its wrapper — or when gh choked on it.
  local inj=0
  grep -q INJECTED "$d/gh-only.err" 2>/dev/null && inj=1
  if grep -q INJECTED "$d/pr-body.txt" 2>/dev/null && ! grep -qF '$(echo INJECTED)' "$d/pr-body.txt" 2>/dev/null; then inj=1; fi
  local titleok=0; grep -q 'Login "Form"' "$d/pr-title.txt" 2>/dev/null && titleok=1
  if [ "$(cat "$d/syntax.rc")" != 0 ] || [ "$inj" = 1 ] || [ "$titleok" = 0 ]; then
    verdict $c LATENT "ensure-mr.yaml:$le interpolates --title/--body inline: with a body holding quotes, a backtick and \$(…) the literal step 'succeeds' (pipeline rc=$(cat "$d/run.rc") — the '2>&1 | grep https' hides gh's exit) but creates $( [ -n "$n" ] && echo "a PR" || echo "NO PR"); gh alone rc=$(cat "$d/gh-only.rc"): '$(grep -m1 'unknown argument' "$d/gh-only.err" | cut -c1-110)'; the shell ran \$(echo INJECTED)=$inj and tried to execute the backtick ('$(grep -o 'backtick: command not found' "$d/run.err" | head -1)'); quoted title preserved=$titleok. Current callers pass benign bodies/titles, so LATENT"
  else verdict $c REFUTED "ensure-mr.yaml:$le hands the body to gh as a FILE and quotes the title as one argument: the render no longer names {description_body} at all, bash -n accepts the command, PR #$n was created with the title '$(cat "$d/pr-title.txt")' intact and a body that still carries the literal \$(echo INJECTED) (executed=$inj), and the create's own exit code (rc=$(cat "$d/run.rc")) is what the caller sees"; fi
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
# gl_want <issues.json> <exact title> — the iid the lookup ought to return, or empty
gl_want() { uv run --no-project python -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next((str(i["iid"]) for i in d if i["title"]==sys.argv[2]), ""))' "$1" "$2" 2>/dev/null; }

case_g06() {
  local c=g06; gl_setup $c || return; local d; d="$(case_dir $c)"
  # issues shaped like the module writes them: the sprint key sits in the DESCRIPTION
  gl_issue_body() { glab api "projects/$ENC/issues?labels=prd::$PRD_KEY&state=all&per_page=100" --hostname "$GLH" | grep -qF "\"title\":\"$1\"" || glab api --method POST "projects/$ENC/issues" --hostname "$GLH" -f "title=$1" -f "description=**Sprint Key:** \`$2\`" -f "labels=prd::$PRD_KEY" >/dev/null; }
  gl_issue_body "Story 1.1: Login Form" 1-1-login-form; gl_issue_body "Story 1.10: Login Form Extended" 1-10-login-form-extended
  gl_issue_body "Story 11.1: Eleven" 11-1-login-form; gl_issue_body "Epic 1: Authentication" epic-1; gl_issue_body "Epic 10: Placeholder" epic-10
  sleep 5
  local lf; lf="$(line_of common/find-issue.yaml 'glab api' 1)"
  # 'Epic 1:' goes in as written: since #32 the search text travels as a `-f` field and
  # glab percent-encodes it, so the previous revision's hand-encoded 'Epic%201:' control
  # searched for a literal '%' and returned 0 hits while claiming HTTP 400. It is gone;
  # the raw searches below show what the (deliberately unchanged) query still returns.
  REPLAY_CWD="$CONSUMER_GL" replay $c find-1-1 common/find-issue.yaml "$lf" search_text="1-1-login-form" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  REPLAY_CWD="$CONSUMER_GL" replay $c find-epic-1 common/find-issue.yaml "$lf" search_text="Epic 1:" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  glab api "projects/$ENC/issues" --method GET -f "search=1-1-login-form" -f "labels=prd::$PRD_KEY" --hostname "$GLH" --paginate > "$d/raw-1-1.json" 2>"$d/raw-1-1.err"
  glab api "projects/$ENC/issues" --method GET -f "search=Epic 1:" -f "labels=prd::$PRD_KEY" --hostname "$GLH" --paginate > "$d/raw-epic-1.json" 2>"$d/raw-epic-1.err"
  gl_titles "$d/raw-1-1.json" > "$d/titles-1-1.txt"; gl_titles "$d/raw-epic-1.json" > "$d/titles-epic.txt"; cat "$d/titles-1-1.txt" "$d/titles-epic.txt" >&2
  local n1 ne w1 we g1 ge
  n1="$(grep -c . "$d/titles-1-1.txt")"; ne="$(grep -c . "$d/titles-epic.txt")"
  w1="$(gl_want "$d/raw-1-1.json" "Story 1.1: Login Form")"; we="$(gl_want "$d/raw-epic-1.json" "Epic 1: Authentication")"
  g1="$(tr -d '[:space:]' < "$d/find-1-1.out")"; ge="$(tr -d '[:space:]' < "$d/find-epic-1.out")"
  local note="the query is untouched and still fuzzy: 'search=1-1-login-form' → $n1 hit(s) ($(tr '\n' ';' < "$d/titles-1-1.txt")), 'search=Epic 1:' → $ne ($(tr '\n' ';' < "$d/titles-epic.txt"))"
  if [ -z "$w1" ] || [ -z "$we" ]; then verdict $c BLOCKED "the seeded issues are not in the search result (find rc=$(cat "$d/find-1-1.rc"); $(head -c 200 "$d/raw-1-1.err")). $note"
  elif [ "$g1" != "$w1" ] || [ "$ge" != "$we" ]; then verdict $c CONFIRMED "find-issue.yaml:$lf (GitLab $GLH) picks the wrong issue: '1-1-login-form' → !${g1:-(empty)} but Story 1.1 is !$w1, and 'Epic 1:' → !${ge:-(empty)} but Epic 1 is !$we — the choice follows the index rank. $note"
  else verdict $c REFUTED "find-issue.yaml:$lf (GitLab $GLH) picks by identity, not by index rank: '1-1-login-form' → !$g1 'Story 1.1: Login Form' (its **Sprint Key** description marker, so 1.10 and 11.1 are excluded) and 'Epic 1:' → !$ge 'Epic 1: Authentication' (exact title prefix, 'Epic 10:' excluded). $note"; fi
}

case_gl-d23() {  # does the GitLab find-issue survive a space in search_text?
  local c=gl-d23; gl_setup $c || return; local d; d="$(case_dir $c)"
  gl_issue "PRD: $PRD_KEY"
  local lf; lf="$(line_of common/find-issue.yaml 'glab api' 1)"
  REPLAY_CWD="$CONSUMER_GL" replay $c find-prd common/find-issue.yaml "$lf" search_text="PRD: $PRD_KEY" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  # the step prints the SELECTED iid now, so the titles come from the raw search
  glab api "projects/$ENC/issues" --method GET -f "search=PRD: $PRD_KEY" -f "labels=prd::$PRD_KEY" --hostname "$GLH" --paginate > "$d/raw.json" 2>"$d/raw.err"
  gl_titles "$d/raw.json" > "$d/titles.txt"; cat "$d/titles.txt" >&2
  local want got; want="$(gl_want "$d/raw.json" "PRD: $PRD_KEY")"; got="$(tr -d '[:space:]' < "$d/find-prd.out")"
  if [ "$(cat "$d/find-prd.rc")" = 0 ] && [ -n "$got" ] && [ "$got" = "$want" ]; then verdict $c REFUTED "GitLab path: 'PRD: $PRD_KEY' with a space is found (rc=0, selected $(head -1 "$d/titles.txt")) — glab api encodes the -f field; D23 is GitHub-only"
  else verdict $c CONFIRMED "GitLab path fails with a space too, differently: glab sends the raw URL, nginx answers HTTP 400 and glab exits rc=$(cat "$d/find-prd.rc") → the RUN step HALTS the workflow (lang §5) instead of the silent [] of GitHub. Every 'PRD: {prd_key}' / 'Epic N:' lookup is dead on both platforms"; fi
}

case_gl-d16() {  # glab mr merge: stdout vs exit code
  local c=gl-d16; gl_setup $c || return; local d; d="$(case_dir $c)"
  cd "$CONSUMER_GL"; git checkout -q main; local br="gl-d16-$(date +%s)"
  git checkout -q -b "$br" main; echo "$br" > "$br.txt"; git add "$br.txt"; git commit -q -m "gl-d16 probe"; git push -q -u origin "$br"; git checkout -q main
  local iid; iid="$(glab mr create --title "gl-d16 probe" --description "probe" --source-branch "$br" --target-branch main -R "$GLH/$REPO_GL" --yes 2>&1 | grep -oE '/merge_requests/[0-9]+' | head -1 | grep -oE '[0-9]+$')"
  echo "mr=$iid" > "$d/mr.txt"; [ -n "$iid" ] || { verdict $c BLOCKED "could not create the MR: see mr.txt"; return; }
  # GitLab computes mergeability asynchronously: merging while detailed_merge_status is still
  # "checking" answers 405. Wait for the MR to settle (≤120 s) so the replay judges the merge step, not the race.
  local t=0 ms=""; while [ $t -lt 120 ]; do ms="$(glab api "projects/$ENC/merge_requests/$iid" --hostname "$GLH" | uv run --no-project python -c 'import json,sys; print(json.load(sys.stdin).get("detailed_merge_status",""))')"; [ "$ms" = mergeable ] && break; sleep 5; t=$((t+5)); done; echo "detailed_merge_status=$ms after ${t}s" > "$d/merge-status-wait.txt"
  # the probe branch triggers CI; merging while it runs makes glab schedule "merge when pipeline
  # succeeds" (rc 0, MR still open). Wait for that pipeline so the replay judges an immediate merge.
  echo "probe pipeline: $(gl_wait_pipeline "$br" 600)" >> "$d/merge-status-wait.txt"
  local lm; lm="$(line_of common/merge-mr.yaml 'RUN: glab mr merge' 1)"
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
  # since #40 the GitLab steps address the GIT REMOTE's project (git_project_enc/git_host,
  # resolved by check-config), not the tracker's — on this lab the two are the same project
  REPLAY_CWD="$CONSUMER_GL" replay $c pipeline_id common/get-mr-pipeline.yaml "$l1" git_project_enc="$ENC" mr_iid="$GREEN_IID" git_host="$GLH"
  REPLAY_CWD="$CONSUMER_GL" replay $c pipeline_status common/get-mr-pipeline.yaml "$l2" git_project_enc="$ENC" mr_iid="$GREEN_IID" git_host="$GLH"
  local got latest; got="$(tr -d '[:space:]' < "$d/pipeline_status.out")"; latest="$(uv run --no-project python -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[0]["ref"]+"="+d[0]["status"])' "$(case_dir gl-ci)/latest-pipelines.json")"
  if [ "$got" = success ]; then verdict $c REFUTED "GitLab path is per-MR and correct: get-mr-pipeline.yaml:$l2 for the green MR !$GREEN_IID → '$got' while the project's latest pipeline is $latest. D02 is GitHub-only"
  else verdict $c CONFIRMED "GitLab path also wrong: green MR reports '$got' (latest project pipeline $latest)"; fi
}

case_gl-d18() {  # the GitLab polling loop, live, against a finished MR pipeline
  local c=gl-d18; case_gl-ci || return; local d; d="$(case_dir $c)"
  local gl; gl="$(line_of common/wait-for-green-ci.yaml 'RUN: \|' 1)"
  $TT render-step common/wait-for-green-ci.yaml "$gl" git_project_enc="$ENC" mr_iid="$GREEN_IID" git_host="$GLH" > "$d/gitlab-loop.cmd"
  # polls_per_round replaced max_attempts when #14 split the 30-min loop into bounded rounds
  sed -E 's/polls_per_round=[0-9]+/polls_per_round=2/' "$d/gitlab-loop.cmd" > "$d/gitlab-loop-2.cmd"
  log "  (a) literal GitLab round, polls_per_round=2 (≈50 s), MR !$GREEN_IID (pipeline success)…"
  ( cd "$CONSUMER_GL" && bash "$d/gitlab-loop-2.cmd" ) > "$d/gitlab-loop-2.out" 2> "$d/gitlab-loop-2.err"; echo $? > "$d/gitlab-loop-2.rc"
  sed '/STATUS=\$(uv run --no-project python -c "/a import sys' "$d/gitlab-loop-2.cmd" > "$d/gitlab-loop-2-patched.cmd"
  log "  (b) +import sys (≈25 s)…"
  ( cd "$CONSUMER_GL" && bash "$d/gitlab-loop-2-patched.cmd" ) > "$d/gitlab-loop-2-patched.out" 2> "$d/gitlab-loop-2-patched.err"; echo $? > "$d/gitlab-loop-2-patched.rc"
  local a b; a="$(tr -d '[:space:]' < "$d/gitlab-loop-2.out")"; b="$(tr -d '[:space:]' < "$d/gitlab-loop-2-patched.out")"
  if [ "$a" = timeout ] && [ "$b" = passed ]; then verdict $c CONFIRMED "wait-for-green-ci.yaml:$gl (GitLab, $GLH) against MR !$GREEN_IID whose pipeline is success: literal round → '$a' after its polls; with 'import sys' → '$b' on the first poll. D18 hits both platforms"
  else verdict $c REFUTED "literal='$a' patched='$b' (see $d)"; fi
}

case_d03() {  # #14 — does ONE poll round return long before the Bash tool cap?
  local c=d03; gl_setup $c || return; local d; d="$(case_dir $c)"
  local gl; gl="$(line_of common/wait-for-green-ci.yaml 'RUN: \|' 1)"
  local br=gl-ci-slow
  cd "$CONSUMER_GL"; git checkout -q main; git pull -q --ff-only origin main 2>/dev/null || true
  git branch -D "$br" >/dev/null 2>&1; git checkout -q -b "$br" main
  set_outcome . "sleep:400"; git commit -q --allow-empty -m "d03 marker $(date +%s)"
  git push -q -f -u origin "$br"; git checkout -q main
  local iid; iid="$(gl_mr_for "$br")"; echo "mr=$iid" > "$d/mr.txt"
  [ -n "$iid" ] || { verdict $c BLOCKED "could not create the MR for $br"; cd - >/dev/null; return; }
  $TT render-step common/wait-for-green-ci.yaml "$gl" git_project_enc="$ENC" mr_iid="$iid" git_host="$GLH" > "$d/poll.cmd"
  # static half: the rendered round must be bounded — no 60-attempt (30-min) RUN left
  local sl po worst
  sl="$(grep -o 'sleep [0-9]*' "$d/poll.cmd" | awk '{print $2}' | sort -n | tail -1)"
  po="$(grep -oE '(polls_per_round|max_attempts)=[0-9]+' "$d/poll.cmd" | cut -d= -f2 | sort -n | tail -1)"
  worst=$(( ${sl:-0} * ${po:-0} )); echo "sleep=$sl polls=$po worst=${worst}s" | tee "$d/bound.txt" >&2
  # the timed round has to start while the pipeline is still running
  local t=0 st=""
  while [ $t -lt 240 ]; do
    st="$(glab api "projects/$ENC/merge_requests/$iid/pipelines" --hostname "$GLH" 2>/dev/null | uv run --no-project python -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["status"] if d else "")')"
    case "$st" in running|pending) break;; esac
    sleep 5; t=$((t+5))
  done
  echo "pipeline status before the timed round: ${st:-(none)}" > "$d/pipeline-before.txt"
  log "  (a) one poll round while the MR !$iid pipeline is ${st:-(none)}…"
  local t0 dur_run dur_final a b final
  t0=$(date +%s); ( cd "$CONSUMER_GL" && bash "$d/poll.cmd" ) > "$d/poll-running.out" 2> "$d/poll-running.err"; echo $? > "$d/poll-running.rc"
  dur_run=$(( $(date +%s) - t0 )); a="$(tr -d '[:space:]' < "$d/poll-running.out")"
  log "      → '$a' in ${dur_run}s; waiting for the pipeline to finish…"
  final="$(gl_wait_pipeline "$br" 900)"; echo "$final" > "$d/pipeline-final.txt"
  log "  (b) one poll round with the pipeline $final…"
  t0=$(date +%s); ( cd "$CONSUMER_GL" && bash "$d/poll.cmd" ) > "$d/poll-final.out" 2> "$d/poll-final.err"; echo $? > "$d/poll-final.rc"
  dur_final=$(( $(date +%s) - t0 )); b="$(tr -d '[:space:]' < "$d/poll-final.out")"
  log "      → '$b' in ${dur_final}s"
  cd - >/dev/null
  local note="bound sleep $sl × $po polls = ${worst}s; running-round '$a' in ${dur_run}s (pipeline $st), terminal-round '$b' in ${dur_final}s (pipeline $final)"
  if [ "$st" != running ] && [ "$st" != pending ]; then verdict $c BLOCKED "the pipeline for $br never reached running/pending (status '${st:-none}') — nothing to time. $note"
  elif [ "$worst" -le 240 ] && [ "$a" = running ] && [ "$dur_run" -le 240 ] && [ "$b" = passed ] && [ "$dur_final" -le 240 ]; then
    verdict $c REFUTED "wait-for-green-ci.yaml:$gl (GitLab, $GLH) against MR !$iid with ci/outcome sleep:400: one poll round is bounded and returns a status instead of being killed — $note. Both rounds finish far under the Bash tool's 600 s cap (120 s default), so ci_status is stored after every round and write-ci-status always gets a value; the 30-min wait is the LOOP's rounds, not one RUN"
  else verdict $c CONFIRMED "one RUN still overruns the tool cap or loses the status: $note"; fi
}

case_gl-d4() {  # glab api --paginate | json.load
  local c=gl-d4; gl_setup $c || return; local d; d="$(case_dir $c)"
  local have; have="$(glab api "projects/$ENC/issues?labels=prd::bulkprd&state=all&per_page=100" --hostname "$GLH" --paginate 2>/dev/null | grep -o '"iid"' | wc -l)"
  glab label create --name "prd::bulkprd" -R "$GLH/$REPO_GL" >/dev/null 2>&1 || true
  local i="$have"; while [ "$i" -lt 105 ]; do i=$((i+1)); glab api --method POST "projects/$ENC/issues" --hostname "$GLH" -f "title=Seed $i (bulkprd)" -f "labels=prd::bulkprd" >/dev/null 2>&1 || { sleep 20; i=$((i-1)); }; printf '\r  seeded %d/105' "$i" >&2; sleep 0.4; done; echo >&2
  glab api "projects/$ENC/issues?labels=prd::bulkprd&state=all&per_page=100" --hostname "$GLH" --paginate | uv run --no-project python -c 'import sys; s=sys.stdin.read(); print("bytes=%d newlines=%d objects=%d" % (len(s), s.count(chr(10)), s.count("[{")))' > "$d/paginate-shape.txt" 2>&1; cat "$d/paginate-shape.txt" >&2
  local l; l="$(line_of common/sync-issues.yaml 'glab api "projects' 1)"
  REPLAY_CWD="$CONSUMER_GL" replay $c bulk-fetch common/sync-issues.yaml "$l" project_enc="$ENC" sep=:: prd_key=bulkprd host="$GLH"
  if [ "$(cat "$d/bulk-fetch.rc")" = 0 ] && [ "$(grep -c . "$d/bulk-fetch.out")" -ge 105 ]; then verdict $c REFUTED "GitLab path reads the whole --paginate stream: rc=0, $(grep -c . "$d/bulk-fetch.out") rows ($(cat "$d/paginate-shape.txt")) — objects>1 means glab concatenated the pages and the step parsed them anyway"
  else verdict $c CONFIRMED "GitLab path too: rc=$(cat "$d/bulk-fetch.rc") rows=$(grep -c . "$d/bulk-fetch.out") $(head -c 160 "$d/bulk-fetch.err") ($(cat "$d/paginate-shape.txt"))"; fi
}

case_d26() {  # #36 — the retrospective issue carries no **Sprint Key** marker, so sync never finds it
  local c=d26; gl_setup $c || return; local d; d="$(case_dir $c)"
  # (a) rendering: the description retrospective/complete.yaml WRITEs for epic 1.
  # The WRITE content is a double-quoted YAML scalar, so the raw line carries literal \n —
  # printf '%b' expands them the way the runtime does before the file reaches the tracker.
  local tmpl; tmpl="$(sed -n 's/^ *content: "\(.*\)"$/\1/p' "$WF/retrospective/complete.yaml" | head -1)"
  printf '%b\n' "$(render "$tmpl" epic_number=1 retrospective_content="What went well: the lab.")" > "$d/retro-desc.md"
  # the pre-fix shape of the same description, as the control the search cannot find
  printf '%b\n' "$(render '**Epic:** {epic_number}\n\n---\n\n{retrospective_content}' epic_number=9 retrospective_content="What went well: the lab.")" > "$d/retro-desc-nomarker.md"
  cat "$d/retro-desc.md" "$d/retro-desc-nomarker.md" >&2
  local marker='**Sprint Key:** `epic-1-retrospective`'
  local has_marker=0; grep -qF "$marker" "$d/retro-desc.md" && has_marker=1
  # (b) the two issues, shaped exactly like the hook writes them (title + prd label + body)
  gl_issue_desc() {  # gl_issue_desc <title> <desc-file> → iid (create, or overwrite the body)
    local iid
    iid="$(glab api "projects/$ENC/issues?labels=prd::$PRD_KEY&state=all&per_page=100" --hostname "$GLH" | uv run --no-project python -c 'import json,sys; d=json.load(sys.stdin); print(next((str(i["iid"]) for i in d if i["title"]==sys.argv[1]), ""))' "$1")"
    if [ -n "$iid" ]; then
      glab api --method PUT "projects/$ENC/issues/$iid" --hostname "$GLH" -F "description=@$2" >/dev/null
    else
      iid="$(glab api --method POST "projects/$ENC/issues" --hostname "$GLH" -f "title=$1" -F "description=@$2" -f "labels=prd::$PRD_KEY" | uv run --no-project python -c 'import json,sys; print(json.load(sys.stdin)["iid"])')"
    fi
    echo "$iid"
  }
  local want ctrl_iid
  want="$(gl_issue_desc "Retrospective: Epic 1" "$d/retro-desc.md")"
  ctrl_iid="$(gl_issue_desc "Retrospective: Epic 9" "$d/retro-desc-nomarker.md")"
  echo "seeded !$want (with marker) and !$ctrl_iid (pre-fix body)" | tee "$d/seeded.txt" >&2
  sleep 5
  # (c) the selection step sync-issues reaches, with the key-shaped search_text it passes
  local lf; lf="$(line_of common/find-issue.yaml 'glab api' 1)"
  REPLAY_CWD="$CONSUMER_GL" replay $c find-retro    common/find-issue.yaml "$lf" search_text="epic-1-retrospective" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  REPLAY_CWD="$CONSUMER_GL" replay $c find-nomarker common/find-issue.yaml "$lf" search_text="epic-9-retrospective" project_enc="$ENC" sep=:: prd_key="$PRD_KEY" host="$GLH"
  local got ctrl; got="$(tr -d '[:space:]' < "$d/find-retro.out")"; ctrl="$(tr -d '[:space:]' < "$d/find-nomarker.out")"
  { echo "marker in the rendered description: $has_marker"
    echo "search 'epic-1-retrospective' (marker present, !$want) → '${got:-(empty)}'"
    echo "search 'epic-9-retrospective' (pre-fix body, !$ctrl_iid) → '${ctrl:-(empty)}'"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  if [ "$has_marker" = 1 ] && [ "$got" = "$want" ] && [ -z "$ctrl" ]; then
    verdict $c REFUTED "retrospective/complete.yaml writes the same identity every other producer writes: the rendered description carries '$marker', and find-issue.yaml:$lf selects !$got for the key-shaped search_text 'epic-1-retrospective' that sync-issues passes. The pre-fix body (!$ctrl_iid, '**Epic:** 9' and nothing else) is invisible to 'epic-9-retrospective' → '${ctrl:-(empty)}', which is what every sync saw: the retrospective counted as created each time and its status label never reconciled"
  else
    verdict $c CONFIRMED "the retrospective issue cannot be found by its key: marker present in the rendered description? $has_marker; find-issue.yaml:$lf on 'epic-1-retrospective' → '${got:-(empty)}' (want !$want); control on the pre-fix body → '${ctrl:-(empty)}' (want empty). create-issue adopts it by exact title, so there is no duplicate — only a sync that never reconciles it"
  fi
}

case_g10() {
  local c=g10; local d; load_lab 2>/dev/null || true; d="$(mkdir -p "$E2E_ROOT/evidence/${LAB_ID:-static}/g10" && echo "$E2E_ROOT/evidence/${LAB_ID:-static}/g10")"
  # rendering proof: cross-platform (issues on GitHub, code on GitLab) — which repo do the MR atomics hit?
  # locator anchored on '- RUN:' for the same reason as case_d2, minus the '^': since #15 the
  # MR/CI steps sit inside `CHECK: git_platform eq "gitlab"` and are indented.
  local l1; l1="$(line_of common/get-mr-pipeline.yaml '- RUN: gh run list' 1)"
  $TT render-step common/get-mr-pipeline.yaml "$l1" host=github.com project=acme/issues-repo mr_repo=gitlab.com/acme/code-repo source_branch=feat/x/1-1 > "$d/get-mr-pipeline.cmd"
  # merge-mr's cross-platform merge. With issues on GitHub and code on GitLab the merge is a
  # GitLab one, so THIS is the step the scenario reaches: before #15 the file routed on
  # `platform` (the tracker) and ran `gh pr merge` here, against a gitlab.com repo path.
  # The render supplies git_host/git_project because the atomic now READs them itself —
  # no caller seeds them any more, and it no longer names {git_owner}/{git_repo} at all.
  local l2; l2="$(line_of common/merge-mr.yaml 'RUN: glab mr merge' 2)"
  $TT render-step common/merge-mr.yaml "$l2" mr_iid=7 squash=true git_host=gitlab.com git_project=acme/code-repo > "$d/merge-mr-cross.cmd"
  # the mirror case (issues on GitLab, code on GitHub) renders the gh cross-platform branch
  local l3; l3="$(line_of common/merge-mr.yaml 'RUN: gh pr merge' 2)"
  $TT render-step common/merge-mr.yaml "$l3" mr_iid=7 git_host=github.com git_project=acme/code-repo > "$d/merge-mr-cross-gh.cmd"
  grep -n 'git_owner\|git_repo' "$WF/common/check-config.yaml" > "$d/check-config-defines.txt" || echo "(check-config defines neither git_owner nor git_repo)" > "$d/check-config-defines.txt"
  local unres; unres="$(cat "$d/merge-mr-cross.cmd" "$d/merge-mr-cross-gh.cmd" | grep -o '{[a-z_]*}' | sort -u | tr '\n' ' ')"
  cat "$d/get-mr-pipeline.cmd" "$d/merge-mr-cross.cmd" "$d/merge-mr-cross-gh.cmd" "$d/check-config-defines.txt" >&2
  echo "unresolved placeholders in the two cross-platform merge renders: ${unres:-(none)}" | tee "$d/unresolved.txt" >&2
  if grep -q 'github.com/acme/issues-repo' "$d/get-mr-pipeline.cmd" && grep -q '{git_owner}' "$d/merge-mr-cross.cmd"; then
    verdict $c CONFIRMED "get-mr-pipeline.yaml:$l1 renders 'gh run list -R github.com/acme/issues-repo' (the ISSUE tracker) although the MR lives in mr_repo=gitlab.com/acme/code-repo; merge-mr.yaml:$l2 leaves {git_owner}/{git_repo} unresolved (check-config sets neither) → lang §4.5 halts the workflow"
  else verdict $c REFUTED "the condition needs BOTH halves of D10 and both are now fixed. get-mr-pipeline.yaml:$l1 renders '$(grep -o -- '-R "[^"]*"' "$d/get-mr-pipeline.cmd" | head -1)' — the git remote, not the tracker (#34). merge-mr.yaml:$l2 is the step this mix reaches now that the merge routes on git_platform instead of platform: '$(grep -o -- 'glab mr merge[^|]*' "$d/merge-mr-cross.cmd" | head -1)' (it used to run gh pr merge against a gitlab.com path), and the mirror branch merge-mr.yaml:$l3 renders '$(grep -o -- 'gh pr merge[^&]*' "$d/merge-mr-cross-gh.cmd" | head -1)'. Unresolved placeholders in both: ${unres:-none} — the atomic READs git_host/git_project itself, so check-config defining neither git_owner nor git_repo no longer halts it on lang §4.5"; fi
}

# spec_fixtures <dir> — render the 6.12.0-shaped spec (frontmatter title, no H1) and the
# legacy H1 variant into <dir>, the way write_spec does for the level-2 scenarios
spec_fixtures() {
  mkdir -p "$1/ia"
  uv run --no-project python - "$E2E_ROOT" "$1" <<'PY'
import sys
e2e, work = sys.argv[1], sys.argv[2]
t = open(e2e + '/fixtures/consumer/implementation-artifacts/spec-1-1-login-form.md.tmpl').read()
rows = open(e2e + '/fixtures/triage-rows.md').read().rstrip()
open(work + '/ia/spec-1-1-login-form.md', 'w').write(t.replace('@STATUS@', 'in-review').replace('@TRIAGE_ROWS@', rows))
PY
  cp "$E2E_ROOT/fixtures/consumer/implementation-artifacts/spec-1-1-login-form.legacy-h1.md" "$1/legacy-h1.md"
  # the status step reads sprint-status.yaml by key (#52), so the fixture needs one;
  # @S11@ is the placeholder lab-up substitutes per scenario
  sed 's/@S11@/backlog/' "$E2E_ROOT/fixtures/consumer/implementation-artifacts/sprint-status.yaml" > "$1/ia/sprint-status.yaml"
}

case_d21() {  # #12 — story issue titles come out empty: the 6.12.0 spec template has no H1
  local c=d21; load_lab; local d; d="$(case_dir $c)"
  local work="$d/work"; rm -rf "$work"; spec_fixtures "$work"
  # what the pre-fix rules produced against the SAME fixture, for the before/after record:
  # ensure-issue read the first '# ' line (none in 6.12.0 → empty title → "Story 1.1: "),
  # sync-issues read the first '#' line (→ '## Intent' → "Story 1.1: Intent").
  uv run --no-project python -c "
import sys
for line in open(sys.argv[1], encoding='utf-8'):
    if line.startswith('# '):
        print(line[2:].strip())
        break
" "$work/ia/spec-1-1-login-form.md" > "$d/old-rule-ensure.out" 2>&1
  uv run --no-project python -c "
import sys
for line in open(sys.argv[1], encoding='utf-8'):
    if line.startswith('#'):
        print(line.lstrip('#').strip())
        break
" "$work/ia/spec-1-1-login-form.md" > "$d/old-rule-sync.out" 2>&1
  local le ls
  le="$(run_line_of common/ensure-issue.yaml 'STORE: story_title')"
  ls="$(run_line_of common/sync-issues.yaml 'candidates\.append')"
  replay $c tmpl   common/ensure-issue.yaml "$le" spec_path="$work/ia/spec-1-1-login-form.md" story_key=1-1-login-form
  replay $c legacy common/ensure-issue.yaml "$le" spec_path="$work/legacy-h1.md" story_key=1-1-login-form
  replay $c sync-tmpl common/sync-issues.yaml "$ls" implementation_artifacts="$work/ia" entry_key=1-1-login-form
  local a b s old_e old_s
  a="$(head -1 "$d/tmpl.out")"; b="$(head -1 "$d/legacy.out")"; s="$(head -1 "$d/sync-tmpl.out")"
  old_e="$(head -1 "$d/old-rule-ensure.out")"; old_s="$(head -1 "$d/old-rule-sync.out")"
  { echo "ensure-issue.yaml:$le  6.12.0 template → '$a'   (first-'# '-line rule gave '$old_e')"
    echo "ensure-issue.yaml:$le  legacy H1       → '$b'"
    echo "sync-issues.yaml:$ls   6.12.0 template → '$s'   (first-'#'-line rule gave '$old_s')"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  if [ "$a" = "Login Form" ] && [ "$b" = "Login Form" ] && [ "$s" = "Story 1.1: Login Form" ]; then
    verdict $c REFUTED "the title comes from the spec frontmatter: ensure-issue.yaml:$le → '$a' on the 6.12.0 template (whose first heading is '## Intent' inside <intent-contract>, so the old first-'# '-line rule produced '$old_e' → the issue title 'Story 1.1: ') and '$b' on the legacy H1 variant; sync-issues.yaml:$ls → '$s' (old rule: '$old_s')"
  else
    verdict $c CONFIRMED "the title is still taken from a heading: ensure-issue.yaml:$le → '$a' (want 'Login Form'), legacy → '$b' (want 'Login Form'), sync-issues.yaml:$ls → '$s' (want 'Story 1.1: Login Form'). The 6.12.0 spec template has no H1 — the title lives in the frontmatter"
  fi
}

case_d15() {  # #13 — the loop item renders as "key: status" and the key leaked everywhere
  local c=d15; load_lab; local d; d="$(case_dir $c)"
  local work="$d/work"; rm -rf "$work"; spec_fixtures "$work"
  local lk lst lt
  lk="$(run_line_of common/sync-issues.yaml 'STORE: entry_key')"
  lst="$(run_line_of common/sync-issues.yaml 'STORE: entry_status')"
  lt="$(run_line_of common/sync-issues.yaml 'candidates\.append')"
  # both renderings lang §4.1 leaves open: "key: status" (what the interpreter does) and
  # the bare key (what the language says a map item is). The KEY still comes out of the
  # rendered item; since #52 the STATUS is read from sprint-status.yaml by that key, so
  # the status step is replayed with {entry_key}/{implementation_artifacts}, not {entry} —
  # which is precisely what makes the bare rendering yield 'backlog' instead of ''.
  replay $c key-pair    common/sync-issues.yaml "$lk"  entry="1-1-login-form: backlog"
  replay $c key-bare    common/sync-issues.yaml "$lk"  entry="1-1-login-form"
  local kp kb
  kp="$(head -1 "$d/key-pair.out")"; kb="$(head -1 "$d/key-bare.out")"
  replay $c status-pair common/sync-issues.yaml "$lst" implementation_artifacts="$work/ia" entry_key="$kp"
  replay $c status-bare common/sync-issues.yaml "$lst" implementation_artifacts="$work/ia" entry_key="$kb"
  local sp sb
  sp="$(head -1 "$d/status-pair.out")"; sb="$(head -1 "$d/status-bare.out")"
  # the derived key feeds the title step and the description file name
  replay $c title common/sync-issues.yaml "$lt" implementation_artifacts="$work/ia" entry_key="$kp"
  local title fname title_leak=0
  title="$(head -1 "$d/title.out")"
  # D15 is about the STATUS leaking into the title, not about which title is read (D21):
  # the assertion is that ': backlog' is absent, not that the title is the right one.
  case "$title" in *": $sp"*) title_leak=1;; esac
  fname="$(render "$(grep -o '/tmp/issue-desc-{entry[_a-z]*}\.md' "$WF/common/sync-issues.yaml" | head -1)" "entry=1-1-login-form: backlog" "entry_key=$kp")"
  # no step may still use {entry} as a key: the only survivors allowed are the two argv
  # lines of the split steps themselves (the line just above each STORE)
  local ka sa; ka="$(grep -n 'STORE: entry_key' "$WF/common/sync-issues.yaml" | cut -d: -f1)"; sa="$(grep -n 'STORE: entry_status' "$WF/common/sync-issues.yaml" | cut -d: -f1)"
  grep -n '{entry}' "$WF/common/sync-issues.yaml" | grep -v ':[[:space:]]*#' \
    | awk -F: -v k="$((ka-1))" -v s="$((sa-1))" '$1!=k && $1!=s' > "$d/raw-entry-uses.txt" || true
  local leaks; leaks="$(grep -c . "$d/raw-entry-uses.txt")"
  { echo "entry='1-1-login-form: backlog' → key='$kp' status='$sp' (read from $work/ia/sprint-status.yaml)"
    echo "entry='1-1-login-form'          → key='$kb' status='$sb' (same file, same key)"
    echo "title step  → '$title' (carries ': $sp'? $title_leak)"
    echo "description file → '$fname'"
    echo "steps still rendering {entry} as a key: $leaks"; cat "$d/raw-entry-uses.txt"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  if [ "$kp" = "1-1-login-form" ] && [ "$sp" = "backlog" ] && [ "$kb" = "1-1-login-form" ] && [ "$sb" = "backlog" ] \
     && [ "$title_leak" = 0 ] && [ "$fname" = "/tmp/issue-desc-1-1-login-form.md" ] && [ "$leaks" = 0 ]; then
    verdict $c REFUTED "sync-issues.yaml:$lk takes the KEY from the loop item under both renderings ('key: status' → '$kp', bare 'key' → '$kb') and sync-issues.yaml:$lst reads the STATUS from sprint-status.yaml by that key → '$sp' / '$sb' (#52: the bare rendering used to leave it empty, so the label was 'status{sep}' with nothing behind it). Downstream uses {entry_key}: the title step renders '$title' and the description file '$fname' — no ': $sp' in either, and $leaks step still uses {entry} as a key"
  else
    verdict $c CONFIRMED "the loop item still leaks: key='$kp' status='$sp' (bare: key='$kb' status='$sb', want 'backlog'); title='$title' carries ': $sp'? $title_leak; description file='$fname' (want '/tmp/issue-desc-1-1-login-form.md'); $leaks step(s) still render {entry} as a key: $(tr '\n' ' ' < "$d/raw-entry-uses.txt")"
  fi
}

case_d29() {  # #42 — the first dev-finish must gate on a CI it can actually see
  # Static (no lab, no API): the defect IS the order of the dev-finish INCLUDEs. With the
  # CI gate ahead of ensure-mr there is no PR on a story's first dev-finish, check-mr-ci
  # maps `no_mr`, write-ci-status writes green, and only then is the PR created — so
  # bmad-loop's first [verify] passes whatever CI did.
  local c=d29 d
  load_lab 2>/dev/null || true
  d="$(mkdir -p "$E2E_ROOT/evidence/${LAB_ID:-static}/d29" && echo "$E2E_ROOT/evidence/${LAB_ID:-static}/d29")"
  local f="$WF/common/post-dev-complete.yaml"
  local from to
  from="$(grep -n 'CHECK: phase eq "dev-finish"' "$f" | head -1 | cut -d: -f1)"
  to="$(grep -n 'CHECK: phase eq "review-finish"' "$f" | head -1 | cut -d: -f1)"
  if [ -z "$from" ] || [ -z "$to" ]; then
    verdict $c BLOCKED "cannot delimit the dev-finish phase in post-dev-complete.yaml (from='$from' to='$to')"; return
  fi
  sed -n "${from},$((to-1))p" "$f" | grep -oE '^[[:space:]]*- INCLUDE: common/[a-z-]+' | sed 's#.*common/##' > "$d/includes.txt"
  pos() { grep -nxF "$1" "$d/includes.txt" | head -1 | cut -d: -f1; }
  local p_issue p_mr p_ci p_write
  p_issue="$(pos ensure-issue)"; p_mr="$(pos ensure-mr)"; p_ci="$(pos wait-for-green-ci)"; p_write="$(pos write-ci-status)"
  # the `no_mr` -> green mapping must survive: it is the flow with no remote MR AT ALL
  grep -n 'ci_status eq "no_mr"' "$WF/common/write-ci-status.yaml" > "$d/no-mr-green.txt" || true
  { echo "dev-finish INCLUDE order: $(tr '\n' ' ' < "$d/includes.txt")"
    echo "ensure-issue=#${p_issue:-?} ensure-mr=#${p_mr:-?} wait-for-green-ci=#${p_ci:-?} write-ci-status=#${p_write:-?}"
    echo "write-ci-status still maps no_mr -> green: $(cat "$d/no-mr-green.txt")"; } > "$d/summary.txt"; cat "$d/summary.txt" >&2
  if [ -z "$p_issue" ] || [ -z "$p_mr" ] || [ -z "$p_ci" ] || [ -z "$p_write" ]; then
    verdict $c BLOCKED "the dev-finish phase does not include all four atomics: $(cat "$d/summary.txt" | head -2 | tr '\n' ' ')"
  elif [ "$p_ci" -lt "$p_mr" ]; then
    verdict $c CONFIRMED "post-dev-complete.yaml dev-finish gates on CI (#$p_ci) BEFORE it ensures the MR (#$p_mr): on a story's first dev-finish there is no PR, check-mr-ci maps no_mr, write-ci-status (#$p_write) writes green, and the PR is created afterwards. bmad-loop's first [verify] passes whatever CI did; a red pipeline is only seen on the next pass"
  elif [ "$p_issue" -lt "$p_mr" ] && [ "$p_mr" -lt "$p_ci" ] && [ "$p_ci" -lt "$p_write" ] && [ -s "$d/no-mr-green.txt" ]; then
    verdict $c REFUTED "post-dev-complete.yaml dev-finish ensures the issue (#$p_issue) and the MR (#$p_mr) BEFORE the CI gate (#$p_ci) and the ci-status.json write (#$p_write), so the FIRST dev-finish of a story is gated on a pipeline that exists. no_mr still maps to green ($(cat "$d/no-mr-green.txt")) — that is the flow with no remote MR at all, not a story whose MR had simply not been created yet"
  else
    verdict $c BLOCKED "neither shape: ensure-issue=#$p_issue ensure-mr=#$p_mr wait-for-green-ci=#$p_ci write-ci-status=#$p_write; no_mr mapping: $(cat "$d/no-mr-green.txt")"
  fi
}

# ============================================================================
main() {
  local what="${1:-}"
  case "$what" in
    static) case_static;;
    d17|d18|d2|d4|d7|d8|d15|d16|d19|d21|d24|d26|d9|d29|r1|r3|r7|g06|g10|gl-d23|gl-d16|gl-d4) "case_$what";;
    gitlab) for k in g06 gl-d23 gl-d16 gl-d4 gl-d2 gl-d18 d26 d03; do log "=== $k"; "case_$k"; done;;
    gl-d2|gl-d18|d03) "case_$what";;
    all) case_static; for k in d17 d7 d8 d16 d9 d15 d21 d29 d19 d2 d18 d4 d24 r1 r3 r7; do log "=== $k"; "case_$k"; done;;
    all-quick) case_static; for k in d17 d7 d8 d16 d9 d15 d21 d29; do log "=== $k"; "case_$k"; done;;
    *) sed -n 2,12p "$0"; exit 2;;
  esac
}
main "$@"
