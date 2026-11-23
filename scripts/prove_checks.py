#!/usr/bin/env python3
"""Prove every registered check catches the real past mistake it was written for.

Each checks/regressions/*.toml entry names a check command, the commit where
the mistake was present, how to put that mistake back, and an `expect` regex.
For each entry this script copies the working tree to a scratch directory, runs
the check (it must pass), reintroduces the mistake, and runs it again: it must
fail, and its output must match `expect`. A check that passes on the bad tree,
or fails for some unrelated reason, cannot catch its mistake and fails the run.

The mistake comes back one of two ways:
- files: these paths are copied from bad_commit over today's tree.
- patch: a checks/regressions/*.patch (applied with git apply) that replays the
  bad_commit mistake on today's code, for when the old file no longer fits.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "checks" / "regressions"
REQUIRED = {"mistake", "check", "bad_commit", "expect"}


def load(path):
    entry = tomllib.loads(path.read_text(encoding="utf-8"))
    missing = REQUIRED - entry.keys()
    if missing:
        raise SystemExit(f"{path.relative_to(ROOT)}: missing keys {sorted(missing)}")
    if not isinstance(entry["check"], list):
        raise SystemExit(f"{path.relative_to(ROOT)}: check must be an argv list")
    if ("files" in entry) == ("patch" in entry):
        raise SystemExit(f"{path.relative_to(ROOT)}: set exactly one of files or patch")
    return entry


def copy_working_tree(dest):
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, check=True, capture_output=True,
    ).stdout.split(b"\0")
    for raw in filter(None, listed):
        rel = raw.decode()
        src = ROOT / rel
        if not src.is_file():
            continue
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)


def overlay(dest, commit, files):
    for rel in files:
        shown = subprocess.run(
            ["git", "show", f"{commit}:{rel}"], cwd=ROOT, capture_output=True,
        )
        target = dest / rel
        if shown.returncode != 0:
            target.unlink(missing_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(shown.stdout)


def reintroduce(tree, entry):
    if "files" in entry:
        overlay(tree, entry["bad_commit"], entry["files"])
        return None
    applied = subprocess.run(
        ["git", "apply", str(REGISTRY / entry["patch"])], cwd=tree, capture_output=True, text=True,
    )
    if applied.returncode != 0:
        return f"{entry['patch']} no longer applies; regenerate it against today's code\n{applied.stderr}"
    return None


def run(check, cwd):
    result = subprocess.run(
        check, cwd=cwd, capture_output=True, text=True,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    return result.returncode, (result.stdout + result.stderr).strip()


def prove(path, verbose):
    entry = load(path)
    name = path.stem
    with tempfile.TemporaryDirectory(prefix=f"prove-{name}-") as tmp:
        tree = Path(tmp)
        copy_working_tree(tree)
        code, out = run(entry["check"], tree)
        if code != 0:
            return f"FAIL {name}: check fails on the current tree\n{out[-2000:]}"
        problem = reintroduce(tree, entry)
        if problem:
            return f"FAIL {name}: {problem}"
        code, out = run(entry["check"], tree)
        if code == 0:
            return (
                f"FAIL {name}: check passes with the {entry['bad_commit']} mistake "
                f"reintroduced, so it cannot catch: {entry['mistake']}"
            )
        if not re.search(entry["expect"], out):
            return (
                f"FAIL {name}: check fails on the bad tree but its output does not match "
                f"expect={entry['expect']!r}, so it may be failing for an unrelated reason\n{out[-1500:]}"
            )
        detail = f"\n{out[-1500:]}" if verbose else ""
        return f"ok   {name}: fails on {entry['bad_commit']} as required{detail}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", help="registry entry names (default: all)")
    parser.add_argument("-v", "--verbose", action="store_true", help="show the failing output on the bad tree")
    args = parser.parse_args()
    paths = sorted(REGISTRY.glob("*.toml"))
    if args.names:
        paths = [p for p in paths if p.stem in args.names]
        unknown = set(args.names) - {p.stem for p in paths}
        if unknown:
            raise SystemExit(f"unknown registry entries: {sorted(unknown)}")
    if not paths:
        raise SystemExit(f"no registry entries under {REGISTRY.relative_to(ROOT)}")
    reports = [prove(p, args.verbose) for p in paths]
    print("\n".join(reports))
    return 1 if any(r.startswith("FAIL") for r in reports) else 0


if __name__ == "__main__":
    sys.exit(main())
