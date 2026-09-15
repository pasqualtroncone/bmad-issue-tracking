"""Both install routes must describe the same module.

Classic installer (`npx bmad-method install --custom-source`, BMM 6.12.0):
  - `.claude-plugin/marketplace.json` at the repo root -> Discovery mode
  - `skills/module.yaml` + `skills/module-help.csv` at the common parent of
    the listed skills -> PluginResolver strategy 1 ("root module files")
  - `--custom-source <repo>/skills` (Direct mode) also finds `skills/module.yaml`
Skills CLI (`npx skills add`, BMAD main / 6.13.0-next):
  - `skills/<skill>/module-manifest.toml`, one per skill

Nothing ties these files together at install time, so this test does.
"""

import csv
import json
import tomllib
from pathlib import Path

import yaml

ROOT = Path(__file__).parent.parent
SKILLS_DIR = ROOT / "skills"
MODULE_YAML = SKILLS_DIR / "module.yaml"
MODULE_HELP = SKILLS_DIR / "module-help.csv"
MARKETPLACE = ROOT / ".claude-plugin" / "marketplace.json"

# tools/installer/modules/module-help-schema.js in bmad-method 6.12.0
CANONICAL_HELP_HEADER = [
    "module", "skill", "display-name", "menu-code", "description", "action",
    "args", "phase", "preceded-by", "followed-by", "required",
    "output-location", "outputs",
]


def _skill_dirs():
    return sorted(p for p in SKILLS_DIR.iterdir() if (p / "SKILL.md").is_file())


def _manifests():
    return {p.name: tomllib.loads((p / "module-manifest.toml").read_text()) for p in _skill_dirs()}


def _module_yaml():
    return yaml.safe_load(MODULE_YAML.read_text())


def _marketplace_plugin():
    data = json.loads(MARKETPLACE.read_text())
    assert len(data["plugins"]) == 1, "one module, one plugin"
    return data["plugins"][0]


def test_every_skill_ships_a_manifest():
    for skill in _skill_dirs():
        assert (skill / "module-manifest.toml").is_file(), f"{skill.name} lacks module-manifest.toml"


def test_module_code_is_the_same_on_both_routes():
    code = _module_yaml()["code"]
    assert _marketplace_plugin()["name"] == code
    for name, manifest in _manifests().items():
        assert manifest["module"] == code, f"{name}/module-manifest.toml declares module={manifest['module']!r}, expected {code!r}"


def test_version_is_the_same_everywhere():
    version = str(_module_yaml()["version"])
    assert _marketplace_plugin()["version"] == version, "marketplace.json version drifted from skills/module.yaml"
    for name, manifest in _manifests().items():
        assert manifest["version"] == version, f"{name}/module-manifest.toml version {manifest['version']!r} != {version!r}"


def test_marketplace_lists_exactly_the_shipped_skills():
    listed = {Path(p).name for p in _marketplace_plugin()["skills"]}
    shipped = {p.name for p in _skill_dirs()}
    assert listed == shipped
    for rel in _marketplace_plugin()["skills"]:
        assert (ROOT / rel / "SKILL.md").is_file(), f"{rel} is not a skill folder"


def test_module_help_uses_the_6_12_canonical_header():
    with MODULE_HELP.open(newline="") as fh:
        rows = list(csv.reader(fh))
    assert rows[0] == CANONICAL_HELP_HEADER, "installer warns on header drift and falls through positionally"
    body = rows[1:]
    assert len(body) >= 1
    for row in body:
        assert len(row) == len(CANONICAL_HELP_HEADER), f"row has {len(row)} fields: {row[:3]}"


def test_module_help_rows_match_shipped_skills():
    with MODULE_HELP.open(newline="") as fh:
        rows = list(csv.DictReader(fh))
    shipped = {p.name for p in _skill_dirs()}
    assert {r["skill"] for r in rows} == shipped, "every skill gets one help row, no more"
    codes = [r["menu-code"] for r in rows]
    assert len(codes) == len(set(codes)), f"menu codes must be unique: {codes}"
    module_name = _module_yaml()["name"]
    for r in rows:
        assert r["module"] == module_name, "help rows are grouped under the module display name"
        assert r["description"].strip(), f"{r['skill']} has an empty description"
