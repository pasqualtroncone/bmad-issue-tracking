#!/usr/bin/env python3
"""e2e helpers built on tests/conftest.py's workflow parser (single source of truth).

  render-step <rel> <line> [key=value ...]   print the RUN command at <line> (1-based) of
                                             workflows/<rel>, placeholders rendered; `|`
                                             blocks are dedented (the parser drops them)
  lint-sys                                   every `python -c` body that uses `sys.` without
                                             importing sys (the check the dead test skips)
  reachable <rel>                            RUN steps reachable from <rel> through INCLUDE
  analyze <trace.jsonl> --entry <rel> --out <dir>
                                             commands.txt, files.txt, result.json, final.txt,
                                             improvisation.txt, coverage.txt from a
                                             `claude -p --output-format stream-json` trace

Run with: uv run --no-project --with pytest --with pyyaml python tests/e2e/trace-tools.py ...
(conftest imports pytest + yaml; tests/e2e/lib/common.sh exports this as $PY / $TT)
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))  # tests/ → conftest
import conftest  # noqa: E402

WF = conftest.WORKFLOWS_DIR
STEP_RE = re.compile(r"^(\s*)- (RUN|INCLUDE|READ|FILTER|OUTPUT|WRITE|CHECK|LOOP|SET|STOP|CD):\s*(.*)$")
FIELD_RE = re.compile(r"^\s+(STORE|PLATFORM|EXPECT_EXIT|CAPTURE|EXTRACT|TRUE|FALSE|do|items|as|message|stop|store|file|content|mode|source|select|where):")


def scan_steps(rel):
    """[(line, type, command)] for every RUN/INCLUDE in workflows/<rel>, at ANY nesting depth.

    tests/conftest.py's parser drops steps nested LOOP→CHECK→RUN (e.g. sync-issues.yaml:274,
    the D17 step), so the lab scans the file linearly: a step starts at `- TYPE:`; a RUN
    body continues on the following lines until the next step or sub-field (`STORE:` …).
    `RUN: |` blocks are dedented. Line numbers are 1-based file lines.
    """
    lines = (WF / rel).read_text(encoding="utf-8").split("\n")
    out, i = [], 0
    while i < len(lines):
        m = STEP_RE.match(lines[i])
        if not m:
            i += 1
            continue
        indent, typ, value = len(m.group(1)), m.group(2), m.group(3).strip()
        start = i
        i += 1
        if typ not in ("RUN", "INCLUDE"):
            continue
        if typ == "INCLUDE":
            out.append((start + 1, typ, value))
            continue
        body = []
        while i < len(lines):
            l = lines[i]
            if STEP_RE.match(l) or FIELD_RE.match(l):
                break
            if l.strip() and (len(l) - len(l.lstrip())) <= indent and value != "|":
                # a column-0 python line inside `-c "..."` is allowed; anything else at or
                # left of the step indent that is not part of an open quote ends the body
                if l.startswith(" ") or l.startswith("#"):
                    break
            body.append(l)
            i += 1
        while body and not body[-1].strip():
            body.pop()
        if value == "|":
            ind = min((len(l) - len(l.lstrip()) for l in body if l.strip()), default=0)
            cmd = "\n".join(l[ind:] if l.strip() else "" for l in body)
        else:
            cmd = value + ("\n" + "\n".join(body) if body else "")
        out.append((start + 1, typ, cmd))
    return out


def step_at(rel, line):
    for ln, typ, cmd in scan_steps(rel):
        if ln == line:
            return typ, cmd
    sys.exit(f"no RUN/INCLUDE step starts at {rel}:{line}")


def render(text, kv):
    for k, v in kv.items():
        text = text.replace("{" + k + "}", v)
    return text


def cmd_render_step(args):
    rel, line = args[0], int(args[1])
    kv = dict(a.split("=", 1) for a in args[2:])
    typ, cmd = step_at(rel, line)
    if typ != "RUN":
        sys.exit(f"{rel}:{line} is a {typ} step, not RUN")
    print(render(cmd, kv))


def python_bodies():
    """Yield (rel, line, body) for every `python -c "..."` in a RUN step (incl. `|` blocks)."""
    for path in sorted(WF.rglob("*.yaml")):
        rel = str(path.relative_to(WF))
        for line, typ, text in scan_steps(rel):
            if typ != "RUN":
                continue
            for m in re.finditer(r'python -c "((?:[^"\\]|\\.)*)"', text, re.DOTALL):
                yield rel, line, m.group(1)


def cmd_lint_sys(_args):
    bad = 0
    for rel, line, body in python_bodies():
        if re.search(r"\bsys\.", body) and not re.search(r"^\s*(import\s+[\w, ]*\bsys\b|from\s+sys\s+import)", body, re.MULTILINE):
            bad += 1
            first = next((l for l in body.splitlines() if l.strip()), "")
            print(f"{rel}:{line}: uses sys without import — first body line: {first.strip()[:80]}")
    print(f"{bad} python -c bodies use sys without importing it")
    return 1 if bad else 0


def include_target(raw):
    t = raw.strip()
    return t if t.endswith(".yaml") else t + ".yaml"


def reachable_runs(entry):
    """[(rel, line, command)] for every RUN reachable from entry via INCLUDE (transitive)."""
    seen, order, runs = set(), [entry], []
    while order:
        rel = order.pop(0)
        if rel in seen or not (WF / rel).exists():
            continue
        seen.add(rel)
        for line, typ, cmd in scan_steps(rel):
            if typ == "INCLUDE":
                order.append(include_target(cmd))
            else:
                runs.append((rel, line, cmd))
    return runs, seen


def cmd_reachable(args):
    runs, files = reachable_runs(args[0])
    print(f"# {len(files)} files, {len(runs)} RUN steps")
    for rel, line, cmd in runs:
        print(f"{rel}:{line}\t{cmd.splitlines()[0][:150] if cmd.strip() else '(empty)'}")


def _pattern(cmd):
    """Regex for a RUN command: first non-empty line, placeholders → non-greedy wildcards."""
    first = next((l for l in cmd.splitlines() if l.strip()), "").strip()
    first = re.sub(r"\s+2>/dev/null\s*\|\|\s*true\s*$", "", first)
    parts = re.split(r"\{\w+\}", first)
    pat = r".+?".join(re.escape(p) for p in parts)
    pat = re.sub(r"\\\s", r"\\s+", pat)
    return re.compile(pat, re.DOTALL), parts[0].strip()


def cmd_analyze(args):
    trace = Path(args[0])
    entry = args[args.index("--entry") + 1] if "--entry" in args else None
    out = Path(args[args.index("--out") + 1]) if "--out" in args else trace.parent
    out.mkdir(parents=True, exist_ok=True)

    tools, commands, files, finals, result = Counter(), [], [], [], None
    pending, results = {}, []  # tool_use_id → command; (command, is_error, result text)
    with open(trace, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "result":
                result = ev
            if ev.get("type") == "user":
                for c in ev.get("message", {}).get("content", []) or []:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        body = c.get("content")
                        if isinstance(body, list):
                            body = "\n".join(b.get("text", "") for b in body if isinstance(b, dict))
                        results.append((pending.get(c.get("tool_use_id"), "?"), bool(c.get("is_error")), str(body or "")))
                continue
            if ev.get("type") != "assistant":
                continue
            for c in ev.get("message", {}).get("content", []) or []:
                if c.get("type") == "text" and c.get("text", "").strip():
                    finals.append(c["text"])
                if c.get("type") != "tool_use":
                    continue
                name, inp = c.get("name", "?"), c.get("input", {}) or {}
                tools[name] += 1
                if name == "Bash":
                    commands.append(inp.get("command", ""))
                    pending[c.get("id")] = inp.get("command", "")
                elif name in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
                    files.append(f"{name}\t{inp.get('file_path', '')}")
                elif name in ("Read",):
                    files.append(f"{name}\t{inp.get('file_path', '')}")

    (out / "commands.txt").write_text("\n\n".join(f"### {i+1}\n{c}" for i, c in enumerate(commands)) + "\n", encoding="utf-8")
    (out / "files.txt").write_text("\n".join(files) + "\n", encoding="utf-8")
    (out / "final.txt").write_text("\n\n---\n\n".join(finals[-3:]) + "\n", encoding="utf-8")
    with open(out / "tool-results.txt", "w", encoding="utf-8") as fh:
        for i, (cmd, err, body) in enumerate(results):
            if cmd == "?":
                continue
            fh.write(f"### {i+1} {'ERROR' if err else 'ok'}\n$ {cmd.strip()[:300]}\n{body.strip()[:1200]}\n\n")
    errors = sum(1 for _, e, _ in results if e)
    summary = {
        "trace": str(trace), "tool_counts": dict(tools), "bash_commands": len(commands), "tool_errors": errors,
        "result": {k: result.get(k) for k in ("subtype", "is_error", "duration_ms", "duration_api_ms", "num_turns", "total_cost_usd", "stop_reason")} if result else None,
        "model_usage": (result or {}).get("modelUsage"),
    }
    (out / "result.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    if entry:
        runs, _ = reachable_runs(entry)
        pats = [(rel, line, cmd) + _pattern(cmd) for rel, line, cmd in runs]
        hit = Counter()
        impro, lines = [], []
        for i, c in enumerate(commands):
            norm = re.sub(r"^\s*cd\s+\S+\s*(&&|;)\s*", "", c.strip(), flags=re.DOTALL)
            match = None
            for rel, line, cmd, rx, prefix in pats:
                if rx.search(norm) or (len(prefix) >= 12 and prefix in norm):
                    match = f"{rel}:{line}"
                    hit[match] += 1
                    break
            tag = match or "IMPROVISED"
            lines.append(f"{i+1:3d}  {tag:45s}  {norm.splitlines()[0][:110] if norm.strip() else '(empty)'}")
            if not match:
                impro.append(c)
        body = [f"# entry: {entry}  reachable RUN steps: {len(pats)}  executed Bash: {len(commands)}  improvised: {len(impro)}", ""] + lines
        (out / "improvisation.txt").write_text("\n".join(body) + "\n", encoding="utf-8")
        cov = [f"# RUN steps reachable from {entry} never executed in this trace (branches make some legitimate)"]
        for rel, line, cmd, _, _ in pats:
            if hit[f"{rel}:{line}"] == 0:
                cov.append(f"{rel}:{line}\t{cmd.splitlines()[0][:120] if cmd.strip() else ''}")
        (out / "coverage.txt").write_text("\n".join(cov) + "\n", encoding="utf-8")
        summary["improvised"] = len(impro)
        summary["reachable_runs"] = len(pats)
        (out / "result.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary["result"] or {}, indent=None))
    print(f"bash={len(commands)} improvised={summary.get('improvised', 'n/a')} tools={dict(tools)}")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    fn = {"render-step": cmd_render_step, "lint-sys": cmd_lint_sys, "reachable": cmd_reachable, "analyze": cmd_analyze}.get(cmd)
    if not fn:
        sys.exit(__doc__)
    rc = fn(args)
    sys.exit(rc or 0)


if __name__ == "__main__":
    main()
