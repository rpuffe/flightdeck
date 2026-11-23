#!/usr/bin/env python3
"""Repo hygiene lints behind `make lint`. Run from the repo root.

    python3 scripts/lint_repo.py [ruff] [encoding] [python-argv] [artifacts] [trivy]

With no arguments every lint runs. Each failure names the fix.
"""

import ast
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path.cwd()
RUFF_VERSION = "0.17.6"
PYTHON_DIRS = ["scripts", "tests", "bootstrap/lambda"]
SUBPROCESS_CALLS = {"run", "Popen", "call", "check_call", "check_output"}
BARE_PYTHON = {"python", "python3"}
ARTIFACT = re.compile(r"(^|/)(__pycache__/|\.terraform/)|\.pyc$|\.tfstate(\.[^/]*)?$|\.tfplan$")
TRIVY_IGNORE = re.compile(r"trivy:ignore:(\S+)")
TRIVY_REASON = re.compile(r"\s--\s+\S")
ALLOWLIST = Path("checks/trivy-ignores.txt")


def candidate_files():
    """Tracked plus untracked-but-not-ignored files; plain tree walk outside git.

    The prover copies the tree without .git, so the walk branch is also what
    sees an overlaid artifact there.
    """
    if (ROOT / ".git").exists():
        out = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=ROOT, check=True, capture_output=True,
        ).stdout
        names = [raw.decode() for raw in out.split(b"\0") if raw]
        return sorted(n for n in names if (ROOT / n).exists())
    return sorted(
        str(p.relative_to(ROOT)) for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts
    )


def lint_ruff():
    if shutil.which("uvx"):
        runner = ["uvx", f"ruff=={RUFF_VERSION}"]
    elif shutil.which("pipx"):
        runner = ["pipx", "run", f"ruff=={RUFF_VERSION}"]
    else:
        return ["need uvx or pipx on PATH to run the pinned ruff"]
    done = subprocess.run(
        [*runner, "check", "--no-cache", "--output-format", "concise", *PYTHON_DIRS],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
    )
    if done.returncode == 0:
        return []
    return [
        (done.stdout + done.stderr).strip(),
        'fix: pass encoding="utf-8" to open(), read_text(), write_text() and '
        "tempfile.NamedTemporaryFile in text mode (the default encoding is locale-dependent)",
    ]


def lint_encoding():
    problems = []
    # Shipped code only. Tests are left to ruff's PLW1514, which sees open()
    # and tempfile but not Path.read_text() on inferred paths.
    for rel in python_sources():
        if rel.startswith("tests/"):
            continue
        for node in ast.walk(ast.parse((ROOT / rel).read_text(encoding="utf-8"), filename=rel)):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
                continue
            if node.func.attr not in {"read_text", "write_text"}:
                continue
            if any(kw.arg in {"encoding", None} for kw in node.keywords) or len(node.args) > (
                0 if node.func.attr == "read_text" else 1
            ):
                continue
            problems.append(
                f"{rel}:{node.lineno}: .{node.func.attr}() without encoding. "
                'fix: pass encoding="utf-8" (the default is locale-dependent)'
            )
    return problems


def python_sources():
    return [
        rel for rel in candidate_files()
        if rel.endswith(".py") and rel.split("/")[0] in {"scripts", "tests", "bootstrap"}
    ]


def lint_python_argv():
    problems = []
    for rel in python_sources():
        for node in ast.walk(ast.parse((ROOT / rel).read_text(encoding="utf-8"), filename=rel)):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
                continue
            if node.func.attr not in SUBPROCESS_CALLS or not node.args:
                continue
            argv = node.args[0]
            first = argv.elts[0] if isinstance(argv, (ast.List, ast.Tuple)) and argv.elts else None
            if isinstance(first, ast.Constant) and first.value in BARE_PYTHON:
                problems.append(
                    f'{rel}:{node.lineno}: subprocess argv starts with "{first.value}". '
                    "fix: use sys.executable so the child runs the same interpreter as the parent"
                )
    return problems


def lint_artifacts():
    return [
        f"{rel}: build artifact in the tree. fix: delete it, `git rm --cached` if tracked, "
        "and make sure .gitignore covers it (__pycache__/, .terraform/, *.tfstate*, *.tfplan)"
        for rel in candidate_files()
        if ARTIFACT.search(rel)
    ]


def read_allowlist():
    allowed = set()
    if ALLOWLIST.exists():
        for raw in ALLOWLIST.read_text(encoding="utf-8").splitlines():
            if raw.strip() and not raw.startswith("#"):
                path, ident = raw.split()
                allowed.add((path, ident))
    return allowed


def lint_trivy():
    problems, found = [], set()
    for rel in candidate_files():
        if not rel.endswith(".tf"):
            continue
        lines = (ROOT / rel).read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            ids = TRIVY_IGNORE.findall(line)
            if not ids:
                continue
            where = f"{rel}:{i + 1}"
            if not TRIVY_REASON.search(line):
                problems.append(
                    f"{where}: trivy:ignore without a reason on the same line. "
                    "fix: append ` -- <why this finding is accepted>` to the comment"
                )
            following = next((x for x in lines[i + 1:] if not x.lstrip().startswith("#")), "")
            if not following.startswith("resource "):
                problems.append(
                    f"{where}: trivy:ignore must sit directly above a `resource` block. "
                    "fix: suppress on the single resource that raises the finding; over a "
                    "data/policy block it also hides every other finding in that block"
                )
            found.update((rel, ident) for ident in ids)
    allowed = read_allowlist()
    for path, ident in sorted(found - allowed):
        problems.append(
            f"{path}: trivy:ignore:{ident} is not in {ALLOWLIST}. "
            f"fix: add the line `{path} {ident}` so the new suppression shows up in review"
        )
    for path, ident in sorted(allowed - found):
        problems.append(
            f"{ALLOWLIST}: `{path} {ident}` has no matching comment. fix: delete the stale line"
        )
    return problems


LINTS = {
    "ruff": lint_ruff,
    "encoding": lint_encoding,
    "python-argv": lint_python_argv,
    "artifacts": lint_artifacts,
    "trivy": lint_trivy,
}


def main(names):
    unknown = [n for n in names if n not in LINTS]
    if unknown:
        raise SystemExit(f"unknown lint {unknown}; choose from {sorted(LINTS)}")
    failed = False
    for name in names or LINTS:
        problems = LINTS[name]()
        print(f"{'FAIL' if problems else 'ok  '} {name}")
        for p in problems:
            print(f"  {p}")
        failed = failed or bool(problems)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
