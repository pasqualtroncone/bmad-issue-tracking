#!/usr/bin/env bash
# Shared helpers for the e2e lab. Source, never execute.
#
#   E2E_ROOT   tests/e2e
#   MOD        repo root of bmad-issue-tracking (the module under test)
#   LAB_ROOT   /tmp/bmad-it-lab            (all labs; the plan pins /tmp on purpose)
#   LAB_ID     <YYYYMMDD>-<4hex>           (read from $LAB_ROOT/current unless E2E_LAB_ID is set)
#   LAB        $LAB_ROOT/$LAB_ID
#   CONSUMER   $LAB/consumer               (GitHub-tracked consumer project)
#   CONSUMER_GL $LAB/consumer-gitlab       (GitLab variant, optional)
#   REPO_GH    pasqualtroncone/bmad-it-lab-<id>
#   REPO_GL    pasqualtroncone/bmad-it-lab-<id> (gitlab.com)
#   EVIDENCE   tests/e2e/evidence/<lab-id>  (gitignored)
#
# Every case writes evidence/<lab-id>/<case>/ and ends with `verdict`.

set -o pipefail

E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$(cd "$E2E_ROOT/../.." && pwd)"
ASSETS="$MOD/skills/bmad-issue-tracking-setup/assets"
WF="$ASSETS/workflows"
LAB_ROOT="${E2E_LAB_ROOT:-/tmp/bmad-it-lab}"
GH_OWNER="${E2E_GH_OWNER:-pasqualtroncone}"
GL_OWNER="${E2E_GL_OWNER:-pasqualtroncone}"
BMM_VERSION="${E2E_BMM_VERSION:-6.12.0}"
PRD_KEY="labprd"

log()  { printf '\033[1;34m[e2e]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[e2e] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[e2e] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

# --- lab identity -----------------------------------------------------------
lab_id() {
  if [ -n "${E2E_LAB_ID:-}" ]; then echo "$E2E_LAB_ID"; return; fi
  [ -f "$LAB_ROOT/current" ] && cat "$LAB_ROOT/current"
}

load_lab() {
  LAB_ID="$(lab_id)"
  [ -n "$LAB_ID" ] || die "no lab: run tests/e2e/lab-up.sh first (or set E2E_LAB_ID)"
  LAB="$LAB_ROOT/$LAB_ID"
  [ -f "$LAB/lab.env" ] || die "lab $LAB_ID has no lab.env ($LAB)"
  # shellcheck disable=SC1090
  . "$LAB/lab.env"
  CONSUMER="$LAB/consumer"
  CONSUMER_GL="$LAB/consumer-gitlab"
  EVIDENCE="$E2E_ROOT/evidence/$LAB_ID"
  mkdir -p "$EVIDENCE"
}

# --- evidence ---------------------------------------------------------------
# case_dir <case> → prints (and creates) evidence/<lab>/<case>
case_dir() { local d="$EVIDENCE/$1"; mkdir -p "$d"; echo "$d"; }

# verdict <case> <CONFIRMED|REFUTED|MASKED-BY x|LATENT|BLOCKED|OBSERVED> <one-line reason>
verdict() {
  local c="$1" v="$2"; shift 2
  local d; d="$(case_dir "$c")"
  printf '%s\t%s\t%s\n' "$v" "$(date -u +%FT%TZ)" "$*" > "$d/verdict.txt"
  printf '\033[1;32m[%s]\033[0m %s — %s\n' "$c" "$v" "$*" >&2
}

# run_ev <case> <name> <cmd...> — run a command, save stdout/stderr/rc as evidence, echo rc
run_ev() {
  local c="$1" n="$2"; shift 2
  local d; d="$(case_dir "$c")"
  local rc=0
  "$@" >"$d/$n.out" 2>"$d/$n.err" || rc=$?
  echo "$rc" > "$d/$n.rc"
  printf '    $ %s\n      rc=%s stdout=%sB stderr=%sB\n' "$*" "$rc" "$(wc -c <"$d/$n.out")" "$(wc -c <"$d/$n.err")" >&2
  return 0
}

# snapshot <case> <name> [worktree] — git + tracker state after a run
snapshot() {
  local c="$1" n="$2" wt="${3:-$CONSUMER}"
  local d; d="$(case_dir "$c")/snap-$n"; mkdir -p "$d"
  ( cd "$wt" 2>/dev/null && {
      git log --oneline --decorate -n 15 > "$d/git-log.txt" 2>&1
      git branch --show-current > "$d/branch.txt" 2>&1
      git rev-parse --abbrev-ref --symbolic-full-name '@{u}' > "$d/upstream.txt" 2>&1 || true
      git status --short > "$d/git-status.txt" 2>&1
      git worktree list > "$d/worktrees.txt" 2>&1
      cp ci-status.json "$d/ci-status.json" 2>/dev/null || echo "(absent)" > "$d/ci-status.json.absent"
    } )
  if [ -n "${REPO_GH:-}" ]; then
    gh run list -R "$REPO_GH" --limit 10 --json databaseId,headBranch,status,conclusion,createdAt,event > "$d/gh-runs.json" 2>&1 || true
    gh issue list -R "$REPO_GH" --state all --limit 100 --json number,title,state,labels,createdAt > "$d/gh-issues.json" 2>&1 || true
    gh pr list -R "$REPO_GH" --state all --limit 50 --json number,title,state,isDraft,headRefName,baseRefName,body > "$d/gh-prs.json" 2>&1 || true
  fi
  ls -la /tmp/issue-desc*.md /tmp/ensure-mr*.md /tmp/prd-desc.md /tmp/review-findings.md /tmp/dev-story-comment.md > "$d/tmp-leftovers.txt" 2>/dev/null || echo "(none)" > "$d/tmp-leftovers.txt"
  echo "$d"
}

# --- GitHub Actions helpers -------------------------------------------------
# wait_run <branch> [timeout_s] — wait until the latest run on <branch> is completed; prints conclusion
wait_run() {
  local branch="$1" timeout="${2:-600}" t=0 json status conc
  while :; do
    json="$(gh run list -R "$REPO_GH" --branch "$branch" --limit 1 --json status,conclusion,databaseId,createdAt 2>/dev/null)"
    status="$(printf '%s' "$json" | uv run --no-project python -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["status"] if r else "")')"
    conc="$(printf '%s' "$json" | uv run --no-project python -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["conclusion"] if r else "")')"
    if [ "$status" = "completed" ]; then echo "$conc"; return 0; fi
    [ "$t" -ge "$timeout" ] && { echo "timeout"; return 1; }
    sleep 10; t=$((t+10))
  done
}

# set_outcome <worktree> <pass|fail|sleep:N> — write ci/outcome and commit
set_outcome() {
  local wt="$1" o="$2"
  ( cd "$wt" && mkdir -p ci && printf '%s\n' "$o" > ci/outcome && git add ci/outcome && git commit -q -m "ci: outcome $o" ) || true
}

# --- placeholder rendering ---------------------------------------------------
# render <string> key=value... — substitute {key} the way the workflow runtime does
render() {
  local s="$1"; shift
  local kv
  for kv in "$@"; do
    s="${s//\{${kv%%=*}\}/${kv#*=}}"
  done
  printf '%s' "$s"
}

# yaml_lines <rel> <from> <to> — print lines of a workflow file
yaml_lines() { sed -n "${2},${3}p" "$WF/$1"; }

# --- claude headless ----------------------------------------------------------
CLAUDE_ALLOWED="${E2E_CLAUDE_ALLOWED:-Read,Glob,Grep,Write,Edit,Bash}"
CLAUDE_DISALLOWED="${E2E_CLAUDE_DISALLOWED:-Bash(rm -rf:*),Bash(git push --force:*),Bash(git push -f:*),Bash(gh repo delete:*),Bash(glab repo delete:*),Bash(git reset --hard:*),Bash(git clean:*)}"
CLAUDE_MAX_TURNS="${E2E_CLAUDE_MAX_TURNS:-250}"
CLAUDE_TIMEOUT="${E2E_CLAUDE_TIMEOUT:-1500}"

# claude_headless <cwd> <trace.jsonl> <prompt> [extra claude args...]
claude_headless() {
  local cwd="$1" trace="$2" prompt="$3"; shift 3
  local strict_args=()
  if [ -n "${E2E_STRICT_ALLOW:-}" ]; then strict_args=(--allowedTools "$E2E_STRICT_ALLOW"); else strict_args=(--allowedTools "$CLAUDE_ALLOWED"); fi
  ( cd "$cwd" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT ${E2E_CLAUDE_ENV:-} \
      timeout "$CLAUDE_TIMEOUT" claude -p --output-format stream-json --verbose \
        --max-turns "$CLAUDE_MAX_TURNS" --permission-mode acceptEdits \
        "${strict_args[@]}" --disallowedTools "$CLAUDE_DISALLOWED" "$@" \
        "$prompt" > "$trace" 2> "${trace%.jsonl}.stderr" )
  echo $? > "${trace%.jsonl}.rc"
  cat "${trace%.jsonl}.rc"
}

# python with conftest's deps, and the trace-tools entry point
PY="uv run --no-project --with pytest --with pyyaml python"
TT="$PY $E2E_ROOT/trace-tools.py"

# --- scenario helpers (level 2) ---------------------------------------------
# story_worktree <story_key> [branch] [--no-upstream] → prints the worktree path
#   Creates $CONSUMER/_bmad/worktrees/<branch> on <branch> (default feat/labprd/<key>) from
#   origin/feat/labprd/prd, like create-story/activation.yaml does, and pushes it with -u
#   (what the create-story phase would have done) unless --no-upstream (bmad-loop shape).
story_worktree() {
  local key="$1" branch="${2:-feat/$PRD_KEY/$1}" up=1
  [ "${3:-}" = "--no-upstream" ] && up=0
  local wt="$CONSUMER/_bmad/worktrees/$branch"
  ( cd "$CONSUMER" && git fetch -q origin && {
      # create-story/activation.yaml: `git worktree add … -b {story_branch} {prd_branch}` from the LOCAL
      # prd branch → no tracking; the create-story phase then does `git push -u`. --no-track keeps that shape.
      [ -d "$wt" ] || { git branch -D "$branch" >/dev/null 2>&1; git worktree add -q --no-track "$wt" -b "$branch" "origin/feat/$PRD_KEY/prd" >/dev/null; }
      if [ "$up" = 1 ]; then ( cd "$wt" && git push -q -u origin "$branch" ); fi
  } ) || die "story_worktree $key failed"
  echo "$wt"
}

# prd_worktree → prints $CONSUMER/_bmad/worktrees/prd on feat/labprd/prd (bmad-prd/activation shape)
prd_worktree() {
  local wt="$CONSUMER/_bmad/worktrees/prd"
  ( cd "$CONSUMER" && git fetch -q origin && { [ -d "$wt" ] || git worktree add -q "$wt" "feat/$PRD_KEY/prd" 2>/dev/null || git worktree add -q "$wt" -b "feat/$PRD_KEY/prd" "origin/feat/$PRD_KEY/prd"; } ) || die "prd_worktree failed"
  ( cd "$wt" && git branch -q --set-upstream-to "origin/feat/$PRD_KEY/prd" >/dev/null 2>&1; git pull -q --ff-only >/dev/null 2>&1 ) || true
  echo "$wt"
}

# write_spec <worktree> <status> <rows|none|legacy> — render the 6.12.0-shaped spec (or the
# legacy H1 variant) into {implementation_artifacts}/spec-1-1-login-form.md and commit it
write_spec() {
  local wt="$1" status="$2" mode="$3" f="$1/$IMPLEMENTATION/spec-1-1-login-form.md"
  mkdir -p "$(dirname "$f")"
  case "$mode" in
    legacy) sed "s/^status: .*/status: '$status'/" "$E2E_ROOT/fixtures/consumer/implementation-artifacts/spec-1-1-login-form.legacy-h1.md" > "$f";;
    rows)   uv run --no-project python - "$E2E_ROOT/fixtures/consumer/implementation-artifacts/spec-1-1-login-form.md.tmpl" "$E2E_ROOT/fixtures/triage-rows.md" "$status" > "$f" <<'PY'
import sys; t=open(sys.argv[1]).read(); rows=open(sys.argv[2]).read().rstrip()
print(t.replace('@STATUS@', sys.argv[3]).replace('@TRIAGE_ROWS@', rows), end='')
PY
;;
    none)   sed -e "s/@STATUS@/$status/" -e '/@TRIAGE_ROWS@/d' "$E2E_ROOT/fixtures/consumer/implementation-artifacts/spec-1-1-login-form.md.tmpl" > "$f";;
    *) die "write_spec mode $mode";;
  esac
  ( cd "$wt" && git add "$IMPLEMENTATION/spec-1-1-login-form.md" && git commit -q -m "spec 1-1 status=$status triage=$mode" ) || true
  echo "$IMPLEMENTATION/spec-1-1-login-form.md"
}

# set_story_status <worktree> <story_key> <status> — edit sprint-status.yaml and commit
set_story_status() {
  local wt="$1" key="$2" st="$3" f="$1/$IMPLEMENTATION/sprint-status.yaml"
  sed -i -E "s/^(  $key): .*/\1: $st/" "$f"
  ( cd "$wt" && git add "$IMPLEMENTATION/sprint-status.yaml" && git commit -q -m "sprint-status: $key=$st" ) || true
}

# touch_src <worktree> <msg> — make the push carry a diff
touch_src() { ( cd "$1" && printf '\n# %s\n' "$2" >> src/login.py && git add src/login.py && git commit -q -m "$2" ) || true; }

# issue_titles [label] — "#n<TAB>title<TAB>state<TAB>labels" for the lab repo
issue_titles() {
  gh issue list -R "$REPO_GH" --state all --limit 200 ${1:+--label "$1"} --json number,title,state,labels \
    --jq '.[] | "#\(.number)\t\(.title)\t\(.state)\t\([.labels[].name] | join(","))"'
}
