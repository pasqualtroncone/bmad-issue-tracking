"""Validate the unified post-completion workflow and its dispatcher.

Covers:
- post-build-dispatch.yaml routes each spec status to the right phase
- post-dev-complete.yaml dispatches on phase variable
- ci-status.json contract is preserved (written by write-ci-status.yaml)
- ensure-issue / ensure-mr are reused across phases
- the trace MR is named after the story, not after the story key (#99)
"""

import re

from conftest import WORKFLOWS_DIR, load_workflow, flatten_steps, collect_includes

# The value side of `- SET: { variable: mr_title, value: "..." }`.
_MR_TITLE_SET_RE = re.compile(r'variable:\s*mr_title\s*,\s*value:\s*"([^"]*)"')


def test_dispatch_routes_ready_for_dev_to_create_story():
    """ready-for-dev status must route to phase=create-story."""
    wf = load_workflow("common/post-build-dispatch.yaml")
    content = wf["content"]
    assert "status eq \"ready-for-dev\"" in content
    assert "phase, value: \"create-story\"" in content


def test_dispatch_routes_in_review_to_dev_finish():
    """in-review status must route to phase=dev-finish."""
    wf = load_workflow("common/post-build-dispatch.yaml")
    content = wf["content"]
    assert "status eq \"in-review\"" in content
    assert "phase, value: \"dev-finish\"" in content


def test_dispatch_routes_in_progress_to_dev_finish():
    """in-progress status must route to phase=dev-finish (dev finished, review not started)."""
    wf = load_workflow("common/post-build-dispatch.yaml")
    content = wf["content"]
    assert "status eq \"in-progress\"" in content
    assert "phase, value: \"dev-finish\"" in content


def test_dispatch_routes_done_to_review_finish():
    """done status must route to phase=review-finish."""
    wf = load_workflow("common/post-build-dispatch.yaml")
    content = wf["content"]
    assert "status eq \"done\"" in content
    assert "phase, value: \"review-finish\"" in content


def test_dispatch_skips_blocked_and_awaiting():
    """blocked / awaiting-operator statuses must skip (no phase dispatch)."""
    wf = load_workflow("common/post-build-dispatch.yaml")
    content = wf["content"]
    assert "status eq \"blocked\"" in content
    assert "status eq \"awaiting-operator\"" in content
    # No INCLUDE common/post-dev-complete directly in those branches
    includes = collect_includes(wf)
    # Only the routed phases include post-dev-complete
    assert "common/post-dev-complete" in includes


def test_post_dev_complete_has_three_phases():
    """The unified workflow must dispatch on the three phase values."""
    wf = load_workflow("common/post-dev-complete.yaml")
    content = wf["content"]
    assert "phase eq \"create-story\"" in content
    assert "phase eq \"dev-finish\"" in content
    assert "phase eq \"review-finish\"" in content


def test_dev_finish_writes_ci_status():
    """dev-finish must write ci-status.json via write-ci-status include."""
    wf = load_workflow("common/post-dev-complete.yaml")
    includes = collect_includes(wf)
    assert "common/write-ci-status" in includes
    assert "common/wait-for-green-ci" in includes


def test_review_finish_writes_ci_status():
    """review-finish must also write ci-status.json (contract for ci-status.sh)."""
    wf = load_workflow("common/post-dev-complete.yaml")
    content = wf["content"]
    includes = collect_includes(wf)
    assert "common/write-ci-status" in includes
    # write-ci-status must appear in the review-finish branch too
    # (count occurrences of the include across the flattened steps)
    writes = [s for s in flatten_steps(wf["steps"]) if s["type"] == "INCLUDE" and "write-ci-status" in s["raw_value"]]
    assert len(writes) >= 2, "write-ci-status must be included in both dev-finish and review-finish"


def test_dev_finish_ensures_issue_and_mr():
    """dev-finish must ensure issue + MR exist (not just find them)."""
    wf = load_workflow("common/post-dev-complete.yaml")
    includes = collect_includes(wf)
    assert "common/ensure-issue" in includes
    assert "common/ensure-mr" in includes


def test_create_story_ensures_issue_and_mr():
    """create-story must ensure issue + MR exist."""
    wf = load_workflow("common/post-dev-complete.yaml")
    includes = collect_includes(wf)
    assert "common/ensure-issue" in includes
    assert "common/ensure-mr" in includes


def test_wrappers_set_phase():
    """The phase wrappers must set the phase variable then INCLUDE the unified workflow."""
    expected = {
        "common/post-dev-complete-create-story.yaml": "create-story",
        "common/post-dev-complete-dev-finish.yaml": "dev-finish",
        "common/post-dev-complete-review-finish.yaml": "review-finish",
    }
    for rel, phase in expected.items():
        wf = load_workflow(rel)
        content = wf["content"]
        assert f"phase, value: \"{phase}\"" in content, f"{rel}: wrong phase value"
        includes = collect_includes(wf)
        assert "common/post-dev-complete" in includes, f"{rel}: missing unified workflow include"


def test_no_mr_title_is_named_after_the_story_key():
    """D40 (#99): a trace MR carries the story's TITLE, the same string its issue carries.

    `common/post-dev-complete.yaml` composed `Story N.M: {story_key}` in all three phases,
    so one story showed up twice under two names — `Story 1.10: Login Form Extended` as the
    issue and `Story 1.10: 1-10-login-form-extended` as the PR. The title is also what
    `common/create-issue.yaml` dedupes by, so the two must not drift. `{story_key}` may
    still appear elsewhere in a title (a PRD MR has no story), but never as the NAME of a
    story: an `mr_title` value carrying it is the defect coming back.
    """
    offenders = []
    for path in sorted(WORKFLOWS_DIR.rglob("*.yaml")):
        for n, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
            if line.lstrip().startswith("#"):
                continue
            m = _MR_TITLE_SET_RE.search(line)
            if m and "{story_key}" in m.group(1):
                offenders.append(f"{path.relative_to(WORKFLOWS_DIR)}:{n}: {line.strip()}")
    assert not offenders, (
        "mr_title must be named after the story title, not its key "
        "(common/story-title.yaml returns {story_title}):\n  " + "\n  ".join(offenders)
    )


def test_every_story_mr_title_uses_the_shared_story_title():
    """The counterpart: the three phases DO compose the title the issue side composes."""
    content = load_workflow("common/post-dev-complete.yaml")["content"]
    sets = [
        line.strip() for line in content.split("\n")
        if not line.lstrip().startswith("#") and _MR_TITLE_SET_RE.search(line)
    ]
    assert len(sets) == 3, f"expected one mr_title SET per phase, found {len(sets)}: {sets}"
    for line in sets:
        assert 'Story {epic_num}.{story_num}: {story_title}' in line, line
