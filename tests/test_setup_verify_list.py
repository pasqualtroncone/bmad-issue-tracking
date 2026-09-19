"""The setup skill's per-file verify lists must name exactly the files it deploys.

skills/bmad-issue-tracking-setup/SKILL.md step 2 lists every TOML override and
step 3 every workflow YAML the consumer must end up with. The setup skill's own
verify step stays green when the list is stale, so the consumer silently misses
files (four common/ MR atomics shipped that way). These tests pin both lists,
and the README override table, to what assets/ actually ships.

Matching is scoped to the step blocks and to bullet lines: prose elsewhere in
SKILL.md legitimately names the same files (step 4 mentions bmad-build-auto.toml)
and README prose names retired ones (bmad-create-ux-design.toml).
"""

import re
from pathlib import Path

ROOT = Path(__file__).parent.parent
SETUP = ROOT / "skills" / "bmad-issue-tracking-setup"
SKILL_MD = (SETUP / "SKILL.md").read_text()
README = (ROOT / "README.md").read_text()
ASSETS = SETUP / "assets"


def _step(n):
    m = re.search(rf'<step n="{n}".*?</step>', SKILL_MD, re.S)
    assert m, f"SKILL.md has no <step n=\"{n}\">"
    return m.group(0)


def _shipped_tomls():
    return {p.name for p in (ASSETS / "custom").glob("*.toml")}


def _shipped_workflows():
    return {str(p.relative_to(ASSETS / "workflows")) for p in (ASSETS / "workflows").rglob("*.yaml")}


def test_no_yml_spelling_hides_a_workflow_from_these_checks():
    assert list((ASSETS / "workflows").rglob("*.yml")) == [], "use .yaml; the deploy and these tests only look for .yaml"


def test_step2_lists_every_shipped_toml_override():
    listed = set(re.findall(r"^- `(bmad-[a-z0-9-]+\.toml)`", _step(2), re.M))
    shipped = _shipped_tomls()
    assert shipped - listed == set(), f"TOML shipped but not in the step 2 list: {sorted(shipped - listed)}"
    assert listed - shipped == set(), f"TOML in the step 2 list but not shipped: {sorted(listed - shipped)}"


def test_step3_lists_every_shipped_workflow():
    step3 = _step(3)
    listed = set(re.findall(r"^- `_bmad/_config/custom/workflows/([^`]+\.yaml)`", step3, re.M))
    shipped = _shipped_workflows()
    assert shipped - listed == set(), f"workflow shipped but not in the step 3 list: {sorted(shipped - listed)}"
    assert listed - shipped == set(), f"workflow in the step 3 list but not shipped: {sorted(listed - shipped)}"
    assert "- `_bmad/_config/custom/bmad-workflow-lang.md`" in step3
    assert (ASSETS / "bmad-workflow-lang.md").is_file()


def test_readme_override_table_has_one_row_per_shipped_toml():
    m = re.search(r"^### TOML overrides \(via setup\)\n(.*?)^### ", README, re.S | re.M)
    assert m, "README lacks the '### TOML overrides (via setup)' section"
    rows = set(re.findall(r"^\| `(bmad-[a-z0-9-]+\.toml)` \|", m.group(1), re.M))
    shipped = _shipped_tomls()
    assert shipped - rows == set(), f"TOML shipped but missing from the README override table: {sorted(shipped - rows)}"
    assert rows - shipped == set(), f"README override table row for a TOML that is not shipped: {sorted(rows - shipped)}"
