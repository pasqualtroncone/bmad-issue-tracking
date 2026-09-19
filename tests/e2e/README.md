# e2e lab — real repos, real CI, real BMM, real hooks

The offline suite (`tests/test_*.py`) regex-parses the workflow files; it cannot see whether a
`RUN` step works. This lab does: it creates a **disposable private GitHub repo** (and optionally
a GitLab project), builds a consumer project with **BMM 6.12.0 via the classic installer**, deploys
this module into it exactly as `/bmad-issue-tracking-setup` would, and then exercises the module
at four levels — from `grep` to `bmad-loop`. Every case ends with a verdict
(`CONFIRMED` / `REFUTED` / `MASKED-BY` / `LATENT` / `OBSERVED` / `BLOCKED`) and leaves its
evidence under `tests/e2e/evidence/<lab-id>/<case>/` (gitignored).

Nothing here is collected by pytest (no `test_*.py`), and nothing runs without you asking.

## Requirements

| Tool | State needed |
|---|---|
| `gh` | authenticated; `repo` + `workflow` scopes. `delete_repo` only for `lab-down.sh` (else it archives and prints the delete command) |
| `glab` | for the GitLab consumer and the `g06`/`gl-*` cases; authenticated on the host you pass with `--gl-host` (check `glab auth status --hostname <host>`, not just gitlab.com). Scopes `api`, `write_repository`. The namespace is the authenticated username |
| `uv`, `node`/`npx`, `git` | `npx -y bmad-method@6.12.0` is fetched from npm on `lab-up` |
| `claude` | level 2 / BMM phase: headless `claude -p` runs on your account (≈ $0.5–3 per scenario) |
| `bmad-loop` 0.11.1 | level 3 only (`uv tool install bmad-loop`) |

## Layout

```
tests/e2e/
  lib/common.sh     $LAB, evidence dirs, verdict(), snapshot(), wait_run(), claude_headless(), worktree helpers
  lab-up.sh         repo + consumer + BMM install + module deploy (--via-skill for the real setup skill) + fixtures; --check
  lab-down.sh       delete/archive the repo(s), remove the consumer and the /tmp leftovers
  replay.sh         level 0 (static) and level 1 (literal RUN replays)
  seed-issues.sh    105 labelled issues for the pagination case (D04)
  run-hook.sh       level 2: a TOML on_complete (or any instruction) executed by a headless Claude in a worktree
  run-skill.sh      BMM phase: a real BMM skill run headless with scripted answers
  trace-tools.py    render-step / lint-sys / reachable / analyze (commands, files, results, improvisation, coverage)
  fixtures/         ci.yml, .gitlab-ci.yml, issue-tracking.yaml.tmpl, consumer/{planning,implementation}-artifacts, quoting-body.md
  scenarios/        A1..A9 (hooks), P1..P5 (real BMM skills), L-bmad-loop.md (runbook), _lib.sh
  evidence/         per lab: traces, snapshots, verdicts (gitignored)
```

The lab lives in `/tmp/bmad-it-lab/<YYYYMMDD>-<4hex>/consumer`; `/tmp/bmad-it-lab/current` names
the active one. The consumer commits **everything** (`_bmad/`, `.claude/`, fixtures): worktrees
carry tracked files only and the hooks read `_bmad/_config/custom/` relative to the worktree.
`push.autoSetupRemote=false` and `push.default=simple` are pinned so no local git config can mask
D08.

## Usage

```bash
make e2e-static                 # level 0, seconds, no lab
make e2e-up  [PLATFORM=github]  # ≈4 min (npm install of bmad-method)
tests/e2e/lab-up.sh --add-gitlab --gl-host gitlab.example.com   # add a GitLab consumer to the current lab
tests/e2e/replay.sh gitlab      # g06 gl-d23 gl-d16 gl-d4 gl-d2 gl-d18 d26 d03
make e2e-check                  # resolve_customization.py returns the module's on_complete per skill
make e2e-replay                 # level 1, ≈35 min (two Actions runs, 105 issues seeded, index waits)
tests/e2e/replay.sh d18         # or one case at a time
tests/e2e/scenarios/A1.sh       # level 2, one hook run ≈3–8 min; see `make e2e-agent` for the order
tests/e2e/scenarios/P1.sh       # real BMM skill, ≈5–15 min each
make e2e-down
```

Cases and what they prove:

| Case | Level | Defect | Mechanism |
|---|---|---|---|
| `static` | 0 | S1–S9, D03, D22 | greps + `trace-tools.py lint-sys` |
| `d17` | 1 | D17 | `sync-issues.yaml:274` replayed with `0` → `NameError` |
| `d18` | 1 | D18 (masks D03) | STATUS snippet without `2>/dev/null`; full poll loop ×2 → `timeout`; +`import sys` → terminal on first poll |
| `d2` | 1 | D02 | push `ci-green`(pass) then `ci-red`(fail); on `ci-green`, `get-mr-pipeline` says `failure` |
| `d4` | 1 | D04 | 105 issues `prd:bulkprd`; `--paginate | json.load` → `Extra data`; ≤100 works |
| `d7` | 1 | D07 | `git commit -m` on a clean tree → exit 1 |
| `d8` | 1 | D08 (+D22) | `bmad-loop/r1/…` branch without upstream → `git push` exit 128; module's `story_branch` absent on origin |
| `d16` | 1 | D16 | `gh pr merge` rc=0, stdout empty → `merged=false` |
| `d15` | 1 | D15, #52 | the key comes out of the loop item under both renderings and the status out of `sprint-status.yaml` by that key (`backlog` for a bare item too); no `: backlog` in the title or in `/tmp/issue-desc-*.md`; no step left rendering `{entry}` as a key |
| `d19` | 1 | D19/D20 | `find-issue` on `1-1-login-form`: the query still returns `Story 1.10`, the verdict reads which id the step SELECTS; index latency; space in URL |
| `d21` | 1 | D21 | `ensure-issue`/`sync-issues` title step against the 6.12.0 spec (frontmatter title, no H1) and the legacy H1 variant; the pre-fix heading rules are replayed alongside |
| `d24` | 1 | D24/D25 | `create-issue` lookup: absent title → empty + rc=0 (not a FILTER halt), present title → its number, and the same over 105 issues (2 `--paginate` pages) |
| `d9` | 1 | D09 (LATENT) | inline `--body "{description_body}"` with quotes/backticks/`$(…)` |
| `r1` | 1 | #47 | `gh issue create` on the lab repo: its stdout is a URL, and the id-extraction step must yield that issue's number |
| `r3` | 1 | #49 | push `ci-green`, then read the run list and render `check-mr-ci`'s mapping at once: an empty list must not come out `no_ci` while a CI-less branch still does |
| `g06` | 1 | D06 | GitLab `search=1-1-login-form` still returns 1.1, 1.10 and 11.1 newest-first; the verdict reads which iid the step SELECTS (and that `Epic 1:` does not resolve to `Epic 10:`) |
| `gl-d23`, `gl-d4`, `gl-d16`, `gl-d2`, `gl-d18` | 1 | D23, D04, D16, D02, D18 on GitLab | same replays as the GitHub cases against the GitLab consumer (D16 and D02 are GitHub-only; the rest hit both) |
| `d03` | 1 | D03 | GitLab MR on `ci/outcome=sleep:400`: one rendered poll round is timed while the pipeline runs (must print `running` well under 240 s) and again once it is green (`passed` in one poll); also asserts the rendered round's `sleep × polls` bound |
| `g10` | 1 | D10 | cross-platform repo mix-up (rendering): `get-mr-pipeline` hits the git remote, `merge-mr`'s cross-platform branch routes on `git_platform` and resolves every placeholder on its own |
| `d26` | 1 | D26 | the retrospective description rendered for epic 1 carries the `**Sprint Key:**` marker, and GitLab `find-issue` selects that issue for `epic-1-retrospective`; a pre-fix body is invisible to the same search |
| `A1`…`A9` | 2 | D21, D18+D03, D17/D15, D07, review gate, D09, D08/D22, D16/S1, marker | real TOML text → headless Claude in the worktree |
| `P1`…`P5` | BMM | D07, D17, D21, D02 in the real flow | `bmad-prd`, `create-epics-and-stories`, `sprint-planning`, `bmad-build` ×2 |
| `L` | 3 | D08/D22 end to end | `bmad-loop run --story 1-1` (runbook, by hand) |

## Reading a level-2 run

`evidence/<lab>/<case>/<tag>/`:

- `prompt.txt` — exactly what the agent got: the TOML `on_complete` text verbatim, preceded only by the variables the skill run would have left in scope (`spec_file`, …).
- `trace.jsonl` — the raw `stream-json` transcript; `result.json` — turns, cost, tool counts, tool errors.
- `commands.txt` / `tool-results.txt` — every Bash command and its result.
- `improvisation.txt` — each command matched against the `RUN` steps reachable from the entry workflow through `INCLUDE` (placeholders → wildcards). `IMPROVISED` = a command the workflow never wrote (lang §7 forbids it). `coverage.txt` = reachable `RUN` steps never executed.
- `snap-<tag>/` — `git log`, upstream, `ci-status.json`, `gh run/issue/pr list --json`, `/tmp` leftovers.

Bash is allowed broadly on purpose (`--allowedTools Read,Glob,Grep,Write,Edit,Bash` minus
`rm -rf`, force pushes, repo deletion, hard resets): a narrow allowlist would make a denied
command look like a module defect. The blast radius is the disposable repo and `/tmp`.
`E2E_STRICT_ALLOW="Bash(gh:*),Bash(git:*),…"` reruns a scenario with a closed list to document
what a hook really needs.

## Two things learned the hard way

- **Never edit a scenario script while it is running.** bash reads the file incrementally; an edit
  moves the offsets and the running script dies with a syntax error at the next line it reads
  (A4 run 2 lost its verdict that way; the evidence was intact and the verdict was re-derived).
- **`claude -p` options are variadic.** `--allowedTools a,b prompt` swallows the prompt. The drivers
  pass the prompt through stdin for that reason. Also: Claude Code 2.1.270 blocks a foreground
  `sleep N && …` Bash call outright and defaults the Bash tool to 120 s (600 s max), which is
  what A2 measures against.

## Cost and time

| Level | Wall time | LLM cost |
|---|---|---|
| 0 static | seconds | none |
| 1 replay (all) | ≈35 min | none (≈30 min of private Actions minutes) |
| 2 hooks (A1–A9, A2 ×3) | ≈1.5 h | ≈17 `claude -p` runs |
| BMM phase (P1–P5) | ≈1 h | 5–6 skill runs |
| 3 bmad-loop | 30–60 min | 1–2 sessions |

## Teardown

`tests/e2e/lab-down.sh` deletes the GitHub repo when the token has `delete_repo`
(`gh auth refresh -h github.com -s delete_repo`), otherwise archives it and prints the command.
It also stops bmad-loop, prunes worktrees, removes `/tmp/bmad-it-lab/<id>` and the
`/tmp/issue-desc*.md`-style files the workflows leave behind. Evidence stays.
