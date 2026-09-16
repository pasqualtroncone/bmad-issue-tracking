#!/usr/bin/env python3
"""Assemble the lab's verdicts into a report and per-defect issue bodies.

  report.py <lab-id> [--out <dir>]     writes <evidence>/<lab>/report.md and issues/<defect>.md

Issue bodies quote the literal command that was replayed (the .cmd file rendered from the
workflow), its exit code and the head of its stderr/stdout — the shortest evidence a reader
can re-run. Level-2 runs contribute turns/cost/improvisation counts and the final message.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVID = HERE / "evidence"

# defect id → (title-with-symptom, files:lines, cases that carry evidence, fix proposal)
DEFECTS = {
    "D02": ("GitHub CI status is read from the whole repository, not the story branch",
            "common/get-mr-pipeline.yaml:33,42 · common/wait-for-green-ci.yaml:87,143",
            ["d2", "P5-D02"],
            "Add `--branch {source_branch}` to every `gh run list` (get-mr-pipeline, the poll body, the failure path), or resolve the run through `gh pr checks {mr_iid}` / the PR's head SHA."),
    "D03": ("wait-for-green-ci polls for up to 30 minutes inside one RUN step; the Bash tool caps at 600 s",
            "common/wait-for-green-ci.yaml:43-74, 81-112",
            ["static", "A2-proxy", "A2-default", "A2-patched"],
            "Poll from the workflow (a LOOP with a bounded RUN of ≤ 5 min each) or delegate the wait to `gh run watch` / `glab ci status --live` with an explicit `timeout`; write ci-status.json `timeout` explicitly when the cap is hit. Note Claude Code 2.1.270 also blocks long foreground sleeps."),
    "D04": ("GitHub bulk fetch breaks past 100 issues: paginated JSON is fed to a single json.load",
            "common/sync-issues.yaml:28 · common/find-issue.yaml:15",
            ["d4"],
            "Use `gh api --paginate --slurp` and iterate the array of pages (both files); the newline split in find-issue does not work because gh joins pages without a separator."),
    "D07": ("PRD/retrospective hooks halt on re-run: `git commit -m` without --allow-empty exits 1 on a clean tree",
            "bmad-prd/complete.yaml:66 · create-prd/complete.yaml:56 · retrospective/complete.yaml:48",
            ["d7", "A4-D07", "A4-D07b"],
            "`git commit --allow-empty -m …` (as post-dev-complete already does) or guard with `git diff --cached --quiet ||`. The update branch of bmad-prd/complete should also commit/push the PRD change."),
    "D08": ("dev-finish/review-finish `git push` has no upstream on bmad-loop branches and exits 128",
            "common/post-dev-complete.yaml:118,183",
            ["d8", "A7-D08", "A7-D08-D22"],
            "`git push -u origin HEAD` (or `git push -u origin {current_branch}`) in both phases; the create-story phase is the only one that sets the upstream today."),
    "D22": ("The module derives story_branch=feat/{prd_key}/{story_key} but bmad-loop names the branch bmad-loop/<run>/<story_key>",
            "common/post-dev-complete.yaml:65-72 · common/ensure-mr.yaml:48",
            ["static", "d8", "A7-D08-D22"],
            "Use `{current_branch}` as the MR source branch (and for the push) instead of the pattern-derived name; keep the pattern only for creating branches."),
    "D16": ("merge-mr reports merged=false after a successful `gh pr merge` (stdout is empty)",
            "common/merge-mr.yaml:56-58, 78-87",
            ["d16", "A8-D16"],
            "Derive `merged` from the exit code (drop `EXPECT_EXIT: any`, or capture `$?`) or from the API (`gh api …/pulls/N --jq .merged`); `merge_sha` non-empty is already the reliable signal."),
    "D17": ("Issue sync stops after the first created issue: NameError on `sys` in the counter increment",
            "common/sync-issues.yaml:274-277",
            ["d17", "A3-D17-1", "A3-D17-2", "P3"],
            "Add `import sys` (the two sibling increments at :188 and :223 have it). Fix the dead test (S7) so it catches this class."),
    "D18": ("CI polling never sees a terminal state: the status mapping NameErrors under 2>/dev/null, so every running pipeline ends in `timeout`",
            "common/wait-for-green-ci.yaml:56-66, 94-104",
            ["d18", "A2-proxy", "A2-default"],
            "Add `import sys` to the STATUS mapping in both loops and drop the `2>/dev/null` that hides the traceback. This defect masks D03 (the loop always runs the full 30 min)."),
    "D19": ("find-issue on GitHub is a fuzzy search with no title check: story 1-1 also matches Story 1.10",
            "common/find-issue.yaml:15-32",
            ["d19", "A1-D21"],
            "Filter the result on the exact `**Sprint Key:** \\`{story_key}\\`` body marker or on the exact title prefix `Story {epic}.{story}:` (as create-issue.yaml already does with `where: title matches`); search-index latency (~5 s) also argues for the REST list endpoint + local filter."),
    "D23": ("find-issue on GitHub never finds the PRD issue: the space in `PRD: {prd_key}` breaks the request and the pipe hides the failure",
            "common/find-issue.yaml:15 · issue-sync/prepare.yaml:17 · bmad-prd/complete.yaml:32",
            ["d19-D23", "d19", "A4-D23"],
            "URL-encode `search_text` (`urllib.parse.quote_plus`) or switch to `gh api -X GET search/issues -f q=…`; add `set -o pipefail`-equivalent handling (check gh's exit before parsing)."),
    "D24": ("On GitHub, creating any story or epic issue halts once the PRD issue exists: create-issue's FILTER existence check has no match and the language treats that as an error",
            "common/create-issue.yaml:31-35 · bmad-workflow-lang.md §2.3 Failure / §5",
            ["A1-D24", "A3-D17-1"],
            "Replace the FILTER with a RUN that prints the matching number or an empty string (python over the listing), so a miss yields an empty issue_id; or give FILTER an `allow_empty`/`default` field in the language."),
    "D15": ("sync-issues renders {entry} as 'key: status' and the status leaks into issue titles and temp-file names",
            "common/sync-issues.yaml:41-55, 108-139, 236",
            ["A3-D15"],
            "Iterate over `entries` with `as: entry` giving key and value explicitly (the language's {key,value} map contract) and pass `{entry.key}` to the title/filename steps; or split once at the top of the loop and never reuse `{entry}` raw."),
    "D21": ("Issue titles come out as `Story 1.1: ` (or `Story 1.1: Intent`): the 6.12.0 spec template has no `# ` heading",
            "common/ensure-issue.yaml:53-63 · common/sync-issues.yaml:108-139",
            ["A1-D21", "A3-D21"],
            "Read the title from the spec frontmatter (`title:`) first, then fall back to the H1; sync-issues should skip `## ` headings inside `<intent-contract>`."),
    "D10": ("Cross-platform (issues on GitHub, code on GitLab): the MR atomics query the issue-tracker repo and reference variables nobody sets",
            "common/get-mr-pipeline.yaml:33,42 · common/merge-mr.yaml:69,73",
            ["g10"],
            "Use `{mr_repo}` (already resolved by check-mr-ci) in get-mr-pipeline; derive git_owner/git_repo inside merge-mr from git_project instead of expecting the caller to."),
    "S1": ("merge-mr uses the operator `neq`, which the workflow language does not define", "common/merge-mr.yaml:36,66", ["static"], "Use `ne`."),
    "S2": ("create-issue: TRUE/FALSE branches are mis-indented under `CHECK: empty issue_id`", "common/create-issue.yaml:36-42", ["static"], "Indent the branches under the CHECK; both branches STOP today so behaviour survives by luck."),
    "S3": ("Sync SKILL.md routes on BMAD_*_ACTION environment variables that no workflow reads", "skills/bmad-issue-tracking-sync/SKILL.md:20-34", ["static"], "Remove steps 3-4 or replace the env channel with the file/variable convention CLAUDE.md prescribes."),
    "S4": ("Setup help.md names the wrong config path (_bmad/_config/custom/ vs _bmad/custom/)", "skills/bmad-issue-tracking-setup/references/help.md:14", ["static"], "Point at `_bmad/custom/issue-tracking.yaml`, the path check-config.yaml reads."),
    "S5": ("ensure-dynamic-labels computes epic_color and nothing uses it", "common/ensure-dynamic-labels.yaml:184-190", ["static"], "Pass `--color` to create-label (gh/glab both accept it) or drop the step."),
    "S6": ("`EXPECT_EXIT: any` is used 11× but the language only defines numeric exit codes", "assets/bmad-workflow-lang.md §2.4", ["static"], "Document `any` in the RUN field table (the agent already interprets it)."),
    "S7": ("The import-sys test never runs: it filters on `uv run python` while every step says `uv run --no-project python`", "tests/test_command_patterns.py:166", ["static"], "Match `python -c` instead; with the fix the test reports the three D17/D18 bodies (see S9 for the parser depth problem)."),
    "S8": ("{spec_file} is read by three workflows but never defined in the workflow language", "assets/bmad-workflow-lang.md §4.4 · common/post-build-dispatch.yaml:11 · common/ensure-issue.yaml · common/post-dev-complete.yaml", ["static"], "Add `{spec_file}` to the predefined-variables table (source: the calling BMM skill's resolved spec path) and fix the CLAUDE.md line reference."),
    "S9": ("tests/conftest.py drops steps nested LOOP → CHECK → RUN, so the suite never sees sync-issues.yaml:274", "tests/conftest.py:_parse_branches", ["static"], "Re-parse branch bodies recursively with file-relative line numbers (tests/e2e/trace-tools.py scan_steps is a linear scanner that reaches them)."),
}

LATENT = {"D09": ("ensure-mr interpolates --title/--body inline; quotes or $(…) in a body break gh or execute", "common/ensure-mr.yaml:45-49", ["d9", "A6-D09"], "Use `--body-file {mr_description_file}` (gh) / `--description-file` or `-F description=@file` (glab).")}


def read(p):
    try:
        return p.read_text(encoding="utf-8")
    except OSError:
        return ""


def head(p, n=900):
    t = read(p).strip()
    return t if len(t) <= n else t[:n] + " …"


def verdict_line(case_dir):
    v = read(case_dir / "verdict.txt").strip()
    return v.split("\t", 2) if v else None


def case_block(lab, case):
    d = EVID / lab / case
    if not d.exists():
        d2 = EVID / "static" if case == "static" else None
        if d2 and d2.exists():
            return f"- `static`: see `tests/e2e/evidence/static/report.md`\n"
        return f"- `{case}`: (not run yet)\n"
    out = []
    v = verdict_line(d)
    if v:
        out.append(f"**{case} → {v[0]}** ({v[1]}): {v[2]}\n")
    # level-1 evidence: every .cmd with its rc/out/err
    for cmd in sorted(d.glob("*.cmd")):
        stem = cmd.stem
        rc = read(d / f"{stem}.rc").strip()
        if not rc and not (d / f"{stem}.out").exists():
            continue
        out.append(f"<details><summary><code>{stem}</code> — rc={rc or '?'}</summary>\n\n```bash\n{head(cmd, 1200)}\n```\n")
        o, e = head(d / f"{stem}.out", 500), head(d / f"{stem}.err", 700)
        if o:
            out.append(f"stdout:\n```\n{o}\n```\n")
        if e:
            out.append(f"stderr:\n```\n{e}\n```\n")
        out.append("</details>\n")
    # level-2 evidence: result.json per run dir
    for run in sorted(p for p in d.iterdir() if p.is_dir() and (p / "result.json").exists()):
        r = json.loads(read(run / "result.json") or "{}")
        res = r.get("result") or {}
        out.append(f"- run `{run.name}`: turns={res.get('num_turns')} cost=${(res.get('total_cost_usd') or 0):.2f} bash={r.get('bash_commands')} improvised={r.get('improvised')} tool_errors={r.get('tool_errors')}; final message tail:\n\n```\n{head(run / 'final.txt', 700)}\n```\n")
    for extra in ("summary.txt", "runs.txt", "index.txt", "paginate-shape.txt", "push-autosetupremote.txt", "pr-state-after.txt"):
        if (d / extra).exists():
            out.append(f"`{extra}`:\n```\n{head(d / extra, 600)}\n```\n")
    return "\n".join(out)


def issue_body(lab, did, meta, latent=False):
    title, where, cases, fix = meta
    b = [f"## Symptom\n\n{title}.\n", f"**Where:** `{where}`\n",
         f"**Verdict:** {'LATENT — callers pass benign input today' if latent else 'CONFIRMED'} in the e2e lab `{lab}` (branch `e2e-lab`, `tests/e2e/`). Commands below are the RUN steps rendered verbatim from the workflow files and executed against a disposable GitHub repo with BMM 6.12.0 (classic installer).\n",
         "## Evidence\n"]
    for c in cases:
        b.append(case_block(lab, c))
    b.append(f"## Proposed fix\n\n{fix}\n")
    b.append(f"\n---\n_Reproduce: `tests/e2e/lab-up.sh && tests/e2e/replay.sh {cases[0] if cases[0] != 'static' else 'static'}` (level-2 cases: `tests/e2e/scenarios/<A>.sh`). Evidence dir: `tests/e2e/evidence/{lab}/`._\n")
    return f"{did}: {title}", "\n".join(b)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    lab = sys.argv[1]
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else EVID / lab / "issues"
    out.mkdir(parents=True, exist_ok=True)
    rep = [f"# e2e lab {lab} — verdicts\n", "| case | verdict | when | summary |", "|---|---|---|---|"]
    for d in sorted((EVID / lab).iterdir()):
        v = verdict_line(d) if d.is_dir() else None
        if v:
            rep.append(f"| `{d.name}` | **{v[0]}** | {v[1]} | {v[2][:160].replace('|', '/')} |")
    sv = EVID / "static" / "verdicts.tsv"
    if sv.exists():
        rep.append("\n## Static (level 0)\n")
        for line in read(sv).splitlines():
            k, v, s = line.split("\t", 2)
            rep.append(f"- **{k} → {v}** — {s}")
    (EVID / lab / "report.md").write_text("\n".join(rep) + "\n", encoding="utf-8")
    for did, meta in DEFECTS.items():
        t, body = issue_body(lab, did, meta)
        (out / f"{did}.md").write_text(f"{t}\n\n{body}", encoding="utf-8")
    for did, meta in LATENT.items():
        t, body = issue_body(lab, did, meta, latent=True)
        (out / f"{did}.md").write_text(f"{t}\n\n{body}", encoding="utf-8")
    print(f"report: {EVID / lab / 'report.md'}\nissues: {out} ({len(DEFECTS)} confirmed-class + {len(LATENT)} latent)")


if __name__ == "__main__":
    main()
