# Module: bmad-issue-tracking

Override layer. Ships TOML pointers + YAML workflows that hook into `bmm` workflow `on_complete` / `activation_steps_append`. Does not run standalone: must be installed in a consumer project that already has `bmm` (≥6.12.0).

## Skills in this module

- `/bmad-issue-tracking-sync` — dispatch the issue mirror for the current `sprint-status.yaml`. Use after `bmad-sprint-planning` or `bmad-sprint-status`.
- `/bmad-issue-tracking-setup` — one-time install: copies TOML overrides + YAML workflows into the consumer project.

## Trigger surface

`skills/module-help.csv` registers two commands in the consumer's help catalog: `SU` (`/bmad-issue-tracking-setup`) and `IS` (`/bmad-issue-tracking-sync`). Those are the only user-invoked entry points; everything else runs from `bmm` workflow hooks installed by the setup skill.

## Prerequisites (consumer project)

- `bmm` ≥ 6.12.0 installed. Classic installer: `installation.version` in `_bmad/_config/manifest.yaml` (fallback: `# Version:` header in `_bmad/bmm/config.yaml`). Skills CLI: `version` in `.agents/skills/bmad-*/module-manifest.toml`
- `uv` available (mandatory for BMM 6.12.0+ workflow Python)
- For bmad-loop consumers: `.bmad-loop/` directory present (optional — sync skill works without bmad-loop)

## Routing

Other questions about behavior → see the assets in the sibling skill folder (`assets/custom/`, `assets/workflows/`) — these are the source of truth. This doc is a routing pointer, not a spec.
