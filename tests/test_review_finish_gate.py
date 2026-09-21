"""The CI gate may never run before the MR it is supposed to read.

`common/wait-for-green-ci` gates on the MR's pipeline, so a phase that gates
without ensuring the MR first reads nothing: `common/check-mr-ci` maps `no_mr`,
`common/write-ci-status` writes green, and bmad-loop's `[verify]` passes over a
pipeline nobody looked at — a red one included.

#79 (D29) fixed that for the dev-finish phase. #95 (D38) is the same defect on
review-finish, which is the ONLY phase bmad-loop ever reaches: `bmad-build-auto`
finalises dev and review in one session, so the hook fires once with the spec
already `done`. These tests pin the ORDER for every phase at once, so the next
phase that grows a CI gate cannot ship without its MR.
"""

from conftest import load_workflow, flatten_steps

WF = "common/post-dev-complete.yaml"
GATE = "common/wait-for-green-ci"
MR = "common/ensure-mr"


def _includes(steps):
    """(file line, target) for every INCLUDE at any depth, in file order."""
    out = [
        (s["start_line"], s["raw_value"].strip())
        for s in flatten_steps(steps)
        if s["type"] == "INCLUDE"
    ]
    return sorted(out)


def _phase_blocks(wf):
    """{phase value: the steps of its `CHECK: phase eq "..."` TRUE branch}."""
    blocks = {}
    for step in wf["steps"]:
        if step["type"] != "CHECK":
            continue
        raw = step["raw_value"]
        if not raw.startswith("phase eq "):
            continue
        blocks[raw.split('"')[1]] = step.get("children", {}).get("TRUE", [])
    return blocks


def _blocks_containing_gate(steps):
    """The innermost CHECK branches that hold a wait-for-green-ci INCLUDE."""
    found = []
    for step in steps:
        for branch in step.get("children", {}).values():
            deeper = _blocks_containing_gate(branch)
            if deeper:
                found.extend(deeper)
            elif any(
                s["type"] == "INCLUDE" and s["raw_value"].strip() == GATE
                for s in flatten_steps(branch)
            ):
                found.append((step["raw_value"], branch))
    return found


def test_every_phase_ensures_the_mr_before_gating_on_ci():
    """No phase may INCLUDE wait-for-green-ci without an earlier ensure-mr."""
    wf = load_workflow(WF)
    blocks = _phase_blocks(wf)
    assert set(blocks) == {"create-story", "dev-finish", "review-finish"}, (
        f"unexpected phases in {WF}: {sorted(blocks)}"
    )
    gating = []
    for phase, steps in sorted(blocks.items()):
        includes = _includes(steps)
        gates = [line for line, target in includes if target == GATE]
        if not gates:
            continue
        gating.append(phase)
        mrs = [line for line, target in includes if target == MR]
        assert mrs, f"phase {phase} gates on CI at line {gates[0] + 1} but never INCLUDEs {MR}"
        for gate_line in gates:
            earlier = [line for line in mrs if line < gate_line]
            assert earlier, (
                f"phase {phase}: {GATE} at line {gate_line + 1} is not preceded by "
                f"{MR} (ensure-mr lines: {[l + 1 for l in mrs]}). With no MR the gate "
                f"reads nothing, check-mr-ci maps no_mr and write-ci-status writes green"
            )
    assert gating == ["dev-finish", "review-finish"], (
        f"the CI-gating phases changed: {gating}"
    )


def test_the_gate_and_its_ensure_mr_share_the_same_guard():
    """ensure-mr must sit INSIDE the block that gates, not on some other path.

    A `CHECK` above the gate's own guard would leave the review-finish gate
    ungated again on every run whose verdict is not `done` — and, worse, would
    let a refactor move the two apart without any test noticing.
    """
    wf = load_workflow(WF)
    for phase, steps in sorted(_phase_blocks(wf).items()):
        for condition, branch in _blocks_containing_gate(steps):
            includes = _includes(branch)
            gates = [line for line, target in includes if target == GATE]
            mrs = [line for line, target in includes if target == MR]
            for gate_line in gates:
                assert any(line < gate_line for line in mrs), (
                    f"phase {phase}, block `{condition}`: {GATE} at line "
                    f"{gate_line + 1} has no {MR} in the same block before it"
                )


def test_review_finish_gate_is_guarded_by_the_done_verdict():
    """The review-finish gate still runs only when the review verdict is `done`."""
    wf = load_workflow(WF)
    conditions = [
        condition
        for condition, _ in _blocks_containing_gate(_phase_blocks(wf)["review-finish"])
    ]
    assert conditions == ['review_status eq "done"'], (
        f"review-finish gates under {conditions}, not the review verdict"
    )
