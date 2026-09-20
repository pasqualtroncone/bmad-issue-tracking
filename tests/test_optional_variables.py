"""A CHECK may only read a variable that is predefined, SET on every path, or an output.

S11 (#63): `lookup_after_create`, `review_producer`, `label_color` and `allow_merge` were
read by a CHECK on the strength of an "optional-flag idiom" — an unset variable reading
false — that `bmad-workflow-lang.md` section 4.5 contradicts ("Variable reference
undefined -> Stop workflow", and the section 5 table says the same for a CHECK). Two
headless interpreters have already read the same file the two different ways. The rule
chosen is the strict one: the defaults are SET, and section 4.5 now says so.
`merge-mr.yaml`'s `error` is the same shape — a documented OUTPUT its success path never
assigned — and so is `head_sha` (#81): the CI lookups interpolate `{head_sha}` to pin
themselves to the commit that was pushed, and a caller that pushed nothing must still reach
them, so `common/check-config.yaml` seeds it "" and `common/post-dev-complete.yaml`
overwrites it after each push.

This test keeps them set. It walks the INCLUDE graph from every entry workflow (a file no
other file INCLUDEs — the ones the TOML overrides point at) and requires that whenever the
closure can reach a file READING one of these variables, the same closure also contains a
file that SETs it.
"""

import re

import pytest

from conftest import WORKFLOWS_DIR

# Flags a CHECK branches on. A new one is fixed with a SET at the entry point, never
# with a spec change.
GUARDED_FLAGS = ("lookup_after_create", "review_producer", "label_color", "allow_merge")
# Plus two names no CHECK branches on, so §4.5 is the only thing that guards them:
# `error`, which no file reads but every caller of common/merge-mr.yaml is told to, and
# `head_sha` (#81), which the CI lookups interpolate and only a phase that PUSHES can know.
GUARDED_VARS = GUARDED_FLAGS + ("error", "head_sha")

_INCLUDE_RE = re.compile(r"^\s*-\s*INCLUDE:\s*(\S+)\s*$", re.MULTILINE)
_SET_RE = re.compile(r"^\s*-\s*SET:\s*\{\s*variable:\s*(\w+)", re.MULTILINE)
_STORE_RE = re.compile(r"^\s*(?:STORE|store):\s*(\w+)\s*$", re.MULTILINE)
_CHECK_RE = re.compile(r"^\s*-\s*CHECK:\s*(.+)$", re.MULTILINE)


def _body(path):
    """File content without comment lines (a name in prose is not a read)."""
    return "\n".join(
        line for line in path.read_text(encoding="utf-8").split("\n")
        if not line.lstrip().startswith("#")
    )


def _load():
    return {
        str(p.relative_to(WORKFLOWS_DIR)): _body(p)
        for p in sorted(WORKFLOWS_DIR.rglob("*.yaml"))
    }


FILES = _load()
GRAPH = {rel: {t + ".yaml" for t in _INCLUDE_RE.findall(body)} for rel, body in FILES.items()}
INCLUDED = {t for targets in GRAPH.values() for t in targets}
ENTRIES = sorted(rel for rel in FILES if rel not in INCLUDED)


def _closure(root):
    seen, stack = set(), [root]
    while stack:
        rel = stack.pop()
        if rel in seen or rel not in FILES:
            continue
        seen.add(rel)
        stack.extend(GRAPH[rel])
    return seen


def _reads(body, var):
    if re.search(r"\{" + var + r"\}", body):
        return True
    return any(re.search(r"\b" + var + r"\b", cond) for cond in _CHECK_RE.findall(body))


def _sets(body, var):
    return var in _SET_RE.findall(body) or var in _STORE_RE.findall(body)


class TestGuardedOptionalVariables:
    """P0: no entry workflow can reach a reader of these names without a setter."""

    @pytest.mark.parametrize("var", GUARDED_VARS)
    def test_every_entry_that_reads_also_sets(self, var):
        offenders = []
        for entry in ENTRIES:
            closure = _closure(entry)
            readers = sorted(rel for rel in closure if _reads(FILES[rel], var))
            if not readers:
                continue
            setters = sorted(rel for rel in closure if _sets(FILES[rel], var))
            if not setters:
                offenders.append(f"{entry} reaches {readers} but nothing SETs {var}")
        assert not offenders, (
            f"'{var}' is read where nothing defines it — lang §4.5 stops the run there. "
            f"SET the default at the entry point, do not rely on an unset variable "
            f"reading false:\n  " + "\n  ".join(offenders)
        )

    @pytest.mark.parametrize("var", GUARDED_FLAGS)
    def test_guarded_flag_is_still_read_somewhere(self, var):
        """A flag nothing reads any more belongs out of GUARDED_FLAGS, not in it."""
        readers = [rel for rel, body in FILES.items() if _reads(body, var)]
        assert readers, f"nothing reads '{var}' any more — drop it from GUARDED_FLAGS"

    def test_merge_mr_seeds_its_error_output(self):
        """`error` is a documented OUTPUT, so it must exist whether or not a merge failed.

        Only the failure branch assigned it, so a caller reading {error} after a good
        merge — the very check the header asks callers to make — hit lang §4.5, after the
        irreversible CLI had run. It is seeded at column 0 before the platform branches,
        like gl_merge_out / gh_merge_out.
        """
        lines = FILES["common/merge-mr.yaml"].split("\n")
        seed = next((i for i, l in enumerate(lines)
                     if re.match(r'^- SET: \{ variable: error, value: "" \}', l)), None)
        first_branch = next((i for i, l in enumerate(lines)
                             if l.startswith("- CHECK: git_platform")), None)
        assert seed is not None, "common/merge-mr.yaml never seeds its `error` output"
        assert first_branch is not None and seed < first_branch, (
            f"common/merge-mr.yaml seeds `error` at line {seed} but branches at "
            f"{first_branch}: the seed must precede every path that can return"
        )
