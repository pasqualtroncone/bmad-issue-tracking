#!/usr/bin/env bash
# Create the e2e lab: disposable GitHub (and optionally GitLab) repo + a local consumer
# project with BMM 6.12.0 (classic installer), this module deployed, and the fixtures.
#
#   lab-up.sh [--platform github|gitlab|both] [--via-skill] [--id <lab-id>]
#   lab-up.sh --check          # verify BMM will fire the module's on_complete hooks
#
# Deploy is deterministic by default (the literal mkdir/cp of SKILL.md steps 2-3 plus a
# direct write of _bmad/custom/issue-tracking.yaml). --via-skill runs the real
# /bmad-issue-tracking-setup skill headless instead (claude -p, allowlisted commands).
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

PLATFORM=github; VIA_SKILL=0; CHECK=0; ID=""; ADD_GL=0; REDEPLOY=0; GL_HOST="${E2E_GL_HOST:-gitlab.com}"
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift 2;;
    --via-skill) VIA_SKILL=1; shift;;
    --check) CHECK=1; shift;;
    --id) ID="$2"; shift 2;;
    --gl-host) GL_HOST="$2"; shift 2;;
    --add-gitlab) ADD_GL=1; shift;;   # add a GitLab consumer to the CURRENT lab (self-hosted host via --gl-host)
    --redeploy) REDEPLOY=1; shift;;   # copy THIS checkout's assets into every consumer of the current lab (level 2 reads the deployed copies)
    -h|--help) sed -n 2,12p "$0"; exit 0;;
    *) die "unknown arg $1";;
  esac
done

need gh; need git; need uv; need npx

# ---------------------------------------------------------------------------
check_lab() {
  load_lab
  local rc=0
  log "check: BMM $BMM_VERSION resolves the module's on_complete for each hooked skill"
  local skill hook want
  for pair in \
      "bmad-build-auto:post-build-dispatch-auto.yaml" \
      "bmad-build:post-build-dispatch-interactive.yaml" \
      "bmad-sprint-planning:sprint-planning/complete.yaml" \
      "bmad-prd:bmad-prd/complete.yaml" \
      "bmad-create-prd:create-prd/complete.yaml" \
      "bmad-create-epics-and-stories:create-epics-and-stories/complete.yaml" \
      "bmad-code-review:post-dev-complete-review-finish.yaml"; do
    skill="${pair%%:*}"; want="${pair#*:}"
    local sdir="$CONSUMER/.claude/skills/$skill"
    if [ ! -d "$sdir" ]; then warn "  $skill: skill dir missing ($sdir)"; rc=1; continue; fi
    hook="$(cd "$CONSUMER" && uv run --no-project python _bmad/scripts/resolve_customization.py --skill "$sdir" --project-root "$CONSUMER" --key workflow.on_complete 2>&1 || true)"
    if printf '%s' "$hook" | grep -q "$want"; then
      log "  $skill → $want  OK"
    else
      warn "  $skill: on_complete does NOT point at $want. Got: $(printf '%s' "$hook" | head -c 200)"; rc=1
    fi
  done
  log "check: consumer tracked files the hooks read"
  for f in _bmad/custom/issue-tracking.yaml _bmad/custom/bmad-build-auto.toml _bmad/_config/custom/bmad-workflow-lang.md _bmad/_config/custom/workflows/common/post-dev-complete.yaml _bmad-output/planning-artifacts/prd.md _bmad-output/implementation-artifacts/sprint-status.yaml; do
    if (cd "$CONSUMER" && git ls-files --error-unmatch "$f" >/dev/null 2>&1); then log "  tracked: $f"; else warn "  NOT tracked: $f"; rc=1; fi
  done
  log "check: git pins"
  (cd "$CONSUMER" && git config --get push.autoSetupRemote; git config --get push.default) | sed 's/^/  /' >&2
  log "check: remotes / repos"
  (cd "$CONSUMER" && git remote -v) | sed 's/^/  /' >&2
  gh repo view "$REPO_GH" --json name,visibility,defaultBranchRef --jq '"  gh: " + .name + " " + .visibility + " default=" + .defaultBranchRef.name' >&2
  return $rc
}

if [ "$CHECK" = 1 ]; then check_lab; exit $?; fi

# --redeploy: SKILL.md steps 2-3 again, from this checkout, committed on main and fast-forwarded
# into the PRD branch (story worktrees are cut from it and carry tracked files only).
if [ "$REDEPLOY" = 1 ]; then
  load_lab
  for c in "$LAB"/consumer*; do
    [ -d "$c" ] || continue
    log "redeploying module assets into $c"
    # replay cases leave local commits on main (d7); the remote is the truth, so start from it
    ( cd "$c" && git fetch -q origin && git checkout -q main && git reset -q --hard origin/main
      mkdir -p _bmad/custom _bmad/_config/custom/workflows
      rm -f _bmad/custom/bmad-*.toml; cp -f "$ASSETS"/custom/*.toml _bmad/custom/
      rm -rf _bmad/_config/custom/workflows/*; cp -rf "$ASSETS"/workflows/* _bmad/_config/custom/workflows/
      cp -f "$ASSETS"/bmad-workflow-lang.md _bmad/_config/custom/
      # the skill folders too, so resolve_customization/help see the same version
      for sk in bmad-issue-tracking-setup bmad-issue-tracking-sync; do rm -rf ".claude/skills/$sk"; cp -r "$MOD/skills/$sk" ".claude/skills/$sk"; done
      git add -A _bmad/custom _bmad/_config/custom .claude/skills
      git commit -q -m "chore: redeploy bmad-issue-tracking from $(git -C "$MOD" rev-parse --short HEAD)" || log "  (nothing changed)"
      git push -q origin main
      git fetch -q origin
      # The PRD branch is usually CHECKED OUT in _bmad/worktrees/prd, and `git branch -f`
      # refuses to move a branch a worktree holds ("cannot force update the branch ...
      # checked out at ..."). The `|| true` that used to swallow that error left the PRD
      # branch — the one every level-2 scenario runs in — on the PREVIOUS assets while
      # main carried the new ones, so a redeploy printed main=<new> prd=<old> and the
      # scenario exercised the code the redeploy was meant to replace. Reset inside the
      # worktree when there is one; on the other path a failure is FATAL, because the
      # push below would otherwise force the stale branch back onto the remote.
      prd_wt="$(git worktree list --porcelain | awk -v b="refs/heads/feat/$PRD_KEY/prd" '/^worktree /{w=$2} $1=="branch" && $2==b {print w}')"
      if [ -n "$prd_wt" ]; then git -C "$prd_wt" reset -q --hard origin/main
      else git branch -f "feat/$PRD_KEY/prd" origin/main || die "cannot move feat/$PRD_KEY/prd to origin/main in $c (detached worktree? locked ref?) — refusing to force-push the stale branch"; fi
      git push -q -f origin "feat/$PRD_KEY/prd:feat/$PRD_KEY/prd"
      # STORY worktrees were cut BEFORE this redeploy and carry their own commits, so
      # neither the reset above nor a branch move reaches them: a level-2 scenario running
      # in one of them executes the PREVIOUS assets while main and the PRD branch carry the
      # new ones, and the improvisation report then blames the agent for commands the
      # deployed files really do contain. The assets are copied in and committed on the
      # story branch, which is what the consumer does with everything else anyway.
      for wt in $(git worktree list --porcelain | awk '/^worktree /{print $2}'); do
        [ "$wt" = "$PWD" ] && continue
        [ "$wt" = "${prd_wt:-}" ] && continue
        [ -d "$wt/_bmad/_config/custom" ] || continue
        rm -f "$wt"/_bmad/custom/bmad-*.toml; cp -f "$ASSETS"/custom/*.toml "$wt"/_bmad/custom/
        rm -rf "$wt"/_bmad/_config/custom/workflows/*; cp -rf "$ASSETS"/workflows/* "$wt"/_bmad/_config/custom/workflows/
        cp -f "$ASSETS"/bmad-workflow-lang.md "$wt"/_bmad/_config/custom/
        git -C "$wt" add -A _bmad/custom _bmad/_config/custom
        git -C "$wt" commit -q -m "chore: redeploy bmad-issue-tracking from $(git -C "$MOD" rev-parse --short HEAD)" \
          && echo "  worktree $(basename "$wt")=$(git -C "$wt" rev-parse --short HEAD)" || echo "  worktree $(basename "$wt") already current"
      done
      # The redeploy only counts if the PRD branch carries what main carries: the
      # scenarios run in it, and a level-2 verdict taken on the previous assets reads as an
      # agent that improvised. Checked, not just printed.
      git fetch -q origin
      main_sha="$(git rev-parse origin/main)"
      prd_sha="$(git rev-parse "origin/feat/$PRD_KEY/prd")"
      [ "$main_sha" = "$prd_sha" ] || die "redeploy left $c with main=${main_sha:0:7} but feat/$PRD_KEY/prd=${prd_sha:0:7} — every A*/P* scenario runs in the PRD branch and would exercise the PREVIOUS assets"
      echo "  main=$(git rev-parse --short origin/main) prd=$(git rev-parse --short origin/feat/$PRD_KEY/prd)" )
  done
  exit 0
fi
export GITLAB_HOST="$GL_HOST"   # glab repo create / glab api pick the host from here

if [ "$ADD_GL" = 1 ]; then
  load_lab; need glab
  glab auth status --hostname "$GL_HOST" >/dev/null 2>&1 || die "glab is not authenticated on $GL_HOST"
  # the GitLab username is the namespace (it can differ from the GitHub login: pasqual.troncone vs pasqualtroncone)
  [ -n "${E2E_GL_OWNER:-}" ] || GL_OWNER="$(glab api user --hostname "$GL_HOST" 2>/dev/null | uv run --no-project python -c 'import json,sys; print(json.load(sys.stdin)["username"])')"
  REPO_NAME="bmad-it-lab-$LAB_ID"; REPO_GL="$GL_OWNER/$REPO_NAME"; ID="$LAB_ID"
  [ -d "$LAB/consumer-gitlab" ] && die "consumer-gitlab already exists in $LAB"
  log "creating private GitLab project $GL_HOST/$REPO_GL"
  glab repo create "$REPO_GL" --private --description "bmad-issue-tracking e2e lab $ID (disposable)" >/dev/null
  { echo "REPO_GL=$REPO_GL"; echo "GL_HOST=$GL_HOST"; } >> "$LAB/lab.env"
  PLATFORM=gitlab-add
fi

# ---------------------------------------------------------------------------
if [ "$ADD_GL" = 0 ]; then
[ -n "$ID" ] || ID="$(date +%Y%m%d)-$(head -c 2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
LAB="$LAB_ROOT/$ID"; CONSUMER="$LAB/consumer"
[ -e "$LAB" ] && die "lab $LAB already exists; run lab-down.sh first or pick another --id"
mkdir -p "$LAB"; echo "$ID" > "$LAB_ROOT/current"
REPO_NAME="bmad-it-lab-$ID"
REPO_GH="$GH_OWNER/$REPO_NAME"; REPO_GL="$GL_OWNER/$REPO_NAME"
log "lab id: $ID  ($LAB)"

{
  echo "LAB_ID=$ID"
  echo "PLATFORM=$PLATFORM"
  case "$PLATFORM" in github|both) echo "REPO_GH=$REPO_GH";; esac
  case "$PLATFORM" in gitlab|both) echo "REPO_GL=$REPO_GL"; echo "GL_HOST=$GL_HOST";; esac
  echo "CREATED=$(date -u +%FT%TZ)"
} > "$LAB/lab.env"
fi

# --- 1. remote repos ---------------------------------------------------------
case "$PLATFORM" in
  github|both)
    log "creating private GitHub repo $REPO_GH"
    gh repo create "$REPO_GH" --private --description "bmad-issue-tracking e2e lab $ID (disposable)" >/dev/null
    ;;
esac
case "$PLATFORM" in
  gitlab|both)
    need glab
    glab auth status --hostname "$GL_HOST" >/dev/null 2>&1 || die "glab is not authenticated on $GL_HOST: run  ! glab auth login --hostname $GL_HOST  (scopes api + write_repository)"
    log "creating private GitLab project $GL_HOST/$REPO_GL"
    glab repo create "$REPO_GL" --private --description "bmad-issue-tracking e2e lab $ID (disposable)" >/dev/null
    ;;
esac

# --- 2. consumer skeleton ----------------------------------------------------
build_consumer() {  # build_consumer <dir> <platform> <remote-url> <host> <project>
  local dir="$1" plat="$2" remote="$3" host="$4" project="$5"
  mkdir -p "$dir"; cd "$dir"
  git init -q -b main
  git config push.autoSetupRemote false
  git config push.default simple
  git config user.name  "${GIT_AUTHOR_NAME:-$(git config --global user.name || echo e2e)}"
  git config user.email "${GIT_AUTHOR_EMAIL:-$(git config --global user.email || echo e2e@example.invalid)}"
  git remote add origin "$remote"
  if [ "$plat" = github ]; then mkdir -p .github/workflows && cp "$E2E_ROOT/fixtures/ci.yml" .github/workflows/ci.yml
  else cp "$E2E_ROOT/fixtures/.gitlab-ci.yml" .gitlab-ci.yml; fi
  mkdir -p ci && echo pass > ci/outcome
  printf '# bmad-it-lab %s (%s)\n\nDisposable consumer project for the bmad-issue-tracking e2e lab.\n' "$ID" "$plat" > README.md
  git add -A && git commit -q -m "chore: lab skeleton (ci on push, outcome=pass)"

  # --- 3. BMM 6.12.0 via the classic installer, module from this checkout ---
  log "installing bmad-method@$BMM_VERSION (bmm + this module) into $dir — takes a few minutes"
  timeout 600 npx -y "bmad-method@$BMM_VERSION" install --directory "$dir" --modules bmm \
      --custom-source "$MOD" --tools claude-code --yes > "$LAB/install-$plat.log" 2>&1 \
    || { tail -30 "$LAB/install-$plat.log" >&2; die "bmad-method install failed (see $LAB/install-$plat.log)"; }
  grep -E 'Custom module|warn|Error' "$LAB/install-$plat.log" | head -5 >&2 || true
  [ -d .claude/skills/bmad-issue-tracking-setup/assets/custom ] || die "module skills not installed under .claude/skills"

  # --- 4. deploy the module (SKILL.md steps 2-3, literally; step 6/7/9 as a file) ---
  if [ "$VIA_SKILL" = 1 ]; then
    log "deploying via the real /bmad-issue-tracking-setup skill (claude -p)"
    local prompt="Run the /bmad-issue-tracking-setup skill now, end to end, without stopping to ask me anything. Whenever a step asks the user a question, use these answers: worktree base directory = the default (_bmad/worktrees); issue tracking platform = $( [ "$plat" = github ] && echo GitHub || echo GitLab ); issue tracker host = $host; issue tracker project = $project; PRD branch pattern = default; story branch pattern = default. At the end print a report of every file you created or modified and anything you skipped."
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT timeout 900 claude -p --permission-mode acceptEdits \
      --allowedTools "Read,Write,Edit,Glob,Grep,Bash(mkdir:*),Bash(cp:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(grep:*),Bash(find:*),Bash(test:*),Bash(chmod:*),Bash(git remote:*),Bash(git rm --cached:*),Bash(git check-ignore:*),Bash(gh auth status:*),Bash(glab auth status:*),Bash(uv --version:*),Bash(uv run:*),Bash(diff:*),Bash(echo:*),Bash(rm -f _bmad/custom/*.toml)" \
      --output-format text "$prompt" > "$LAB/setup-skill-$plat.log" 2>&1 || warn "setup skill exited non-zero (see $LAB/setup-skill-$plat.log)"
  else
    local path=".claude/skills/bmad-issue-tracking-setup/assets"
    mkdir -p _bmad/custom
    cp -f "$path"/custom/*.toml _bmad/custom/
    mkdir -p _bmad/_config/custom/workflows
    cp -f "$path"/bmad-workflow-lang.md _bmad/_config/custom/
    cp -rf "$path"/workflows/* _bmad/_config/custom/workflows/
  fi
  # the config file is written directly in both modes (deterministic values; --via-skill
  # answers the prompts with the same values, so this only normalises formatting)
  local cross=""
  sed -e "s|@PLATFORM@|$plat|" -e "s|@GIT_PLATFORM@|$plat|" -e "s|@HOST@|$host|" -e "s|@PROJECT@|$project|" -e "s|@CROSS@|$cross|" \
      "$E2E_ROOT/fixtures/issue-tracking.yaml.tmpl" | sed '/^$/d' > _bmad/custom/issue-tracking.yaml
  grep -qxF '_bmad/worktrees' .gitignore 2>/dev/null || echo '_bmad/worktrees' >> .gitignore

  # --- 5. fixtures in the paths bmm/config.yaml declares ---
  local pa ia
  pa="$(grep -E '^planning_artifacts:' _bmad/bmm/config.yaml | sed -E 's/.*"\{project-root\}\/(.*)"/\1/')"
  ia="$(grep -E '^implementation_artifacts:' _bmad/bmm/config.yaml | sed -E 's/.*"\{project-root\}\/(.*)"/\1/')"
  [ -n "$pa" ] && [ -n "$ia" ] || die "could not read artifact paths from _bmad/bmm/config.yaml"
  echo "PLANNING=$pa" >> "$LAB/lab.env"; echo "IMPLEMENTATION=$ia" >> "$LAB/lab.env"
  mkdir -p "$pa" "$ia" src
  cp "$E2E_ROOT"/fixtures/consumer/planning-artifacts/*.md "$pa/"
  sed 's/@S11@/backlog/' "$E2E_ROOT/fixtures/consumer/implementation-artifacts/sprint-status.yaml" > "$ia/sprint-status.yaml"
  cp "$E2E_ROOT/fixtures/consumer/src/login.py" src/login.py

  # --- 6. nothing the hooks need may be gitignored (worktrees carry tracked files only) ---
  local bad=0 f
  for f in _bmad/custom/issue-tracking.yaml _bmad/custom/bmad-build-auto.toml _bmad/_config/custom/bmad-workflow-lang.md \
           _bmad/_config/custom/workflows/common/post-dev-complete.yaml .claude/skills/bmad-build-auto/SKILL.md \
           "$pa/prd.md" "$ia/sprint-status.yaml" _bmad/scripts/resolve_customization.py; do
    if git check-ignore -v "$f" >/dev/null 2>&1; then warn "gitignored but needed in worktrees: $f ($(git check-ignore -v "$f"))"; bad=1; fi
  done
  [ "$bad" = 0 ] || die "fix the consumer .gitignore before continuing"

  git add -A && git commit -q -m "chore: BMM $BMM_VERSION + bmad-issue-tracking deployed + lab fixtures"
  log "pushing main"
  git push -q -u origin main
  # PRD branch: the story worktrees branch from it (module: feat/{prd_key}/prd)
  git branch "feat/$PRD_KEY/prd" main
  git push -q origin "feat/$PRD_KEY/prd"
  cd "$LAB"
}

case "$PLATFORM" in
  github|both) build_consumer "$CONSUMER" github "git@github.com:$REPO_GH.git" github.com "$REPO_GH";;
esac
case "$PLATFORM" in
  gitlab|both|gitlab-add) build_consumer "$LAB/consumer-gitlab" gitlab "git@$GL_HOST:$REPO_GL.git" "$GL_HOST" "$REPO_GL";;
esac

log "lab ready: $LAB"
log "  consumer(s): $(ls -d "$LAB"/consumer* | tr '\n' ' ')"
log "  next: tests/e2e/lab-up.sh --check ; tests/e2e/replay.sh static ; tests/e2e/replay.sh all"
