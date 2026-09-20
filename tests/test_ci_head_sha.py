"""The CI gate judges the commit that was pushed (#81).

`gh run list --branch <src>` and `merge_requests/<iid>/pipelines` both answer with the
PREVIOUS commit's run for the first seconds after a push, until the platform registers the
new head. dev-finish and review-finish push and gate in the same breath, so the gate read
that older run and could report green over a tree CI never built (observed live in the A5
scenario: the run for `e22efb6` while `1ef97a3` had just been pushed).

The fix is one variable. `common/post-dev-complete.yaml` STOREs `git rev-parse HEAD` right
after each push and every lookup filters on it; `common/check-config.yaml` seeds it empty so
a caller that pushed nothing (a standalone `common/check-mr-ci.yaml`) still reads the
branch's newest run. "No run for THIS sha yet" is an EMPTY answer, which the existing
#49/#64/#74 mapping turns into `running` when the branch defines CI — never into the run
before it.

What this file cannot check: that GitHub treats `--commit ""` as "no filter". That is an API
fact, verified in the lab (`tests/e2e/replay.sh r24`) and against the live API.
"""

import json
import re
import subprocess
import sys

import pytest

from conftest import WORKFLOWS_DIR

CHECK_CONFIG = WORKFLOWS_DIR / "common/check-config.yaml"
POST_DEV = WORKFLOWS_DIR / "common/post-dev-complete.yaml"
GET_PIPELINE = WORKFLOWS_DIR / "common/get-mr-pipeline.yaml"
WAIT_GREEN = WORKFLOWS_DIR / "common/wait-for-green-ci.yaml"

# The GitLab-side filter body: a `python -c` heredoc whose second line reads the sha off
# argv. GitHub needs no body — `--commit` is a flag the API applies.
_FILTER_RE = re.compile(r'python -c "\n(import json, sys\nsha = sys\.argv\[1\][\s\S]*?)\n" "\{head_sha\}"')

# Newest first, the way both APIs list: the run of the commit just pushed is `new`, the one
# the unpinned lookup used to adopt is `old`.
PIPELINES = json.dumps([
    {"id": 2, "sha": "newsha", "status": "running"},
    {"id": 1, "sha": "oldsha", "status": "success"},
])


def code(path):
    """The file without comment lines — a command quoted in prose is not a lookup."""
    return "\n".join(l for l in path.read_text(encoding="utf-8").split("\n")
                     if not l.lstrip().startswith("#"))


def bodies(path):
    return _FILTER_RE.findall(path.read_text(encoding="utf-8"))


def run_filter(body, sha, stdin=PIPELINES):
    out = subprocess.run([sys.executable, "-c", body, sha],
                         input=stdin, capture_output=True, text=True, check=True)
    return out.stdout.strip()


ALL_FILTERS = [(rel, i, b)
               for rel, path in (("common/get-mr-pipeline.yaml", GET_PIPELINE),
                                 ("common/wait-for-green-ci.yaml", WAIT_GREEN))
               for i, b in enumerate(bodies(path))]
IDS = [f"{rel}#{i}" for rel, i, _ in ALL_FILTERS]


class TestTheShaIsCaptured:
    def test_check_config_seeds_it_empty(self):
        """Seeded at the one atomic every entry point INCLUDEs, like lookup_after_create."""
        assert '- SET: { variable: head_sha, value: "" }' in CHECK_CONFIG.read_text(encoding="utf-8")

    def test_every_push_is_followed_by_the_capture(self):
        """A phase that pushes must pin the gate to what it pushed, in that order."""
        lines = POST_DEV.read_text(encoding="utf-8").split("\n")
        pushes = [i for i, l in enumerate(lines) if re.match(r"^\s*- RUN: git push -u origin HEAD\s*$", l)]
        assert pushes, "common/post-dev-complete.yaml no longer pushes HEAD"
        for i in pushes:
            window = "\n".join(lines[i:i + 12])
            assert re.search(r"^\s*- RUN: git rev-parse HEAD\s*$", window, re.M), (
                f"the push at post-dev-complete.yaml:{i + 1} is not followed by a "
                "`git rev-parse HEAD`: the gate after it reads whichever run the platform "
                "lists first, which right after a push is the PREVIOUS commit's"
            )
            assert re.search(r"^\s*STORE: head_sha\s*$", window, re.M), (
                f"the capture after post-dev-complete.yaml:{i + 1} does not STORE head_sha"
            )


class TestEveryLookupIsPinned:
    """Four lookups read a run/pipeline list; none of them may read it unfiltered."""

    @pytest.mark.parametrize("path, rel", [(GET_PIPELINE, "common/get-mr-pipeline.yaml"),
                                           (WAIT_GREEN, "common/wait-for-green-ci.yaml")])
    def test_every_gh_run_list_filters_on_the_commit(self, path, rel):
        text = code(path)
        calls = re.findall(r"gh run list [^\n|]*", text)
        assert calls, f"{rel} no longer calls `gh run list`"
        for call in calls:
            assert '--commit "{head_sha}"' in call, (
                f"{rel}: `{call.strip()}` is not pinned to the pushed commit — "
                "`--branch` alone answers with the previous head's run until Actions "
                "registers this one"
            )

    @pytest.mark.parametrize("path, rel", [(GET_PIPELINE, "common/get-mr-pipeline.yaml"),
                                           (WAIT_GREEN, "common/wait-for-green-ci.yaml")])
    def test_every_mr_pipeline_lookup_carries_the_sha(self, path, rel):
        text = code(path)
        calls = re.findall(r"glab api \"projects/[^\"]*/pipelines\"", text)
        assert calls, f"{rel} no longer lists the MR's pipelines"
        assert len(bodies(path)) == len(calls), (
            f"{rel} lists the MR's pipelines {len(calls)}× but only {len(bodies(path))} of "
            "those lists are filtered on head_sha"
        )

    def test_the_four_lookups_are_all_here(self):
        """Two in get-mr-pipeline (id + status), two in wait-for-green-ci (poll + failure)."""
        assert len(bodies(GET_PIPELINE)) == 2
        assert len(bodies(WAIT_GREEN)) == 2


class TestTheFilterItself:
    """The bodies executed, so the rule is proved and not just spelled."""

    @pytest.mark.parametrize("rel, i, body", ALL_FILTERS, ids=IDS)
    def test_the_pushed_commit_wins(self, rel, i, body):
        """Even when it is not the newest entry in the list."""
        assert run_filter(body, "oldsha") in ("1", "success"), (
            f"{rel} body {i} does not select the pipeline of the sha it was given"
        )

    @pytest.mark.parametrize("rel, i, body", ALL_FILTERS, ids=IDS)
    def test_an_unregistered_sha_is_empty_never_the_previous_run(self, rel, i, body):
        """The whole defect in one row: the answer for a sha with no pipeline yet."""
        got = run_filter(body, "notyet")
        assert got in ("", "none"), (
            f"{rel} body {i} answered '{got}' for a commit that has no pipeline yet — "
            "the empty answer is what check-mr-ci maps to `running`; anything else is the "
            "previous commit's run passing the gate"
        )

    @pytest.mark.parametrize("rel, i, body", ALL_FILTERS, ids=IDS)
    def test_an_empty_sha_falls_back_to_the_newest(self, rel, i, body):
        """A caller that pushed nothing keeps the answer this module always gave."""
        assert run_filter(body, "") in ("2", "running")

    @pytest.mark.parametrize("rel, i, body", ALL_FILTERS, ids=IDS)
    def test_an_empty_list_is_still_the_empty_answer(self, rel, i, body):
        assert run_filter(body, "newsha", stdin="[]") in ("", "none")
