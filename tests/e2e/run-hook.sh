#!/usr/bin/env bash
# Level 2 driver: execute a module on_complete hook the way BMM would — the TOML text,
# verbatim, given to a headless Claude in the story/PRD worktree, with only the variables
# the skill run would have left in scope prepended.
#
#   run-hook.sh --case A1 --worktree <dir> --toml bmad-build-auto \
#               --var spec_file=_bmad-output/implementation-artifacts/spec-1-1-login-form.md \
#               [--var k=v ...] [--entry common/post-build-dispatch-auto.yaml] \
#               [--answer "<policy for OUTPUT questions>"] [--strict "<allowlist>"] [--tag name]
#
# Produces evidence/<lab>/<case>/<tag>/{trace.jsonl,commands.txt,files.txt,result.json,
# final.txt,improvisation.txt,coverage.txt} + a snapshot. Bash is deliberately broad
# (a narrow allowlist would make a denied command look like a defect); the blast radius
# is the disposable repo + /tmp. --strict runs with a closed list to document what the
# hook actually needs.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

CASE=""; WT=""; TOML=""; TEXT=""; ENTRY=""; ANSWER=""; TAG="run"; VARS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --case) CASE="$2"; shift 2;; --worktree) WT="$2"; shift 2;; --toml) TOML="$2"; shift 2;; --text) TEXT="$2"; shift 2;;
    --var) VARS+=("$2"); shift 2;; --entry) ENTRY="$2"; shift 2;; --answer) ANSWER="$2"; shift 2;;
    --strict) export E2E_STRICT_ALLOW="$2"; shift 2;; --tag) TAG="$2"; shift 2;;
    -h|--help) sed -n 2,16p "$0"; exit 0;; *) die "unknown arg $1";;
  esac
done
[ -n "$CASE" ] && [ -n "$WT" ] && { [ -n "$TOML" ] || [ -n "$TEXT" ]; } || die "need --case, --worktree, and --toml <name> or --text <instruction>"
load_lab
[ -d "$WT" ] || die "worktree not found: $WT"
if [ -n "$TOML" ]; then
  TOML_FILE="$WT/_bmad/custom/$TOML.toml"
  [ -f "$TOML_FILE" ] || die "deployed TOML not found in worktree: $TOML_FILE"
  HOOK="$(uv run --no-project python -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["workflow"]["on_complete"].strip())' "$TOML_FILE")"
  [ -n "$HOOK" ] || die "$TOML_FILE has an empty on_complete"
else
  HOOK="$TEXT"; TOML="(instruction)"
fi
[ -n "$ENTRY" ] || ENTRY="$(printf '%s' "$HOOK" | grep -oE 'workflows/[A-Za-z0-9_./-]+\.yaml' | head -1 | sed 's|^workflows/||')"

D="$(case_dir "$CASE")/$TAG"; mkdir -p "$D"
SKILL="${TOML#bmad-}"
{
  if [ "$TOML" = "(instruction)" ]; then
    printf 'You are running a bmad-issue-tracking workflow in this project (cwd: %s). The instruction follows verbatim.\n' "$WT"
  else
    printf 'You are finishing a run of the BMM skill `%s` in this project (cwd: %s). The skill reached its final step and must now run its `on_complete` customization, which follows verbatim.\n' "$TOML" "$WT"
  fi
  if [ ${#VARS[@]} -gt 0 ]; then
    printf '\nThese variables from the skill run are already in scope for the workflow language:\n'
    for v in "${VARS[@]}"; do printf '  %s = "%s"\n' "${v%%=*}" "${v#*=}"; done
  fi
  printf '\nBMM config: planning_artifacts = %s, implementation_artifacts = %s, project-root = %s.\n' "$PLANNING" "$IMPLEMENTATION" "$WT"
  [ -n "$ANSWER" ] && printf '\nIf a workflow OUTPUT step asks the user a question: %s\n' "$ANSWER"
  printf '\n--- execute exactly this ---\n%s\n' "$HOOK"
} > "$D/prompt.txt"

log "[$CASE/$TAG] hook=$TOML entry=$ENTRY worktree=$WT"
log "  claude -p … (max-turns $CLAUDE_MAX_TURNS, timeout ${CLAUDE_TIMEOUT}s) → $D/trace.jsonl"
start=$(date +%s)
rc="$(claude_headless "$WT" "$D/trace.jsonl" "$D/prompt.txt")"
echo "$(( $(date +%s) - start ))" > "$D/wall-seconds.txt"
log "  claude rc=$rc wall=$(cat "$D/wall-seconds.txt")s"
$TT analyze "$D/trace.jsonl" --entry "$ENTRY" --out "$D" | tee "$D/analyze.txt" >&2
snapshot "$CASE" "$TAG" "$WT" >/dev/null
[ -s "$D/final.txt" ] && { log "  final message (tail):"; tail -c 600 "$D/final.txt" | sed 's/^/    | /' >&2; }
echo "$D"
