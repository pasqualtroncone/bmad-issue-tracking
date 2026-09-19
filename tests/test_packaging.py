"""Both install routes must describe the same module.

Classic installer (`npx bmad-method install --custom-source`, BMM 6.12.0):
  - `.claude-plugin/marketplace.json` at the repo root -> Discovery mode
  - `skills/module.yaml` + `skills/module-help.csv` at the common parent of
    the listed skills -> PluginResolver strategy 1 ("root module files")
  - `--custom-source <repo>/skills` (Direct mode) also finds `skills/module.yaml`
Skills CLI (`npx skills add`, BMAD main / 6.13.0-next):
  - `skills/<skill>/module-manifest.toml`, one per skill

Nothing ties these files together at install time, so this test does. The
installer-side facts each assertion relies on are cited inline (bmad-method
6.12.0, tools/installer/...).
"""

import csv
import json
import os
import re
import tomllib
from pathlib import Path

import yaml

ROOT = Path(__file__).parent.parent
SKILLS_DIR = ROOT / "skills"
MODULE_YAML = SKILLS_DIR / "module.yaml"
MODULE_HELP = SKILLS_DIR / "module-help.csv"
MARKETPLACE = ROOT / ".claude-plugin" / "marketplace.json"
CHANGELOG = ROOT / "CHANGELOG.md"

# tools/installer/modules/module-help-schema.js in bmad-method 6.12.0
CANONICAL_HELP_HEADER = [
    "module", "skill", "display-name", "menu-code", "description", "action",
    "args", "phase", "preceded-by", "followed-by", "required",
    "output-location", "outputs",
]
# version-resolver.js normalizeVersion(): anything that is not a string becomes null
SEMVER = re.compile(r"\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?")


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


def _help_rows():
    with MODULE_HELP.open(newline="") as fh:
        return list(csv.DictReader(fh))


# ---- skill folders ---------------------------------------------------------

def test_every_skills_subdirectory_is_a_skill():
    """A folder without SKILL.md would silently drop out of every other comparison."""
    for p in SKILLS_DIR.iterdir():
        if p.is_dir() and not p.name.startswith("."):
            assert (p / "SKILL.md").is_file(), f"skills/{p.name} has no SKILL.md"
    assert len(_skill_dirs()) >= 2


def test_every_skill_ships_a_manifest():
    for skill in _skill_dirs():
        assert (skill / "module-manifest.toml").is_file(), f"{skill.name} lacks module-manifest.toml"


# ---- module code and version -----------------------------------------------

def test_module_code_is_the_same_on_both_routes():
    code = _module_yaml()["code"]
    assert _marketplace_plugin()["name"] == code
    for name, manifest in _manifests().items():
        assert manifest["module"] == code, f"{name}/module-manifest.toml declares module={manifest['module']!r}, expected {code!r}"


def test_version_is_a_semver_string_everywhere():
    version = _module_yaml()["version"]
    assert isinstance(version, str), "module.yaml version must be quoted: a YAML float (3.1) is dropped to null by the installer"
    assert SEMVER.fullmatch(version), f"module.yaml version {version!r} is not semver"
    plugin_version = _marketplace_plugin()["version"]
    assert isinstance(plugin_version, str) and SEMVER.fullmatch(plugin_version)
    assert plugin_version == version, "marketplace.json version drifted from skills/module.yaml"
    for name, manifest in _manifests().items():
        v = manifest["version"]
        assert isinstance(v, str) and SEMVER.fullmatch(v), f"{name}/module-manifest.toml version {v!r} is not a semver string"
        assert v == version, f"{name}/module-manifest.toml version {v!r} != {version!r}"


def test_changelog_newest_release_heading_matches_the_module_version():
    """Catches 'bumped the manifests, forgot CHANGELOG' in the release procedure."""
    m = re.search(r"^## \[(\d+\.\d+\.\d+)\]", CHANGELOG.read_text(), re.M)
    assert m, "CHANGELOG.md has no '## [x.y.z]' heading"
    assert m.group(1) == _module_yaml()["version"]


# ---- manifests -------------------------------------------------------------

def test_manifests_share_update_source_and_point_knowledge_at_their_own_skill():
    manifests = _manifests()
    assert len({m["update_source"] for m in manifests.values()}) == 1, "update_source differs between skills"
    for name, m in manifests.items():
        assert name in m["knowledge"], f"{name}/module-manifest.toml knowledge points at another skill: {m['knowledge']!r}"
        assert (SKILLS_DIR / name / "references" / "help.md").is_file()


# ---- marketplace.json ------------------------------------------------------

def test_marketplace_lists_exactly_the_shipped_skills():
    skills = _marketplace_plugin()["skills"]
    assert len(skills) == len(set(skills)), f"duplicate skill entries: {skills}"
    for rel in skills:
        # plugin-resolver.js silently skips absolute or traversing paths
        assert rel.startswith("./skills/") and ".." not in Path(rel).parts, f"unsafe skill path {rel!r}"
        assert (ROOT / rel / "SKILL.md").is_file(), f"{rel} is not a skill folder"
    assert {Path(p).name for p in skills} == {p.name for p in _skill_dirs()}
    # strategy 1 needs module.yaml + module-help.csv at the skills' common parent
    common = Path(os.path.commonpath([(ROOT / rel).resolve() for rel in skills]))
    assert common == SKILLS_DIR.resolve()
    assert MODULE_YAML.is_file() and MODULE_HELP.is_file()


# ---- module-help.csv -------------------------------------------------------

def test_module_help_uses_the_6_12_canonical_header_on_physical_line_1():
    raw = MODULE_HELP.read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf"), "BOM would break the installer's startsWith('module,') header detection"
    assert b"\r" not in raw, "CRLF line endings"
    assert raw.splitlines()[0].decode() == ",".join(CANONICAL_HELP_HEADER), "installer warns on header drift and falls through positionally"
    with MODULE_HELP.open(newline="") as fh:
        rows = list(csv.reader(fh))
    body = rows[1:]
    assert len(body) >= 1
    for row in body:
        assert len(row) == len(CANONICAL_HELP_HEADER), f"row has {len(row)} fields: {row[:3]}"
        # installer.js mergeModuleHelpCatalogs splits on "\n" and drops fragments with < 12 columns
        assert all("\n" not in field for field in row), f"embedded newline would split the row for the installer: {row[1]}"
        assert not row[0].startswith("#"), "rows starting with # are treated as comments"


def test_module_help_rows_match_shipped_skills():
    rows = _help_rows()
    shipped = {p.name for p in _skill_dirs()}
    assert {r["skill"] for r in rows} == shipped, "every skill gets one help row, no more"
    codes = [r["menu-code"] for r in rows]
    assert len(codes) == len(set(codes)), f"menu codes must be unique: {codes}"
    module_name = _module_yaml()["name"]
    for r in rows:
        assert r["module"] == module_name, "help rows are grouped under the module display name"
        assert r["description"].strip(), f"{r['skill']} has an empty description"
        assert re.fullmatch(r"[A-Z]{2,3}", r["menu-code"]), f"{r['skill']} menu-code {r['menu-code']!r}: official codes are 2-3 uppercase letters"
        assert r["required"] in {"true", "false"}, f"{r['skill']} required={r['required']!r}"
        assert r["phase"], f"{r['skill']} has no phase"
        for ref in (r["preceded-by"], r["followed-by"]):
            if ref.startswith("bmad-issue-tracking-"):
                assert ref in shipped, f"{r['skill']} references unknown skill {ref!r}"
