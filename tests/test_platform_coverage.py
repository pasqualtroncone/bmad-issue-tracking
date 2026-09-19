"""Validate that platform-specific RUN steps have correct CLI/platform pairing.

P1 — checks that glab commands run on PLATFORM:gitlab and gh on PLATFORM:github.
Does NOT recurse into branches (same limitation as variable flow).

TestGitPlatformSelection adds the other half: which of the two selection channels a step
is allowed to use. `PLATFORM:` is the ISSUE TRACKER's channel; a step that talks to the
GIT REMOTE (MR/PR, CI) is selected by `CHECK: git_platform eq ...` and carries no
annotation. It recurses (raw-line scan), so it does see the nested poll RUNs.
"""

import re

import pytest
import conftest
from conftest import load_all_workflows, get_step_field, flatten_steps


class TestPlatformCoverage:
    """P1: glab commands on PLATFORM:gitlab, gh on PLATFORM:github."""

    @pytest.mark.parametrize("rel, wf", list(load_all_workflows().items()), ids=lambda x: x[0] if isinstance(x, tuple) else str(x))
    def test_platform_runs_balanced(self, rel, wf):
        """Top-level PLATFORM-annotated RUNs must pair glab with gitlab and gh with github."""
        glab_gitlab = 0
        gh_github = 0
        glab_github = 0
        gh_gitlab = 0

        for step in flatten_steps(wf["steps"]):
            if step["type"] != "RUN":
                continue
            platform = None
            # a step may open with shell options (`set -o pipefail; gh api … | …`,
            # find-issue.yaml) — the CLI that follows is still what must match PLATFORM
            cmd = step["raw_value"].strip().removeprefix("set -o pipefail;")
            for _, key, value in step["block"]:
                if key == "PLATFORM":
                    platform = value
            if platform is None:
                continue
            if cmd.strip().startswith("glab ") and platform == "gitlab":
                glab_gitlab += 1
            elif cmd.strip().startswith("glab ") and platform == "github":
                glab_github += 1
            elif cmd.strip().startswith("gh ") and platform == "github":
                gh_github += 1
            elif cmd.strip().startswith("gh ") and platform == "gitlab":
                gh_gitlab += 1

        errors = []
        if glab_github:
            errors.append(f"glab on PLATFORM:github ({glab_github}x)")
        if gh_gitlab:
            errors.append(f"gh on PLATFORM:gitlab ({gh_gitlab}x)")

        if errors:
            pytest.fail(f"{rel}: {', '.join(errors)}")


# The rule the workflows follow (bmad-workflow-lang.md §2.4, CLAUDE.md "Platform
# differences"): `PLATFORM:` compares against `platform`, the ISSUE TRACKER, so it may
# only annotate tracker steps. A step that talks to the GIT REMOTE (MR/PR, CI) carries no
# annotation and is selected by `CHECK: git_platform eq "gitlab"`.
#
# The checks below scan the raw YAML lines instead of conftest's step tree on purpose: the
# parser drops steps nested LOOP→CHECK→RUN (S9), and the poll RUNs of wait-for-green-ci —
# the ones whose stray `PLATFORM:` is what this rule exists to forbid — live exactly there.

CLI_RUN_RE = re.compile(r"^(\s*)- RUN: (?:set -o pipefail; )?(gh|glab) ")
CHECK_LINE_RE = re.compile(r"^(\s*)- CHECK: (.+)$")
STEP_FIELD_RE = re.compile(r"^\s+(STORE|PLATFORM|EXPECT_EXIT|CAPTURE):\s*(.*)$")


def cli_runs(rel):
    """[(line, cli, platform, enclosing_checks)] for every gh/glab RUN in the file.

    `enclosing_checks` is every `- CHECK:` this RUN sits inside — walking backwards and
    up, one per indent level, innermost first. `ensure-mr` nests the CLI choice outside a
    `mr_draft` CHECK, so only the innermost one would miss it.
    """
    lines = (conftest.WORKFLOWS_DIR / rel).read_text(encoding="utf-8").split("\n")
    out = []
    for i, line in enumerate(lines):
        m = CLI_RUN_RE.match(line)
        if not m:
            continue
        indent, cli = len(m.group(1)), m.group(2)
        platform = None
        for nxt in lines[i + 1:]:
            f = STEP_FIELD_RE.match(nxt)
            if f:
                if f.group(1) == "PLATFORM":
                    platform = f.group(2).strip()
                continue
            if nxt.lstrip().startswith("- "):
                break
        checks, level = [], indent
        for prev in reversed(lines[:i]):
            c = CHECK_LINE_RE.match(prev)
            if c and len(c.group(1)) < level:
                checks.append(c.group(2).strip())
                level = len(c.group(1))
                if level == 0:
                    break
        out.append((i + 1, cli, platform, checks))
    return out


ALL_RELS = sorted(load_all_workflows().keys())

# Tracker atomics that exist on one platform only, with the reason. GitHub has no issue
# boards (it has Projects), so ensure-board is GitLab-only by design and its header says so.
SINGLE_CLI_BY_DESIGN = {"common/ensure-board.yaml"}


class TestGitPlatformSelection:
    """A gh/glab RUN is selected either by PLATFORM: (tracker) or by a git_platform CHECK."""

    @pytest.mark.parametrize("rel", ALL_RELS)
    def test_unannotated_cli_runs_sit_under_a_git_platform_check(self, rel):
        bad = [
            f"{rel}:{ln} `{cli}` has no PLATFORM: and no enclosing git_platform CHECK "
            f"(branches: {' / '.join(checks) or '(none)'})"
            for ln, cli, platform, checks in cli_runs(rel)
            if platform is None and not any("git_platform" in c for c in checks)
        ]
        if bad:
            pytest.fail(
                "a gh/glab RUN must be selected by PLATFORM: (issue tracker) or by an "
                "enclosing `CHECK: git_platform ...` (git remote):\n  " + "\n  ".join(bad)
            )

    @pytest.mark.parametrize("rel", ALL_RELS)
    def test_git_platform_branches_carry_no_platform_annotation(self, rel):
        bad = [
            f"{rel}:{ln} `{cli}` inside `CHECK: {checks[-1]}` also carries "
            f"PLATFORM: {platform}"
            for ln, cli, platform, checks in cli_runs(rel)
            if platform is not None and any("git_platform" in c for c in checks)
        ]
        if bad:
            pytest.fail(
                "a step already selected by git_platform must not also be filtered by "
                "PLATFORM: (which compares against the issue tracker and would skip it on "
                "a cross-platform setup):\n  " + "\n  ".join(bad)
            )

    @pytest.mark.parametrize("rel", ALL_RELS)
    def test_cli_runs_have_a_sibling_on_the_other_platform(self, rel):
        """Whichever channel selects them, gh and glab come in pairs within a file.

        File-level, like test_platform_runs_balanced: an atomic that learned to speak one
        CLI and not the other is the shape every platform-coverage defect has taken. This
        is the guarantee the PLATFORM-pairing test used to give for the MR/CI atomics,
        which no longer carry a PLATFORM: annotation to pair with.
        """
        if rel in SINGLE_CLI_BY_DESIGN:
            pytest.skip(f"{rel} is single-platform by design (see its header)")
        clis = {cli for _ln, cli, _p, _c in cli_runs(rel)}
        if clis and clis != {"gh", "glab"}:
            only = clis.pop()
            other = "glab" if only == "gh" else "gh"
            pytest.fail(f"{rel}: only `{only}` RUN steps; no `{other}` sibling")
