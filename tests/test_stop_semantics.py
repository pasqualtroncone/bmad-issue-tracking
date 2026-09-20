"""STOP is a RETURN to the INCLUDE caller, never a halt of the whole run (#60).

Two headless interpreters read the same `- STOP` two different ways in 2026-09 level-2
runs: one returned to the caller, the other ended the entire sync at
`common/find-prd-key.yaml`. The spec now says which one is right (lang section 2.10) —
these checks keep the workflow files inside that reading:

- a file that returns must HAVE a caller: every STOP-bearing file is INCLUDEd by another
  workflow and is never an entry workflow named by a TOML override, where "return to the
  caller" means nothing and the step can only be read as "halt";
- a STOP is always a branch step: an unconditional `- STOP` at column 0 makes every step
  after it dead, and is exactly the shape that reads as a whole-run halt. The run-ending
  case is `OUTPUT ... stop: true`;
- the spec keeps saying so, so the files and the language cannot drift apart again.
"""

import re
from pathlib import Path

import pytest
from conftest import WORKFLOWS_DIR, collect_includes

CUSTOM_DIR = WORKFLOWS_DIR.parent / "custom"
LANG_SPEC = WORKFLOWS_DIR.parent / "bmad-workflow-lang.md"

STOP_RE = re.compile(r"^(\s*)- STOP\s*$")


def stop_sites():
    """[(rel, 1-based line, indent)] for every `- STOP` step in the deployed workflows."""
    sites = []
    for path in sorted(WORKFLOWS_DIR.rglob("*.yaml")):
        rel = str(path.relative_to(WORKFLOWS_DIR))
        for n, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
            m = STOP_RE.match(line)
            if m:
                sites.append((rel, n, len(m.group(1))))
    return sites


def entry_workflows():
    """Workflow paths a TOML override points at — the files nothing INCLUDEs."""
    entries = set()
    for toml in sorted(CUSTOM_DIR.glob("*.toml")):
        for m in re.finditer(r"workflows/([a-z0-9/-]+)", toml.read_text(encoding="utf-8")):
            entries.add(m.group(1) + ".yaml")
    return entries


def included_targets(all_workflows):
    """Every path reached through `INCLUDE:` from any workflow file."""
    targets = set()
    for wf in all_workflows.values():
        for t in collect_includes(wf):
            targets.add(t if t.endswith(".yaml") else t + ".yaml")
    return targets


class TestStopIsAReturn:
    def test_there_are_stop_sites(self):
        """A guard on the guard: these checks are vacuous if the grep stops matching."""
        assert stop_sites(), "no `- STOP` step found — has the step syntax changed?"

    def test_entry_workflows_never_stop(self):
        """An entry workflow has no INCLUDE caller, so STOP there can only mean 'halt'."""
        entries = entry_workflows()
        assert entries, "no entry workflow found in assets/custom/*.toml"
        bad = [f"{rel}:{n}" for rel, n, _ in stop_sites() if rel in entries]
        assert not bad, (
            "STOP in an entry workflow (nothing INCLUDEs it, so there is no caller to "
            f"return to; end a run with `OUTPUT ... stop: true` instead): {bad}"
        )

    def test_stop_bearing_files_have_a_caller(self, all_workflows):
        """Every file that returns is reached through an INCLUDE."""
        targets = included_targets(all_workflows)
        orphans = sorted({rel for rel, _, _ in stop_sites() if rel not in targets})
        assert not orphans, (
            "STOP in a file no workflow INCLUDEs — nothing would resume after the "
            f"return: {orphans}"
        )

    def test_stop_is_always_a_branch_step(self):
        """A column-0 `- STOP` is unconditional: everything after it is dead code."""
        bad = [f"{rel}:{n}" for rel, n, indent in stop_sites() if indent == 0]
        assert not bad, (
            "unconditional `- STOP` at the top level of a file (every step after it is "
            f"unreachable; guard it with a CHECK, or use `OUTPUT ... stop: true`): {bad}"
        )


class TestNoStopSitsOnADeadBranch:
    """A STOP the interpreter can never reach is not a return — it is noise (#78)."""

    def test_create_issue_adopt_path_is_one_branch(self):
        text = (WORKFLOWS_DIR / "common/create-issue.yaml").read_text(encoding="utf-8")
        adopt = text.split("- CHECK: empty found_issue_id", 1)[1].split("\n# Create the issue", 1)[0]
        assert "empty issue_id" not in adopt, (
            "common/create-issue.yaml branches on `empty issue_id` right after SETting it "
            "from a found_issue_id the enclosing CHECK proved non-empty: the branch cannot "
            "execute, and its STOP counts as a live return site that is not one"
        )
        assert adopt.count("- STOP") == 1, (
            f"the adopt path must return exactly once, found {adopt.count('- STOP')}"
        )


@pytest.fixture(scope="module")
def spec():
    return LANG_SPEC.read_text(encoding="utf-8")


class TestLangSpecDefinesStopAsAReturn:
    def test_section_2_10_says_return_not_halt(self, spec):
        body = spec.split("### 2.10 STOP", 1)[1].split("### 2.11", 1)[0]
        assert "returns to the caller" in body.lower() or "return to the caller" in body.lower(), (
            "lang section 2.10 no longer defines STOP as a return to the INCLUDE caller"
        )
        assert "halts workflow execution immediately" not in body.lower(), (
            "lang section 2.10 is back to the reading that killed the sync in scenario A3"
        )

    def test_section_2_5_owns_the_whole_run_halt(self, spec):
        body = spec.split("### 2.5 OUTPUT", 1)[1].split("### 2.6", 1)[0]
        assert "ENTIRE run halts" in body, (
            "lang section 2.5 no longer states that `stop: true` ends the whole run"
        )

    def test_section_2_1_tells_the_caller_what_a_stop_does(self, spec):
        body = spec.split("### 2.1 INCLUDE", 1)[1].split("### 2.2", 1)[0]
        assert "STOP" in body and "section 2.10" in body, (
            "lang section 2.1 no longer says what a STOP inside the included file does"
        )
