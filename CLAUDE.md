# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

BMAD module that integrates sprint tracking with GitLab/GitHub Issues. It's not a runnable application — it's a set of TOML overrides and two skill folders, packaged for both BMad install routes: the classic installer (`npx bmad-method install --custom-source`, reads `skills/module.yaml`, `skills/module-help.csv`, `.claude-plugin/marketplace.json`) and the Skills CLI (`npx skills add`, reads each `<skill>/module-manifest.toml`; all declare `module = "bmad-issue-tracking"`).

Requires BMM 6.12.0+ (targets the 6.12.0 skill set and `uv`). Install-route rule: **released BMAD (6.12.x) ships only the classic installer**, with the `_bmad/{bmm,core,_config,custom,...}/` consumer layout. The Skills-as-modules route (`npx skills add bmad-code-org/BMAD-METHOD`, `module-manifest.toml`, `bmad setup/update/doctor`, flat `_bmad/{method,toolbox}/`) existed only on BMAD `main` (6.13.0-next) when 3.0.x was cut. The two routes are not designed to coexist in one consumer project (different `_bmad/` layouts; BMAD `main` adds an explicit installer guard). Consumers on a released BMAD use the classic route; the manifests are forward compatibility. Check the BMAD release notes before changing which route the README recommends.

## Architecture

Two skill folders, each with its own `module-manifest.toml` declaring the same module key (plus the shared classic metadata in `skills/module.yaml` + `skills/module-help.csv`):

- `skills/bmad-issue-tracking-sync/` — the user-facing `/bmad-issue-tracking-sync` command. Manifest: `module = "bmad-issue-tracking"`, `knowledge` pointing at its own `references/help.md`.
- `skills/bmad-issue-tracking-setup/` — one-time deploy. Manifest: same module key, `knowledge` pointing at its own `references/help.md`. Its `scripts/` folder holds the bmad-loop integration Python + shell files (`bmad-loop/ci-gate/ci-status.sh`, `close-trace-mr/`).

Assets that get pushed into a consumer project live under `skills/bmad-issue-tracking-setup/assets/custom/` (TOML pointers), `assets/workflows/` (YAML bodies), and `assets/bmad-workflow-lang.md`. The standalone sync SKILL.md never gets copied into a consumer project — only `assets/` payloads do, via the setup skill.

### Issue sync workflow split

The sync task is split into two phases so callers can skip redundant setup:

- **`issue-sync/prepare.yaml`** (steps 1-3) — platform detection, labels, board, PRD issue creation
- **`issue-sync/sync.yaml`** (steps 4-6) — sync issues, mark MR ready, summary (includes its own `check-config` + `find-prd` since context may be compacted)

Callers:
- `sprint-planning/complete.yaml` → `INCLUDE: issue-sync/sync` (steps 4-6 only, prepare ran during sprint planning)
- `sprint-status/complete.yaml` → `INCLUDE: issue-sync/sync` (steps 4-6 only, prepare ran during sprint status)
- `/bmad-issue-tracking-sync` standalone → `INCLUDE: issue-sync/prepare` then `INCLUDE: issue-sync/sync`

## TOML override semantics

Files in `skills/bmad-issue-tracking-setup/assets/custom/` are TOML overrides for BMM workflows:
- `[workflow] activation_steps_append` — array, appends to BMM's activation steps
- `[workflow] on_complete` — scalar, replaces BMM's completion block entirely

All overrides are pure pointers — they reference workflow YAML files that handle the actual logic. The config guard (`common/check-config.yaml` validating `issue_tracking.platform`, `issue_tracking.branch_patterns`, etc.) runs inside each workflow YAML, not in the TOML.

## Key variable conventions in instructions

TOML instructions reference these placeholders — they are NOT config variables, they're resolved at runtime by the AI agent:
- `{prd_key}` — from PRD frontmatter, e.g. `mobile-oidc`
- `{story_key}` — sprint-status entry key, e.g. `1-3-login-form`
- `{epic_num}`, `{story_num}` — extracted from `story_key` (first two dash-separated numbers)
- `{prd_branch}` — `branch_patterns.prd` resolved with `{prd_key}`, e.g. `feat/mobile-oidc/prd`
- `{story_branch}` — `branch_patterns.story` resolved with `{prd_key}` and `{story_key}`
- `{sep}` — `::` for GitLab, `:` for GitHub (label separator)
- `$MR_HOST`, `$MR_PROJECT` — git remote host/project for MR operations (GitLab); same as `$HOST`/`$PROJECT_PATH` when platforms match
- `$MR_OWNER`, `$MR_REPO` — git remote owner/repo for PR operations (GitHub); same as `$OWNER`/`$REPO` when platforms match

## Issue title formats

All workflows that create issues use these title formats. They must stay consistent — `create-issue.yaml` searches by title to avoid duplicates.

| Type | Format | Set by |
|------|--------|--------|
| PRD | `PRD: {prd_key}` | `bmad-prd/complete.yaml`, `create-prd/complete.yaml`, `issue-sync/prepare.yaml` |
| Story | `Story {epic_num}.{story_num}: {title}` | `create-story/complete.yaml`, `sync-issues.yaml` |
| Epic | `Epic {n}: {title}` | `sync-issues.yaml` |
| Retrospective | `Retrospective: Epic {n}` | `retrospective/complete.yaml` |

For stories, the spec's LOCATION and `{title}` both come from **one shared atomic**,
`common/story-title.yaml`, which returns `spec_path` and `story_title`:
frontmatter `title:` first, then a real H1 (`# Story 1.4: Login Form`), then the entry
key's slug segments (`1-4-login-form` → `Login Form`) — and a leading `Story N.M:` is
stripped on **every** one of those paths, because the prefix is the caller's to add
exactly once. `ensure-issue.yaml` and `sync-issues.yaml` both INCLUDE it; they used to
carry their own copies, which had drifted, and a frontmatter `title: 'Story 1.1: Login
Form'` then produced `Story 1.1: Story 1.1: Login Form` on one path and `Story 1.1: Login
Form` on the other — two identities for one story, and the title IS what `create-issue`
dedupes by. During initial sync (sprint-planning) story files don't exist yet, so the
key-derived tier answers; every path produces the same format. The candidate list is
shared too (`{spec_path}` hint, `{spec_file}`, `spec-<prefix>-*.md`,
`stories/<prefix>-*.md`, the legacy `{implementation_artifacts}/{story_key}.md`):
`ensure-issue.yaml` used to try only the last two, so a sprint-mode story with an empty
`{spec_file}` produced no body and no issue.

## Branch/MR flow

Branch setup happens in activation (before BMM workflow runs). The BMM workflow creates files directly in the worktree. on_complete handles commit/push/issue/MR. Never commit on PRD for story work.

| Workflow | Activation | on_complete | MR direction |
|----------|-----------|-------------|--------------|
| bmad-prd (6.11.0+) | Detect intent: create → ask key + create worktree; update/validate → find worktree | Create → issue + commit + push + draft MR; update → update description | PRD → default (draft, create only) |
| create-prd (6.11.0+ shim) | Create/switch to PRD worktree | Commit + push + issue + draft MR | PRD → default (draft) |
| create-architecture | Switch to PRD worktree | Commit + push | (PRD worktree) |
| bmad-ux | Switch to PRD worktree | Commit + push | (PRD worktree) |
| create-epics-and-stories | Switch to PRD worktree | Commit + push | (PRD worktree) |
| sprint-planning | Switch to PRD worktree | Trigger issue sync (steps 4-6) | (PRD worktree) |
| edit-prd (6.11.0+ shim) | Switch to PRD worktree | Update PRD issue description | (PRD worktree) |
| correct-course | Switch to PRD worktree | Update issue descriptions if artifacts modified | (PRD worktree) |
| retrospective | Switch to PRD worktree | Create retrospective issue + close | (PRD worktree) |
| create-story (shim) | Ask story key, create/switch to story worktree (from PRD) | Commit + push + issue + MR | story → PRD |
| dev-story (shim) | Find story with status `ready-for-dev`, switch to worktree | Commit + push + issue + MR, then the CI gate, then update issue (the MR is ensured BEFORE the gate: with no MR the gate has nothing to read and writes green) | (MR from create-story) |
| code-review | Find story with status `review`, switch to worktree | Commit + push + post review + optional merge | story → PRD |
| sprint-status (shim) | Switch to PRD worktree | Trigger issue sync (steps 4-6) | (none) |

### bmad-loop flow (unattended)

Projects using [`bmad-loop`](https://github.com/bmad-code-org/bmad-loop) bypass the manual branch/MR flow: bmad-loop drives `bmad-build-auto` per story in isolated worktrees, is the single writer of `sprint-status.yaml`, and merges each story back locally (never pushes). The module's role shrinks to mirroring:

- `common/find-prd-key.yaml` — silent `prd_key` resolution (no PRD worktree, no prompt); used by `issue-sync/prepare.yaml` + `sync.yaml` so `/bmad-issue-tracking-sync` runs unattended after a bmad-loop run.
- `common/mark-mr-ready.yaml` — no-op when no MR exists (bmad-loop has none). The CI gate DOES run in this flow: the dev-finish phase ensures the trace MR first (`common/ensure-mr.yaml`) and then gates on it (`common/check-mr-ci.yaml`, `common/wait-for-green-ci.yaml`), so the gate has something to read on the first pass.
- `scripts/bmad-loop/ci-gate/ci-status.sh` (in the setup skill's `scripts/` folder) — bmad-loop `[verify]` command deployed to `.bmad-loop/ci-status.sh` (setup step 4): reads `ci-status.json` (written by the `dev-finish` / `review-finish` phases of `common/post-dev-complete.yaml` via `common/write-ci-status.yaml`) and returns exit 0 if CI is green, exit 1 if red (fixable), exit 1 if the file is missing. The intelligent work (polling CI, parsing logs) is done by the `on_complete` workflow.
- `custom/bmad-build-auto.toml` — routes the `bmad-build-auto` `on_complete` hook to `common/post-build-dispatch-auto.yaml`, which honours the `.bmad-ci-handled` marker, sets `review_producer` and then INCLUDEs `common/post-build-dispatch.yaml`. The bmad-build-auto skill executes this hook at the end of EVERY session — including when bmad-loop invokes it — so issue tracking + CI write happen without any bmad-loop plugins. `bmad-build.toml` uses the interactive dispatcher (`post-build-dispatch-interactive.yaml`) with the optional MR merge prompt.
- `awaiting-operator` — bmad-loop status for a story parked on external action; mapped to `status{sep}awaiting-operator` and the issue stays open.

## Platform differences

- GitLab: `glab` CLI, labels use `::` separator, `glab api` for issue updates (labels field replaces all), `glab label create` for labels
- GitHub: `gh` CLI, labels use `:` separator, `gh issue edit --add-label`/`--remove-label` for label updates (preserves other labels)
- `glab api` uses `--hostname`; `glab mr`/`glab label` use `-R`; `gh` uses `-R` with format `[HOST/]OWNER/REPO`

**How a step picks its CLI:** `PLATFORM: gitlab|github` compares against `platform` — the ISSUE
TRACKER (lang §2.4). So it may only annotate steps that talk to the tracker (issues, labels,
comments, boards). Every step that talks to the GIT REMOTE — MR/PR create, find, merge,
mark-ready; CI pipelines, runs, job traces — carries **no `PLATFORM:` annotation** and is
selected by `CHECK: git_platform eq "gitlab"` with the GitHub command in `FALSE:`
(`find-mr`, `get-mr-pipeline`, `merge-mr`, `ensure-mr`, `mark-mr-ready`,
`wait-for-green-ci`, `get-failed-jobs`). Annotating one of those disables it on a
cross-platform setup: the `CHECK` picks the right branch and the `PLATFORM:` filter then
skips the RUN inside it, so its `STORE` variable is never written and the caller reads the
empty value as "no MR" / "no CI". `tests/test_platform_coverage.py` enforces both halves.

**The CI state table lives in three copies.** `common/check-mr-ci.yaml` and the two poll
rounds of `common/wait-for-green-ci.yaml` map a raw pipeline state to the `ci_status` enum.
A poll round is ONE bash `RUN` and cannot `INCLUDE` an atomic, so the table is duplicated —
and `tests/test_ci_status_mapping.py` compares the three `python -c` bodies byte for byte.
Rules the table encodes: every state both APIs answer is NAMED, anything unnamed is
`running` (never green — an unknown state costs wall clock, not a false pass), `skipped`
and `neutral` are green, `manual`/`action_required`/`canceled`/`timed_out` are red (a
pipeline parked on an operator never goes green on its own), and `no_ci`/`no_run` are the
CALLER's answer for an empty but SUCCESSFUL listing, passed in as the second argument —
`running` when the branch defines CI, `no_ci` when it does not, `no_run` inside the rounds.

**Git remote vs issue tracker:** The git remote (origin) and issue tracker can be on different platforms (e.g., code on GitLab, issues on GitHub). `issue_tracking.platform` is the issue tracker; `issue_tracking.git_platform` (set during setup) is the git remote. Issue operations (create/update/close issues, labels, comments) use `platform`. MR/PR operations (list, create, merge, mark ready) use `git_platform`. When they differ, `host`/`project` apply to the issue tracker and `git_host`/`git_project` apply to the git remote. Issue references in MR descriptions use `Closes #X` for same-platform, full URL for cross-platform.

`check-config` resolves BOTH coordinate sets once and exports them: `host`/`project`/
`project_enc` for the TRACKER, and `git_host`/`git_project`/`git_project_enc` plus
`mr_repo` (= `{git_host}/{git_project}`) for the GIT REMOTE — equal to the tracker's when
`git_platform eq platform`, read from `issue_tracking.git_host`/`git_project` otherwise.
Every MR/PR and CI step takes them from there: `mr_repo` for `gh -R` / `glab -R`, and
`git_project_enc` + `git_host` for `glab api projects/… --hostname …`. Never address a
pipeline or an MR through `{project_enc}`/`{host}`: those name the tracker, which is the
right answer only while the two platforms coincide. `gh -R` and the `repos/…` API path
take `owner/repo` whole, so `git_project` is never split into owner and repo.
`merge-mr`'s cross-platform branch additionally READs `git_host`/`git_project` itself, so
no caller has to seed them; its same-platform branch still takes `host`/`project`/
`project_enc` from `check-config`.

### Tracker CLI facts (verified in the lab)

- `gh api --paginate` and `glab api --paginate` join pages with NO separator → parse with a `raw_decode` loop.
- `gh api` paths never contain the host (`repos/{project}/… --hostname {host}`); a raw space in a URL is a
  silent `[]` on gh and an HTTP 400 on glab → pass query text as `-f` fields.
- GitHub's search index lags a create by ~5 s; `gh issue create` prints a URL, not JSON; `gh pr merge` prints
  nothing on stdout; `gh issue edit --add-label` fails on an unknown label (GitLab creates it).
- BMM 6.12.0's classic installer does not install the v6 shims: six TOML overrides target absent skills.
- Claude Code blocks a foreground `sleep N && …` and caps the Bash tool at 120 s default / 600 s max.

## Files to update when adding a new BMM workflow override

1. Create `skills/bmad-issue-tracking-setup/assets/custom/bmad-{workflow}.toml` (pointer format — activation_steps_append and/or on_complete)
2. Create the corresponding workflow YAML files in `skills/bmad-issue-tracking-setup/assets/workflows/{workflow}/`
3. Add the TOML file to the list in `skills/bmad-issue-tracking-setup/SKILL.md` (step 2)
4. Add the YAML files to the verify list in `skills/bmad-issue-tracking-setup/SKILL.md` (step 3)
5. Add a row to the override table in `README.md`
6. If the workflow has a standalone skill, create or update its `references/help.md`, add its row to `skills/module-help.csv` (classic help catalog) and bump `version` in `<skill>/module-manifest.toml`

## Branching and PRs

- `devel` is the integration branch and the default; `main` tracks `upstream/main` (jrevillard).
- PRs are squash-merged: the PR title is the `devel` commit message and must follow the convention.
- `gh pr create` / `gh issue create` need `-R pasqualtroncone/bmad-issue-tracking` — gh resolves to `upstream` otherwise.
- `Closes #n` must be plain text in the PR body; inside backticks GitHub ignores it.
- Upstream PRs: cherry-pick one fix onto a branch from `upstream/main`, never push `devel` wholesale.

## Commit convention

This repo follows the generic scoped-commit convention (`type(scope): description`,
five types: `feat`, `fix`, `docs`, `chore`, `revert`; the description states the
effect or the symptom, never the operation). Repo-specific rules:

### Language

- **English.** Upstream commits in English and changes may go back as PRs.

### Canonical scopes

The scope is semantic (what area is being talked about), not a folder path.

| Scope | Area |
|-------|------|
| `install` | Packaging and install routes: `skills/module.yaml`, `skills/module-help.csv`, `.claude-plugin/marketplace.json`, `*/module-manifest.toml`, install docs |
| `setup` | The `bmad-issue-tracking-setup` skill: version gate, deploy steps, prerequisite checks |
| `sync` | The `bmad-issue-tracking-sync` skill and the `issue-sync/` workflows |
| `overrides` | The TOML pointers in `assets/custom/` (which BMM workflows are hooked, and to what) |
| `workflows` | The workflow YAML bodies in `assets/workflows/` (`common/`, per-workflow folders) |
| `ci-gate` | `ci-status.sh`, the `ci-status.json` contract, CI wait/poll behaviour for bmad-loop |
| `lang` | `bmad-workflow-lang.md`, the workflow language itself |
| `tests` | The test suite infrastructure (`conftest.py`, runners); a test for area X is `chore(X)` |
| `readme` / `changelog` | The respective file, when the change belongs to no area (a docs change about an area takes that area's scope, e.g. `docs(install)`) |
| `release` | Version bumps and tags |
| `repo` | Repo housekeeping that fits no area (`.gitignore`, stale artifacts) |

**Without scope** go cross-cutting changes (`LICENSE`, this convention): plain `docs:` or `chore:`.

**Vocabulary maintenance:** a commit that needs a scope missing from this table adds it
to the table in the same commit/PR.

### Issue tracker

- The issue reference goes **only in the footer**: `Refs #n`, or `Closes #n` in the
  commit/PR that closes the task. Never in the scope or the description.

### PR title

The PR title becomes the `main` commit message when squash-merged, so it must satisfy the
full convention (type + scope + description with substance). Intermediate branch commits
follow the same format with lower stakes; the `Refs #n` footer is non-negotiable.

### Examples from this repo

- ✅ `chore(release): 3.0.0`
- ✅ `chore: add the MIT LICENSE file the README already declares`
- ❌ `docs(readme): fix stale BMM version refs, add architecture/CI/troubleshooting/license`
  → the "and" list signals several changes; split, or name the one effect that matters:
  `docs(readme): BMM version refs no longer point at 6.11`

## e2e lab (tests/e2e)

- `make e2e-static` — level 0, greps only, no lab. `tests/e2e/replay.sh <case>|all|gitlab` — level 1,
  literal RUN replays (no LLM); `tests/e2e/scenarios/A*.sh` — level 2, headless Claude (~$3 each).
- `tests/e2e/lab-up.sh` creates the GitHub lab; `--add-gitlab --gl-host <host>` adds a GitLab consumer
  (glab must be authenticated on THAT host); `--check` proves BMM resolves the module hooks.
- Level 1 renders steps from THIS checkout; level 2 reads the consumer's deployed copies → run
  `tests/e2e/lab-up.sh --redeploy` after every workflow change before any A*/P* scenario.
- Never edit `replay.sh` or a scenario while it runs (bash reads the file incrementally).
- Cases that push CI branches (`d2`, `gl-d2`, `d16`, `gl-d16`, `d03`) cannot run concurrently on one lab.
- Evidence lives in `tests/e2e/evidence/<lab>/` (gitignored); `tests/e2e/lab-down.sh` tears the lab down.

## Python environment

Tests use `pytest` and `pyyaml`. Run them with `uv` (already a module requirement), never `pip3 install --break-system-packages`:
```bash
uv run --with pytest --with pyyaml pytest -q
```
A project venv works too:
```bash
python3 -m venv .venv && source .venv/bin/activate && pip install pytest pyyaml
```

## Releasing

When working on a branch, add functional changes to the `[Unreleased]` section of `CHANGELOG.md` following Keep a Changelog format (Added, Changed, Fixed, etc.) — one entry per logical change, not per commit.

When cutting a release:
1. Bump `version` in every `skills/*/module-manifest.toml`, in `skills/module.yaml` and in `.claude-plugin/marketplace.json` — `tests/test_packaging.py` fails if they disagree.
2. Update `CHANGELOG.md` — replace `[Unreleased]` with the version and date, add comparison link.
3. Create a git tag `v{version}` on the version bump commit and push it (`git push origin --tags`).

## Step-authoring rules the test suite enforces

These four are not style preferences — `tests/` fails a workflow that breaks them, and all
four have caught real defects:

- **No raw shell variables in any step.** `test_command_patterns.py::test_no_unresolved_shell_vars`
  rejects `$var` and `${var}` in every step's `raw_value` (only the awk built-in `NF` is
  allowed). Variables are passed through the workflow language's `{placeholder}` scope —
  which also means **there is no supported environment-variable channel into a workflow**,
  so a caller cannot signal behaviour that way. `test_variable_flow.py` additionally flags
  a `${X:-default}` colon as a hardcoded label separator, so even the shell-default idiom
  is doubly unavailable. **If a caller must influence a workflow, use a file** (see
  "Caller negotiation" below) — never an env var.
- **Every `common/*.yaml` needs the four-line header** — Purpose, Input variables, Output
  variables, **Side effects**. `test_include_contracts.py` requires the Side effects line
  even when the answer is "none" (`check-config` and `find-issue` both say
  `Side effects: none`). Four MR atomics shipped without it and left the suite red; only
  the first was ever reported, because `assert` aborts the test on the first failure.
- **`STOP` is a RETURN, never a halt.** Lang §2.10 says it ends the CURRENT file and
  resumes the INCLUDE caller with every variable in scope; the whole-run halt is
  `OUTPUT ... stop: true` (§2.5). `test_stop_semantics.py` keeps the files inside that
  reading: a STOP-bearing file must have an INCLUDE caller and must never be an entry
  workflow a TOML override points at, no `- STOP` may sit unconditionally at column 0,
  and §2.10 must keep defining it as a return. Two headless interpreters read the old
  wording two different ways and one ended a whole sync at `common/find-prd-key.yaml`,
  where the step meant "prd_key is already known, carry on" — so prefer a guard that
  needs no early return (`find-prd-key`, `ensure-board`, `mark-mr-ready` all gate their
  body on the positive condition now) and comment the STOPs that stay.

- **A CHECK may only read a variable that is predefined, SET on every path that reaches
  it, or an output of an INCLUDEd atomic.** Lang §4.5 stops a run on a reference to an
  undefined variable and the §5 table says the same for a CHECK, so there is no
  "unset reads false" idiom: an optional flag is one whose DEFAULT is SET at the entry
  point. `common/check-config.yaml` seeds `lookup_after_create`, the three
  `post-dev-complete-*` wrappers plus the two dispatchers seed `review_producer` and
  `allow_merge`, `ensure-labels`/`create-issue` seed `label_color`, and `merge-mr` seeds
  its `error` output. `test_optional_variables.py` walks the INCLUDE graph from every
  entry workflow and fails when a closure reaches a reader with no setter. Two headless
  interpreters have read the same file both ways; the strict reading is the one that
  holds.

A fifth rule is not checked by `tests/` but by the e2e level-0 report (`make e2e-static`,
item `D03-static`): **no single `RUN` may block longer than the interpreter's Bash tool
allows** — 120 s by default, 600 s at most. A long wait is expressed in the workflow
language, not in bash: `common/wait-for-green-ci.yaml` spends its 30-minute CI budget as a
`LOOP` over eighteen rounds, each ONE `RUN` of at most 4 polls × 25 s (~100 s) that stores
`ci_status` and lets the following iterations no-op once the state is terminal. The
original shape (one `RUN` looping `sleep 30` sixty times) was killed by the tool on any
pipeline longer than the cap, so `ci_status` was never set, `common/write-ci-status.yaml`
never wrote `ci-status.json` and bmad-loop's `[verify]` failed for the wrong reason. The
round must fit the 120 s DEFAULT, not just the 600 s maximum: at 8 polls (~200 s) it only
survived where the interpreter had raised the timeout, which is the same failure again.

## Adding or removing a workflow file

`skills/bmad-issue-tracking-setup/SKILL.md` step 3 carries an explicit per-file verify
list of every file the setup step must have copied. Adding
`common/post-build-dispatch-auto.yaml` required adding it there; forgetting leaves the
installer green while the file is missing in the consumer.

## Which producer wrote the review section (post-dev-complete review-finish)

Three producers reach `common/post-dev-complete.yaml`, and they disagree about the
`## Review Triage Log` / `### Review Findings` section:

| Producer | Section | How it is reached |
|---|---|---|
| `bmad-build-auto` | appends a `### <date> — Review pass` entry on EVERY pass | its `on_complete` hook |
| `bmad-build` | one row PER FINDING → nothing on a clean review | `post-build-dispatch-interactive.yaml` |
| `bmad-code-review` | nothing at all on a clean review | its `on_complete` hook → `post-dev-complete-review-finish.yaml` |

Only `bmad-build-auto` guarantees a section, so only there does a missing/empty section
mean "the review never ran". `common/post-build-dispatch-auto.yaml` — used solely by the
`bmad-build-auto` hook — sets `review_producer="bmad-build-auto"`, and post-dev-complete
halts on an absent/empty section **only** when that flag is present; every other flow
warns and continues to the CI gate.

Two things NOT to do here, both tried and reverted:
- **`allow_merge` cannot discriminate.** It marks the interactive merge prompt and is
  unset on BOTH the unattended and the `bmad-code-review` paths, so keying the halt on it
  blocked clean `bmad-code-review` stories.
- **Never let a sentinel reach `review_section`.** The block after the sentinels checks
  `empty review_section` and posts whatever it holds. A warn branch that does not clear
  the variable posts the literal string `SPEC_NO_REVIEW_SECTION` as the issue comment —
  while its own message claims no comment was posted.

Halt only on a missing spec FILE (`SPEC_NOT_FOUND`): that case is unambiguous and is the
one that actually killed story 2-1, whose phase read the spec from an invented path
(`{implementation_artifacts}/{story_key}.md`) with no error handling. The spec is now read
from `{spec_file}` — the path the runtime resolves, per the predefined-variables table
in `bmad-workflow-lang.md` §4.4 and BMAD's `tools/skill-validator.md:37` — with the
legacy path kept as a second candidate so existing consumers do not regress.

## Caller negotiation (both current channels)

**When the marker is present, the module does none of the tracker work for that story** —
no push, no MR, no CI, no issue status, no comment. That means the caller must cover all of
it. `bmad-build-converge` does: it pushes, ensures the MR, polls the pipeline, merges, sets
the story issue `in-progress` then `done` + close, and posts one comment carrying the
implementation summary and the review findings. It reuses THIS module's atomics for the
tracker calls (`post-issue-comment.yaml`, executed the way the hooks execute it), so the
platform logic still lives here — but the extraction rule for the review section is
duplicated in the caller (the module's workflow files cannot be imported). If you change
how `## Review Triage Log` / `### Review Findings` are extracted in
`common/post-dev-complete.yaml`, change it in `bmad-build-converge.js`'s
`postStoryIssueComment` too.



A caller cannot pass a variable into a workflow (see the step-authoring rules), so when a
caller needs different behaviour it declares that through something a step CAN read:

| Channel | Set by | Read by | Effect |
|---|---|---|---|
| `review_producer="bmad-build-auto"` | `common/post-build-dispatch-auto.yaml`, used only by the bmad-build-auto hook (the other entry wrappers seed `""`) | post-dev-complete review-finish | halt on an absent/empty review section (the only producer that guarantees one) |
| `<worktree>/.bmad-ci-handled` (file) | the caller, before dispatching | `common/post-build-dispatch-auto.yaml`, at its FIRST step | the WHOLE chain does nothing — no `check-config`, no spec read, no routing, no phase |

The marker file exists because a caller (bmad-build-converge) does the whole chain itself —
it pushes, ensures the MR, polls the pipeline and merges — so running the module's chain too
is a pure duplicate, and its CI wait re-introduces inside every build dispatch the delay the
convergence loop deliberately removed (measured 47-305 s per dispatch in the run traces).
Absent marker → unchanged behaviour, so bmad-loop is untouched and still gets the
`ci-status.json` its `[verify]` requires. The guard lives at the ENTRY POINT
(`post-build-dispatch-auto.yaml`, before the INCLUDE) precisely so nothing downstream runs;
placing it later would leave `check-config`, the spec read and the routing executing.

Convention for any future channel: a **file or a workflow variable set by a wrapper we
ship**, never a shell variable, and always with the "absent → previous behaviour"
property so consumers that know nothing about it cannot regress.
