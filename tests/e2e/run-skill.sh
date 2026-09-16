#!/usr/bin/env bash
# Real-BMM driver: run a BMM 6.12.0 skill headless in the consumer (its activation and
# on_complete customizations fire exactly as they would for a user), answering its
# questions from a fixed script.
#
#   run-skill.sh --case P1 --cwd <dir> --skill bmad-prd --answers "<how to answer prompts>" \
#                [--entry <workflow rel the hook will fire>] [--tag name] [--extra "<more instructions>"]
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"
CASE=""; CWD=""; SKILL=""; ANSWERS=""; ENTRY=""; TAG="run"; EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --case) CASE="$2"; shift 2;; --cwd) CWD="$2"; shift 2;; --skill) SKILL="$2"; shift 2;;
    --answers) ANSWERS="$2"; shift 2;; --entry) ENTRY="$2"; shift 2;; --tag) TAG="$2"; shift 2;; --extra) EXTRA="$2"; shift 2;;
    -h|--help) sed -n 2,9p "$0"; exit 0;; *) die "unknown arg $1";;
  esac
done
[ -n "$CASE" ] && [ -n "$CWD" ] && [ -n "$SKILL" ] || die "need --case, --cwd, --skill"
load_lab
D="$(case_dir "$CASE")/$TAG"; mkdir -p "$D"
{
  printf 'Invoke the skill `%s` now with the Skill tool (this is the same as the user typing /%s) and run it end to end in this project, without stopping to ask me anything.\n' "$SKILL" "$SKILL"
  printf 'Whenever the skill asks the user a question or shows a menu, decide with these answers: %s\n' "$ANSWERS"
  printf 'Follow the skill and its customization (activation steps and on_complete) exactly as written; do not skip the on_complete step.\n'
  [ -n "$EXTRA" ] && printf '%s\n' "$EXTRA"
  printf 'At the end, report which files you created or modified and anything that failed.\n'
} > "$D/prompt.txt"
log "[$CASE/$TAG] skill=$SKILL cwd=$CWD → $D/trace.jsonl"
start=$(date +%s)
rc="$(claude_headless "$CWD" "$D/trace.jsonl" "$D/prompt.txt")"
echo "$(( $(date +%s) - start ))" > "$D/wall-seconds.txt"
log "  claude rc=$rc wall=$(cat "$D/wall-seconds.txt")s"
if [ -n "$ENTRY" ]; then $TT analyze "$D/trace.jsonl" --entry "$ENTRY" --out "$D" | tee "$D/analyze.txt" >&2
else $TT analyze "$D/trace.jsonl" --out "$D" | tee "$D/analyze.txt" >&2; fi
snapshot "$CASE" "$TAG" "$CWD" >/dev/null
[ -s "$D/final.txt" ] && { log "  final message (tail):"; tail -c 800 "$D/final.txt" | sed 's/^/    | /' >&2; }
echo "$D"
