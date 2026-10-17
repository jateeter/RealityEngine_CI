#!/usr/bin/env python3
"""Fail when a shared container image is pinned differently in different repos.

Five services — loki, promtail, grafana, prometheus, qdrant, open-webui — are
declared by more than one repository in this workspace. Nothing compared those
declarations, so every one of them had drifted, and the drift was invisible
until a config written for one version met a different binary at runtime
(localAIStack#77).

This is the convergence gate. `config/shared-service-versions.json` is the
single source of truth; every declaration found in a sibling repo must agree
with it.

Scope note: this checks *declared* versions, which is what a repository can be
held to. It does not check what is running — an image already pulled keeps
running whatever it was built from until something recreates it, and that is
the job of the build-provenance gate, not this one.

Usage:
    python3 scripts/check-shared-service-versions.py            # report + exit 1 on drift
    python3 scripts/check-shared-service-versions.py --summary  # report, always exit 0
"""
from __future__ import annotations

import argparse
import os
import json
import pathlib
import re
import sys

# Not resolve(): a workspace of symlinked checkouts must find its siblings
# beside the link, not beside the link's target.
CI_DIR = pathlib.Path(os.path.abspath(__file__)).parent.parent
WORKSPACE = CI_DIR.parent
MANIFEST = CI_DIR / "config" / "shared-service-versions.json"

# Repos that may declare a shared image. Absent siblings are skipped, not failed:
# a developer checkout need not hold every repo.
REPOS = [
    "RealityEngine_CI", "RealityEngine_Manager", "RealityEngine_Machines",
    "RealityEngine_CPP", "RealityEngine_LSP", "RealityEngine_Scala",
    "localAIStack", "localOpenClawStack", "localHealthkitBridge",
    "OpenCommons-Health---Personal-Information-Management",
]

# Where a declaration can hide. Compose files and Dockerfiles are the obvious
# ones; .env.example matters because localOpenClawStack keeps its authoritative
# digest there and the tag beside it is what the digest must correspond to.
FILE_GLOBS = ["docker-compose*.yml", "docker-compose*.yaml", "Dockerfile*", ".env.example"]

SKIP_DIRS = {"node_modules", ".regression-tests", ".git", "target", "build", ".venv"}


def repo_roots():
    """(name, root) for every repo present. This repo is always scanned from where
    it is, whatever its directory is called (a worktree, a CI checkout path), so
    the check can never pass having scanned nothing."""
    roots = [("RealityEngine_CI", CI_DIR)]
    for repo in REPOS:
        root = WORKSPACE / repo
        if repo == "RealityEngine_CI" or not root.is_dir() or root.resolve() == CI_DIR.resolve():
            continue
        roots.append((repo, root))
    return roots


def iter_candidate_files():
    for _repo, root in repo_roots():
        for pattern in FILE_GLOBS:
            for path in root.rglob(pattern):
                if any(part in SKIP_DIRS for part in path.parts):
                    continue
                if path.is_file():
                    yield root, path


def scan(image: str):
    """Every (path, line, tag) where `image` is pinned, tag None when floating."""
    # Matches `image:tag`, bare `image`, and `image@sha256:...` so a digest pin
    # is reported rather than silently passing as "not found".
    pat = re.compile(
        re.escape(image) + r"(?:@(?P<digest>sha256:[0-9a-f]{64})|:(?P<tag>[A-Za-z0-9._-]+))?"
    )
    for root, path in iter_candidate_files():
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            m = pat.search(line)
            if not m:
                continue
            tag = m.group("tag")
            if m.group("digest"):
                tag = "@" + m.group("digest")[:14] + "…"
            yield pathlib.Path(dict((str(r), n) for n, r in repo_roots())[str(root)]) / path.relative_to(root), lineno, tag


FLOATING = {None, "latest", "main", "master", "stable", "edge"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", action="store_true",
                    help="report and exit 0 even on drift")
    args = ap.parse_args()

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))["services"]
    problems: list[str] = []
    print("shared service versions — declared vs canonical\n")
    scanned = [name for name, _root in repo_roots()]
    print(f"  scanned {len(scanned)} repo(s): {', '.join(scanned)}\n")

    for image, spec in manifest.items():
        canonical = spec["version"]
        found = list(scan(image))
        print(f"  {image}  canonical={canonical}")
        if not found:
            print("      (no declarations found)")
            continue
        for rel, lineno, tag in found:
            if tag is not None and tag.startswith("@"):
                # A digest pin cannot be compared to a tag here; the repo that
                # uses one owns resolving it. Report, do not fail.
                print(f"      ok?  {rel}:{lineno} {tag}  (digest pin — verify separately)")
            elif tag in FLOATING:
                shown = tag if tag else "<untagged>"
                print(f"      FAIL {rel}:{lineno} {shown}  (floating tag — untrackable, cannot converge)")
                problems.append(f"{image} floats at {rel}:{lineno} ({shown})")
            elif tag != canonical:
                print(f"      FAIL {rel}:{lineno} {tag}  (expected {canonical})")
                problems.append(f"{image} is {tag} at {rel}:{lineno}, canonical is {canonical}")
            else:
                print(f"      ok   {rel}:{lineno} {tag}")
        note = spec.get("migration_note")
        if note:
            print(f"      note: {note}")
        print()

    if problems:
        print(f"[fail] {len(problems)} shared-service divergence(s):")
        for p in problems:
            print(f"  - {p}")
        print("\nConverge the pins, or change config/shared-service-versions.json if the")
        print("canonical version is what should move. A version stated twice is a version")
        print("that can disagree with itself.")
        return 0 if args.summary else 1

    print("[ok] every shared service declares the canonical version")
    return 0


if __name__ == "__main__":
    sys.exit(main())
