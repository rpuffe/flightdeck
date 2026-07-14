#!/usr/bin/env python3
"""Check or update every reference coupled to a Flightdeck release tag."""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


TAG_PATTERN = r"v[0-9]+\.[0-9]+\.[0-9]+"


@dataclass(frozen=True)
class ReleaseReference:
    name: str
    path: str
    pattern: str


# This is the single inventory of release-coupled references. Release prep and
# CI both consume it; adding a new self-reference requires adding it here once.
RELEASE_REFERENCES = (
    ReleaseReference("deploy build workflow", ".github/workflows/deploy.yml", r"(build-scan-push\.yml@)(%s)" % TAG_PATTERN),
    ReleaseReference("deploy terraform workflow", ".github/workflows/deploy.yml", r"(terraform-plan-apply\.yml@)(%s)" % TAG_PATTERN),
    ReleaseReference("promote terraform workflow", ".github/workflows/promote.yml", r"(terraform-plan-apply\.yml@)(%s)" % TAG_PATTERN),
    ReleaseReference("template PR workflow", "template-app/.github/workflows/ci.yml", r"(pr-checks\.yml@)(%s)" % TAG_PATTERN),
    ReleaseReference("template deploy workflow", "template-app/.github/workflows/ci.yml", r"(deploy\.yml@)(%s)" % TAG_PATTERN),
    ReleaseReference("template promote workflow", "template-app/.github/workflows/ci.yml", r"(promote\.yml@)(%s)" % TAG_PATTERN),
    ReleaseReference("template Terraform module", "template-app/main.tf", r"(fargate-service\?ref=)(%s)" % TAG_PATTERN),
    ReleaseReference("template release marker", "template-app/.flightdeck-version", r"()^(%s)$" % TAG_PATTERN),
    ReleaseReference("README current release", "README.md", r"(Latest tagged release: \*\*)(%s)(\*\*)" % TAG_PATTERN),
    ReleaseReference("handoff current release", "spec-docs/HANDOFF.md", r"(platform tag )(%s)(\))" % TAG_PATTERN),
)


def validate_tag(tag: str) -> None:
    if re.fullmatch(TAG_PATTERN, tag) is None:
        raise ValueError(f"release tag must match vX.Y.Z, got {tag!r}")


def replace_atomically(contents: dict[Path, str]) -> None:
    """Replace a file set with temp files and roll back any partial failure."""
    prepared: list[tuple[Path, Path, bytes, int]] = []
    replaced: list[tuple[Path, bytes, int]] = []
    try:
        for path, text in contents.items():
            original = path.read_bytes()
            mode = path.stat().st_mode
            with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
                handle.write(text.encode(encoding="utf-8"))
                temporary = Path(handle.name)
            temporary.chmod(mode)
            prepared.append((path, temporary, original, mode))
        for path, temporary, original, mode in prepared:
            os.replace(temporary, path)
            replaced.append((path, original, mode))
    except OSError:
        for path, original, mode in reversed(replaced):
            with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
                handle.write(original)
                rollback = Path(handle.name)
            rollback.chmod(mode)
            os.replace(rollback, path)
        raise
    finally:
        for _path, temporary, _original, _mode in prepared:
            temporary.unlink(missing_ok=True)


def inspect(root: Path, expected_tag: str, update: bool = False) -> list[str]:
    validate_tag(expected_tag)
    errors: list[str] = []
    found: list[tuple[ReleaseReference, Path, re.Match[str]]] = []
    for reference in RELEASE_REFERENCES:
        path = root / reference.path
        if not path.is_file():
            errors.append(f"{reference.name}: missing {reference.path}")
            continue
        text = path.read_text(encoding="utf-8")
        matches = list(re.finditer(reference.pattern, text, flags=re.MULTILINE))
        if len(matches) != 1:
            errors.append(
                f"{reference.name}: expected exactly one reference in {reference.path}, found {len(matches)}"
            )
            continue
        match = matches[0]
        found.append((reference, path, match))
        actual_tag = match.group(2)
        if actual_tag == expected_tag:
            continue
        if not update:
            errors.append(
                f"{reference.name}: {reference.path} uses {actual_tag}, expected {expected_tag}"
            )
    # --set is two-phase: validate the entire inventory before writing any
    # file, then apply each file's edits back-to-front from the validated text.
    if errors or not update:
        return errors
    changes: dict[Path, list[tuple[int, int, str]]] = {}
    for _reference, path, match in found:
        if match.group(2) == expected_tag:
            continue
        replacement = match.group(1) + expected_tag
        if match.lastindex and match.lastindex >= 3:
            replacement += match.group(3)
        changes.setdefault(path, []).append((match.start(), match.end(), replacement))
    updated: dict[Path, str] = {}
    for path, edits in changes.items():
        text = path.read_text(encoding="utf-8")
        for start, end, replacement in sorted(edits, reverse=True):
            text = text[:start] + replacement + text[end:]
        updated[path] = text
    replace_atomically(updated)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--tag", help="expected release tag (defaults to template marker)")
    parser.add_argument("--set", dest="set_tag", help="update all inventoried references to this tag")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.tag and args.set_tag:
        parser.error("--tag and --set are mutually exclusive")
    try:
        tag = (
            args.set_tag
            or args.tag
            or (root / "template-app/.flightdeck-version").read_text(encoding="utf-8").strip()
        )
        errors = inspect(root, tag, update=bool(args.set_tag))
        if args.set_tag and not errors:
            errors = inspect(root, tag)
    except (OSError, ValueError) as error:
        print(f"release consistency: {error}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print(f"release consistency: {error}", file=sys.stderr)
        return 1
    verb = "updated and verified" if args.set_tag else "verified"
    print(f"release consistency: {verb} {len(RELEASE_REFERENCES)} references at {tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
