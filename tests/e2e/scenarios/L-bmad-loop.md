# Level 3 — bmad-loop 0.11.1 against the lab (run by hand)

bmad-loop starts `claude --permission-mode bypassPermissions` inside tmux; from a Claude Code
session that launch can be blocked, and the consumer must be trusted once interactively. So
this level is a runbook, not a script. One story, one run.

## Prerequisites

1. Lab up (`tests/e2e/lab-up.sh`), GitHub only is enough.
2. Open `claude` once inside `$LAB/consumer` and accept the workspace trust prompt, then exit.
3. `gh auth status` green (already the case).

## Setup (in `$LAB/consumer`, on `feat/labprd/prd`)

```bash
cd "$(cat /tmp/bmad-it-lab/current | sed 's|^|/tmp/bmad-it-lab/|')/consumer"
git checkout feat/labprd/prd && git pull --ff-only
bmad-loop init --cli claude
# module setup step 4 (ci gate) + step 5 (close-trace-mr), by hand:
MOD=.claude/skills/bmad-issue-tracking-setup
mkdir -p .bmad-loop/plugins
cp -f $MOD/scripts/bmad-loop/ci-gate/ci-status.sh .bmad-loop/ci-status.sh && chmod +x .bmad-loop/ci-status.sh
cp -rf $MOD/scripts/close-trace-mr .bmad-loop/plugins/ && chmod +x .bmad-loop/plugins/close-trace-mr/close-trace-mr.sh
grep -qxF '.bmad-loop/ci-status.sh' .gitignore || echo '.bmad-loop/ci-status.sh' >> .gitignore
grep -qxF '.bmad-loop/plugins/close-trace-mr/' .gitignore || echo '.bmad-loop/plugins/close-trace-mr/' >> .gitignore
# ci-status.json is the gate's OUTPUT (transient): untracked, bmad-loop's single commit of
# the story worktree carries it into the target branch (#96)
grep -qxF 'ci-status.json' .gitignore || echo 'ci-status.json' >> .gitignore
```

`.bmad-loop/policy.toml` (merge into what `init` wrote):

```toml
[gates]
mode = "none"

[review]
enabled = false

[limits]
max_dev_attempts = 2
session_timeout_min = 45

[verify]
commands = ["bash .bmad-loop/ci-status.sh"]

[scm]
isolation = "worktree"
branch_per = "story"
target_branch = "feat/labprd/prd"
delete_branch = false
keep_failed = true
worktree_seed = [".bmad-loop/ci-status.sh", ".bmad-loop/plugins/close-trace-mr"]

[adapter]
name = "claude"
cleanup_session_on_finish = false

[notify]
desktop = false
```

Make sure `sprint-status.yaml` has `1-1-login-form: ready-for-dev` (or `backlog`, per the
bmad-loop version's pick rule) and `ci/outcome` is `pass`, commit, push.

```bash
bmad-loop validate
bmad-loop run --dry-run
bmad-loop run --story 1-1 --max-stories 1      # from a normal terminal, not from Claude Code
```

## Running it under ai-jail

[ai-jail](https://github.com/akitaonrails/ai-jail) (a `bwrap` wrapper) is how the operator
runs this level now: bmad-loop drives `claude --permission-mode bypassPermissions`, so the
session is sandboxed rather than trusted. The launcher is a ~10-line wrapper kept outside the
repo (the working copy lives with the run evidence, which is gitignored); what matters is the
invocation and why each mount is there.

```bash
#!/usr/bin/env bash
set -euo pipefail
PRD=/tmp/bmad-it-lab/<lab>/consumer/_bmad/worktrees/prd
export GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"
BMAD_LOOP_ARGS="$(printf '%q ' "$@")"; export BMAD_LOOP_ARGS
cd "$PRD"
exec ai-jail --no-save-config --exec --terminal-passthrough --network --worktree \
  --rw-map "$HOME/.claude" --rw-map "$HOME/.claude.json" \
  --map "$HOME/.config/gh" --map "$HOME/.local/bin" --map "$HOME/.local/share/uv" \
  --rw-map "$HOME/.local/state/bmad-loop" --rw-map "$HOME/.cache/uv" --rw-map "/tmp/tmux-$(id -u)" \
  --env PATH --env GH_TOKEN --env BMAD_LOOP_ARGS -- bash -c 'eval "exec bmad-loop $BMAD_LOOP_ARGS"'
```

Invoked as `bmad-loop-jail.sh run --story 1-10 --max-stories 1`, i.e. exactly the bmad-loop
command line from the block above.

**Why each flag and mount:**

| Flag / mount | Why |
|---|---|
| `--exec --terminal-passthrough` | ai-jail requires the pair on a real TTY: the child runs directly on the caller's terminal with no PTY proxy, which is what tmux and `bmad-loop attach` need. Not usable from inside a Claude Code session. |
| `--network` | ai-jail starts with networking **off**. gh, git and the Claude API all need it. |
| `--worktree` | the PRD checkout is a *linked* worktree, so its `.git` is a file pointing into the main repo; the flag mounts that metadata and the main repo rw, without which every VCS command inside fails. |
| `--rw-map ~/.claude`, `~/.claude.json` | ai-jail gives the child a private HOME. These two carry Claude Code's OAuth credentials, the directory-trust record and session state — rw because the session writes back. |
| `--map ~/.config/gh` (ro) | gh's config. The token itself is **not** here (it lives in the desktop keyring, which the jail cannot reach) — hence `GH_TOKEN`. |
| `--map ~/.local/bin`, `~/.local/share/uv` (ro) | bmad-loop (installed as a `uv` tool) and `uv` itself. |
| `--rw-map ~/.local/state/bmad-loop` | bmad-loop's events dir — the hook relay writes there. |
| `--rw-map ~/.cache/uv` | every module step is `uv run --no-project python -c …`; without the cache each one re-resolves. |
| `--rw-map /tmp/tmux-$(id -u)` | shares the tmux socket dir so `bmad-loop attach` also works from the **host**. |
| `--env PATH --env GH_TOKEN` | `PATH` so `~/.local/bin` is reachable inside; `GH_TOKEN` exported on the host from `gh auth token` because gh's keyring is unreachable in the jail. It travels through the environment, never written to disk. |

**Not mounted: `~/.ssh`.** No keys, no agent. The lab remote must therefore be **HTTPS**, and
the VCS authenticates through the global `gh auth git-credential` helper (`gh auth setup-git`
on the host, so the helper sits in the user-level config). An `ssh://` or `user@host:` remote
fails at the first push with no useful message.

**Argument passing.** ai-jail rejects child flags that collide with its own — `--dry-run`,
`--verbose` — even when they come after `--`. So the bmad-loop arguments travel shell-quoted
inside `BMAD_LOOP_ARGS` and are `eval exec`-ed on the inside. That is why the wrapper ends in
`bash -c 'eval "exec bmad-loop $BMAD_LOOP_ARGS"'` rather than passing `"$@"` through.

**Judging liveness from the host.** `engine.pid` in the run dir holds the pid *inside* the
jail's namespace, so `bmad-loop list` / `bmad-loop status` run on the host report a perfectly
healthy jailed run as **`interrupted`**. That is an artefact, not a failure — do not stop or
clean up on it. Judge liveness with:

```bash
pgrep -af "bmad-loop run"                       # the real process, on the host
tmux ls; tmux attach -r -t bmad-loop-<run_id>   # read-only attach to the session
tail -f .bmad-loop/runs/<run_id>/journal.jsonl  # the authoritative event stream
```

## What to capture (into `tests/e2e/evidence/<lab>/L/`)

- `.bmad-loop/runs/<run_id>/journal*` and the feedback/ directory (verify rc, diagnostics)
- `git -C .bmad-loop/runs/<run_id>/worktrees/* branch -vv` → the branch is
  `bmad-loop/<run_id>/1-1-login-form` with **no upstream** — the shape the module's
  `push -u origin HEAD` has to handle
- `ls .bmad-loop/runs/<run_id>/worktrees/*/ci-status.json` → present? (`[verify]` needs it)
- `gh run list -R <repo> --limit 5 --json headBranch,conclusion` — was anything pushed at all?
- `gh issue list -R <repo> --state all`, `gh pr list -R <repo> --state all` → D22: the trace PR
  must be on the bmad-loop branch, never on `feat/labprd/1-1-login-form`
- the verify command's rc (0 on a green pipeline; 1 → repair session → story deferred after
  max_dev_attempts)
- `bmad-loop plugin-hook close-trace-mr` output, if the hook fired

Prediction now that D08 and D22 are fixed: the phase pushes `-u origin HEAD`, so the branch
with no upstream reaches the remote; `ensure-mr` opens the trace PR on that same branch
(`source_branch={current_branch}`); the CI gate reads that PR's pipeline and writes
`ci-status.json`; `[verify]` returns 0 on green, and the story issue carries its status label.
A halt at the push, an absent `ci-status.json`, or a PR on `feat/labprd/1-1-login-form` is a
regression of D08/D22.

Teardown of this level: `bmad-loop stop; bmad-loop cleanup` (or leave it; `lab-down.sh` removes
the whole consumer).
