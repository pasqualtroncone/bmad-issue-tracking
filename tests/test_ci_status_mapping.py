"""The pipeline-state -> ci_status table (#74).

Every state the mapping did not NAME fell through to `no_ci`, which the gate reads as
green: GitLab answers `created` for the first seconds of an MR pipeline, and a `canceled`
or `timed_out` run ended the gate green the same way. The table now enumerates the states
both APIs can answer and sends anything unnamed to `running`, so an unknown string costs
wall clock and never a false green.

The table lives in three places — `common/check-mr-ci.yaml` and the two poll rounds of
`common/wait-for-green-ci.yaml` — because a poll round is one bash RUN and cannot INCLUDE
a workflow atomic. The copies are therefore kept BYTE FOR BYTE identical and this test is
what keeps them so; only the caller's argument differs (the answer for an empty listing).
"""

import re
import subprocess
import sys
from pathlib import Path

import pytest

WORKFLOWS = Path(__file__).parent.parent / "skills/bmad-issue-tracking-setup/assets/workflows"
CHECK_MR_CI = WORKFLOWS / "common/check-mr-ci.yaml"
WAIT_FOR_GREEN = WORKFLOWS / "common/wait-for-green-ci.yaml"

# The mapper body: a `python -c` heredoc that starts at the `ps = sys.argv[1]` line and
# ends at the closing quote in column 0.
_BODY_RE = re.compile(r'python -c "\n(import sys\nps = sys\.argv\[1\][\s\S]*?)\n"')


def bodies(path):
    return _BODY_RE.findall(path.read_text(encoding="utf-8"))


def run_map(body, state, none_is="no_run"):
    out = subprocess.run([sys.executable, "-c", body, state, none_is],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


@pytest.fixture(scope="module")
def mapper():
    found = bodies(CHECK_MR_CI)
    assert len(found) == 1, f"check-mr-ci.yaml holds {len(found)} mapping bodies, want 1"
    return found[0]


class TestTheThreeCopiesAreOne:
    def test_wait_for_green_has_both_rounds(self):
        assert len(bodies(WAIT_FOR_GREEN)) == 2, (
            "wait-for-green-ci.yaml must carry the mapping in both poll rounds"
        )

    def test_all_three_copies_are_identical(self, mapper):
        for i, body in enumerate(bodies(WAIT_FOR_GREEN)):
            assert body == mapper, (
                f"poll round {i + 1} of wait-for-green-ci.yaml has drifted from "
                "check-mr-ci.yaml's table; the three copies must stay byte-identical"
            )


class TestTheTable:
    """One row per state, so a future edit has to state which verdict it is changing."""

    @pytest.mark.parametrize("state", [
        "created", "waiting_for_resource", "preparing", "pending", "running",
        "scheduled", "queued", "waiting", "requested", "in_progress",
    ])
    def test_pre_run_and_in_flight_states_are_running(self, mapper, state):
        assert run_map(mapper, state) == "running"

    @pytest.mark.parametrize("state", [
        "failed", "failure", "canceled", "cancelled", "timed_out", "stale",
        "action_required", "startup_failure", "manual",
    ])
    def test_failed_and_parked_states_are_failed(self, mapper, state):
        assert run_map(mapper, state) == "failed"

    @pytest.mark.parametrize("state", ["success", "skipped", "neutral"])
    def test_success_and_skipped_are_passed(self, mapper, state):
        """A skipped or neutral run is not a red one; a success with skipped jobs is
        reported as `success` by both APIs, so it needs no row of its own."""
        assert run_map(mapper, state) == "passed"

    @pytest.mark.parametrize("state", ["none", ""])
    def test_only_an_empty_listing_takes_the_callers_answer(self, mapper, state):
        assert run_map(mapper, state, "no_run") == "no_run"
        assert run_map(mapper, state, "no_ci") == "no_ci"
        assert run_map(mapper, state, "running") == "running"

    @pytest.mark.parametrize("state", ["unreadable", "banana", "SUCCESS", "completed"])
    def test_an_unnamed_state_is_never_green(self, mapper, state):
        assert run_map(mapper, state) == "running"

    def test_no_state_falls_through_to_no_ci(self, mapper):
        """`no_ci` is the caller's answer for an empty listing, never the table's."""
        for state in ("created", "manual", "canceled", "skipped", "banana"):
            assert run_map(mapper, state, "no_ci") != "no_ci", (
                f"'{state}' still reaches the caller's CI-less answer"
            )


class TestCheckMrCiPassesTheRightAnswer:
    def test_empty_ci_status_is_set_from_ci_defined(self):
        text = CHECK_MR_CI.read_text(encoding="utf-8")
        assert 'CHECK: ci_defined eq "true"' in text
        assert '- SET: { variable: empty_ci_status, value: "running" }' in text
        assert '- SET: { variable: empty_ci_status, value: "no_ci" }' in text
        assert '" "{pipeline_status}" "{empty_ci_status}"' in text

    def test_poll_rounds_answer_no_run_for_an_empty_listing(self):
        text = WAIT_FOR_GREEN.read_text(encoding="utf-8")
        assert text.count('" "$pipeline_status" no_run)') == 2, (
            "both poll rounds must pass `no_run` as the empty-listing answer: the "
            "initial check has already proved the branch defines CI"
        )
