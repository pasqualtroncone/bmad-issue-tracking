"""The setup skill's per-file verify list must name exactly the files it deploys.

skills/bmad-issue-tracking-setup/SKILL.md (steps 2 and 3) lists every TOML
override and workflow YAML the consumer must end up with. The setup skill's own verify step stays
green when the list is stale, so the consumer silently misses files (four
common/ MR atomics shipped that way). This test pins the list to assets/.
"""

import re
from pathlib import Path

SETUP = Path(__file__).parent.parent / "skills" / "bmad-issue-tracking-setup"
SKILL_MD = (SETUP / "SKILL.md").read_text()
ASSETS = SETUP / "assets"

WORKFLOW_ENTRY = re.compile(r"`_bmad/_config/custom/workflows/([^`]+\.yaml)`")
TOML_ENTRY = re.compile(r"`_bmad/custom/(bmad-[^`]+\.toml)`|`(bmad-[a-z0-9-]+\.toml)`")


def test_verify_list_names_every_shipped_workflow():
    listed = set(WORKFLOW_ENTRY.findall(SKILL_MD))
    shipped = {str(p.relative_to(ASSETS / "workflows")) for p in (ASSETS / "workflows").rglob("*.yaml")}
    assert shipped - listed == set(), f"shipped but not in the SKILL.md verify list: {sorted(shipped - listed)}"
    assert listed - shipped == set(), f"in the SKILL.md verify list but not shipped: {sorted(listed - shipped)}"


def test_verify_list_names_every_shipped_toml_override():
    listed = {a or b for a, b in TOML_ENTRY.findall(SKILL_MD)}
    shipped = {p.name for p in (ASSETS / "custom").glob("*.toml")}
    assert shipped - listed == set(), f"TOML shipped but not listed: {sorted(shipped - listed)}"
    assert listed - shipped == set(), f"TOML listed but not shipped: {sorted(listed - shipped)}"
