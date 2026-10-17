#!/usr/bin/env python3
"""Promote certified candidate images to a release tag, by digest (RELEASE.md step 6).

For every image in release/images.json, resolve the digest that
`<registry>/<name>:<from-tag>` points at and add `<to-tag>` to that same
digest. Nothing is rebuilt, so the release images are byte for byte the
candidates the certification ran.

Refuses, before changing anything:
  - an image with no candidate under the from-tag;
  - a to-tag that already exists at a different digest (a release tag is never
    moved; RELEASE.md, Tag conventions).

    release/promote-images.py --from-tag release-v0.0.1-rc1 --to-tag release-v0.0.1 --out images.json
    release/promote-images.py ... --dry-run
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import subprocess
import sys

CI_DIR = pathlib.Path(os.path.abspath(__file__)).parent.parent
CATALOG = CI_DIR / "release" / "images.json"


def inspect(ref: str) -> dict | None:
    """The image index or manifest at ref, or None when there is none."""
    p = subprocess.run(["docker", "buildx", "imagetools", "inspect", "--raw", ref],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    digest = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", "--format", "{{.Manifest.Digest}}", ref],
        capture_output=True, text=True, check=True).stdout.strip()
    config = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", "--format", "{{json .Image}}", ref],
        capture_output=True, text=True, check=True).stdout.strip()
    image = json.loads(config) if config and config != "null" else {}
    # A multi-platform index maps platform -> image; a single image is flat.
    if image and "config" not in image:
        image = next(iter(image.values()), {})
    labels = (image.get("config") or {}).get("Labels") or {}
    return {"digest": digest, "labels": labels}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from-tag", required=True)
    ap.add_argument("--to-tag", required=True)
    ap.add_argument("--catalog", type=pathlib.Path, default=CATALOG)
    ap.add_argument("--registry", default=None)
    ap.add_argument("--out", type=pathlib.Path, default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    catalog = json.loads(args.catalog.read_text())
    registry = args.registry or catalog["registry"]

    plan, problems = [], []
    for img in catalog["images"]:
        ref = f"{registry}/{img['name']}"
        cand = inspect(f"{ref}:{args.from_tag}")
        if cand is None:
            problems.append(f"{img['name']}: no candidate at {ref}:{args.from_tag}")
            continue
        existing = inspect(f"{ref}:{args.to_tag}")
        if existing and existing["digest"] != cand["digest"]:
            problems.append(f"{img['name']}: {ref}:{args.to_tag} already exists at "
                            f"{existing['digest']}, not the candidate {cand['digest']}; a release tag is never moved")
            continue
        labels = cand["labels"]
        plan.append({
            "name": img["name"], "repo": img["repo"], "ref": ref,
            "revision": labels.get("org.opencontainers.image.revision", ""),
            "digest": cand["digest"],
            "already": bool(existing),
            "also_from": {k.removeprefix("org.realityengine.source."): v
                          for k, v in labels.items() if k.startswith("org.realityengine.source.")},
        })

    if problems:
        print(f"[refused] {len(problems)} problem(s); nothing was tagged:")
        for p in problems:
            print(f"  - {p}")
        return 1

    for p in plan:
        target = f"{p['ref']}:{args.to_tag}"
        if p["already"]:
            print(f"  = {target} already at {p['digest']}")
            continue
        cmd = ["docker", "buildx", "imagetools", "create", "-t", target, f"{p['ref']}@{p['digest']}"]
        print(("  would: " if args.dry_run else "  ") + " ".join(cmd))
        if not args.dry_run:
            subprocess.run(cmd, check=True)

    result = {
        "tag": args.to_tag,
        "promoted_from": args.from_tag,
        "platform": catalog["platform"],
        "registry": registry,
        "pushed": not args.dry_run,
        "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "images": [{k: v for k, v in p.items() if k != "already"} for p in plan],
    }
    text = json.dumps(result, indent=2) + "\n"
    if args.out:
        args.out.write_text(text)
    print(f"promoted {len(plan)} image(s) {args.from_tag} -> {args.to_tag}" + (" (dry run)" if args.dry_run else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
