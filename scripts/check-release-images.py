#!/usr/bin/env python3
"""Validate the release image catalog, release/images.json (ReleaseRoadmap B1).

Checks, for every image:
  - the name is `re-<component>` and unique;
  - its repo is one of the ten release repos;
  - its build context and Dockerfile exist, when that repo is checked out beside
    this one. A `status: planned` image may have no Dockerfile yet; nothing else
    may be missing;
  - no two images build from the same Dockerfile and context (one Dockerfile per
    image, and one image per Dockerfile and context).

And for the catalog: the image registry is ghcr.io/jateeter and the platform is
linux/arm64 (decisions A3 and A4).

A repo that is not checked out is reported and skipped, never passed silently:
the summary names how many images were checked against a real file.

    python3 scripts/check-release-images.py              # exit 1 on a problem
    python3 scripts/check-release-images.py --catalog F  # check another file
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys

# Not resolve(): a workspace of symlinked checkouts must find its siblings
# beside the link, not beside the link's target.
CI_DIR = pathlib.Path(os.path.abspath(__file__)).parent.parent
WORKSPACE = CI_DIR.parent
CATALOG = CI_DIR / "release" / "images.json"

RELEASE_REPOS = {
    "RealityEngine_CI", "RealityEngine_CPP", "RealityEngine_LSP",
    "RealityEngine_Scala", "RealityEngine_Machines", "RealityEngine_Manager",
    "localAIStack", "localOpenClawStack",
    "OpenCommons-Health---Personal-Information-Management", "localHealthkitBridge",
}
REGISTRY = "ghcr.io/jateeter"
PLATFORM = "linux/arm64"
NAME_RE = re.compile(r"^re-[a-z0-9]+(-[a-z0-9]+)*$")
REQUIRED = ("name", "repo", "context", "dockerfile")


def repo_dir(repo: str) -> pathlib.Path:
    # This repo is always found where it is, whatever its directory is called.
    return CI_DIR if repo == "RealityEngine_CI" else WORKSPACE / repo


def workspace_path(rel: str) -> pathlib.Path | None:
    """A workspace-relative path, or None when its repo is not checked out."""
    head, _, rest = rel.partition("/")
    root = repo_dir(head)
    if not root.is_dir():
        return None
    return root / rest if rest else root


def check(catalog: dict) -> tuple[list[str], int, list[str]]:
    problems: list[str] = []
    skipped: list[str] = []
    verified = 0

    if catalog.get("registry") != REGISTRY:
        problems.append(f"registry is {catalog.get('registry')!r}, expected {REGISTRY!r} (A3)")
    if catalog.get("platform") != PLATFORM:
        problems.append(f"platform is {catalog.get('platform')!r}, expected {PLATFORM!r} (A4)")

    images = catalog.get("images")
    if not isinstance(images, list) or not images:
        problems.append("no images listed")
        return problems, verified, skipped

    seen_names: set[str] = set()
    seen_builds: dict[tuple[str, str], str] = {}
    for i, img in enumerate(images):
        label = img.get("name", f"images[{i}]")
        missing = [k for k in REQUIRED if not img.get(k)]
        if missing:
            problems.append(f"{label}: missing {', '.join(missing)}")
            continue
        name, repo = img["name"], img["repo"]
        if not NAME_RE.match(name):
            problems.append(f"{name}: not of the form re-<component>")
        if name in seen_names:
            problems.append(f"{name}: listed twice")
        seen_names.add(name)
        for r in [repo, *img.get("also_from", [])]:
            if r not in RELEASE_REPOS:
                problems.append(f"{name}: {r} is not a release repo")
        build = (img["dockerfile"], img["context"])
        if build in seen_builds:
            problems.append(f"{name}: builds from the same Dockerfile and context as {seen_builds[build]}")
        seen_builds[build] = name

        planned = img.get("status") == "planned"
        if img.get("status") not in (None, "planned"):
            problems.append(f"{name}: unknown status {img['status']!r}")

        ctx = workspace_path(img["context"])
        dockerfile = workspace_path(img["dockerfile"])
        if ctx is None or dockerfile is None:
            skipped.append(f"{name} ({img['context'].split('/')[0]} or "
                           f"{img['dockerfile'].split('/')[0]} not checked out)")
            continue
        if not dockerfile.is_file():
            if planned:
                skipped.append(f"{name} (planned; {img['dockerfile']} not built yet)")
                continue
            problems.append(f"{name}: Dockerfile {img['dockerfile']} does not exist")
            continue
        if not ctx.is_dir():
            problems.append(f"{name}: build context {img['context']} does not exist")
            continue
        verified += 1

    return problems, verified, skipped


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", type=pathlib.Path, default=CATALOG)
    args = ap.parse_args()

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    problems, verified, skipped = check(catalog)
    total = len(catalog.get("images") or [])
    print(f"release image catalog: {total} image(s), {verified} checked against their files")
    for s in skipped:
        print(f"  skip {s}")
    if problems:
        print(f"[fail] {len(problems)} problem(s):")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("[ok] release image catalog is consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
