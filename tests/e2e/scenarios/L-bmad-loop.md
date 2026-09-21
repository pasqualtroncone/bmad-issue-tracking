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
