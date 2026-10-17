#!/usr/bin/env python3
"""Build the release images in release/images.json (ReleaseRoadmap B4, B5).

Each image is built natively for the catalog's platform (linux/arm64, A4) from
the repo checkout beside this one, labelled with the commit it was built from,
and tagged in the image registry as `<registry>/<name>:<tag>` and
`<registry>/<name>:sha-<12 hex>`. The result is an images file recording, per
image, the commit and the digest:

    {"tag": ..., "platform": ..., "images": [{"name", "repo", "revision",
      "ref", "digest", "also_from": {repo: revision}}]}

which release-manifest.py takes with --images (F2) and the installer runs from.

Local builds load into the Docker daemon. `--push` pushes instead, with SBOM
and provenance attestations; that needs `docker login ghcr.io` (or the
workflow's GITHUB_TOKEN) and a buildx builder that can push.

    release/build-images.py --tag dev                     # build all, load locally
    release/build-images.py --tag dev --only re-cpp,re-lsp
    release/build-images.py --tag release-v0.0.1-rc1 --push --out images.json

A repo with uncommitted tracked changes is refused unless --allow-dirty: the
revision label must name the source the image was actually built from.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import subprocess
import sys
import tempfile

CI_DIR = pathlib.Path(os.path.abspath(__file__)).parent.parent
CATALOG = CI_DIR / "release" / "images.json"
SOURCE_BASE = "https://github.com/jateeter"


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, **kw)


def git(repo: pathlib.Path, *args: str) -> str:
    return run(["git", "-C", str(repo), *args], capture_output=True).stdout.strip()


def repo_dir(workspace: pathlib.Path, repo: str) -> pathlib.Path:
    return CI_DIR if repo == "RealityEngine_CI" else workspace / repo


def ws_path(workspace: pathlib.Path, rel: str) -> pathlib.Path:
    head, _, rest = rel.partition("/")
    root = repo_dir(workspace, head)
    return root / rest if rest else root


def revision(workspace: pathlib.Path, repo: str, allow_dirty: bool) -> str:
    root = repo_dir(workspace, repo)
    if not (root / ".git").exists():
        sys.exit(f"{repo}: not a git checkout at {root}")
    if not allow_dirty and git(root, "status", "--porcelain", "--untracked-files=no"):
        sys.exit(f"{repo}: uncommitted tracked changes at {root}; commit them, or pass --allow-dirty")
    return git(root, "rev-parse", "HEAD")


def expand(value: str, workspace: pathlib.Path, out: pathlib.Path) -> str:
    """Catalog placeholders: {ws} the workspace, {ci} this repo, {out} a scratch
    directory for this image's build. Anything else is a workspace-relative path
    (repo/sub/path) when it names a repo, else left as it is."""
    v = value.replace("{ws}", str(workspace)).replace("{ci}", str(CI_DIR)).replace("{out}", str(out))
    if not v.startswith("/"):
        head = v.split("/", 1)[0]
        if head == "RealityEngine_CI" or (workspace / head).is_dir():
            return str(ws_path(workspace, v))
    return v


def build_one(img: dict, args, workspace: pathlib.Path, registry: str, platform: str) -> dict:
    name = img["name"]
    rev = revision(workspace, img["repo"], args.allow_dirty)
    also = {r: revision(workspace, r, args.allow_dirty) for r in img.get("also_from", [])}
    ref = f"{registry}/{name}"
    tags = [f"{ref}:{args.tag}", f"{ref}:sha-{rev[:12]}"]
    created = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    labels = {
        "org.opencontainers.image.title": name,
        "org.opencontainers.image.source": f"{SOURCE_BASE}/{img['repo']}",
        "org.opencontainers.image.revision": rev,
        "org.opencontainers.image.version": args.tag,
        "org.opencontainers.image.created": created,
        "org.opencontainers.image.vendor": "RealityEngine",
    }
    for r, sha in also.items():
        labels[f"org.realityengine.source.{r}"] = sha

    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp)
        meta = out / "metadata.json"
        # An image assembled from generated content (re-corpus) runs its
        # prepare command first; its output reaches the build as a named context.
        if img.get("prepare"):
            prep = [expand(a, workspace, out) for a in img["prepare"]]
            print(f"   prepare: {' '.join(prep)}", flush=True)
            if not args.dry_run:
                run(prep, stdout=subprocess.DEVNULL)
        cmd = ["docker", "buildx", "build", "--platform", platform,
               "-f", str(ws_path(workspace, img["dockerfile"])),
               "--metadata-file", str(meta)]
        for t in tags:
            cmd += ["-t", t]
        for k, v in labels.items():
            cmd += ["--label", f"{k}={v}"]
        for k, v in (img.get("build_args") or {}).items():
            cmd += ["--build-arg", f"{k}={v}"]
        for k, v in (img.get("build_contexts") or {}).items():
            cmd += ["--build-context", f"{k}={expand(v, workspace, out)}"]
        if args.push:
            cmd += ["--push", "--provenance=mode=max", "--sbom=true"]
        else:
            cmd += ["--load"]
        # A pushed (release) build never reuses a local layer cache and always
        # pulls its base images: a stale cached `npm install` layer once built
        # an image whose TypeScript had no linux-arm64 binary, from a source
        # tree that builds cleanly (2026-10-17, re-visualizer-frontend).
        if args.no_cache or args.push:
            cmd += ["--no-cache", "--pull"]
        cmd.append(str(ws_path(workspace, img["context"])))
        print(f"\n== {name}  ({img['repo']} @ {rev[:12]})", flush=True)
        if args.dry_run:
            print("   " + " ".join(cmd))
            return {"name": name, "repo": img["repo"], "revision": rev, "ref": ref,
                    "digest": None, "also_from": also}
        run(cmd)
        md = json.loads(meta.read_text())

    # A pushed build reports the manifest digest the image registry holds; a
    # loaded build has no image registry digest yet, so record its image ID.
    digest = md.get("containerimage.digest") if args.push else None
    image_id = md.get("containerimage.config.digest")
    return {"name": name, "repo": img["repo"], "revision": rev, "ref": ref,
            "tags": tags, "digest": digest, "image_id": image_id, "also_from": also}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", required=True, help="image tag, e.g. dev or release-v0.0.1-rc1")
    ap.add_argument("--only", default="", help="comma-separated image names")
    ap.add_argument("--workspace", type=pathlib.Path, default=CI_DIR.parent,
                    help="directory holding the sibling repos (default: this repo's parent)")
    ap.add_argument("--registry", default=None, help="override the catalog's image registry")
    ap.add_argument("--catalog", type=pathlib.Path, default=CATALOG)
    ap.add_argument("--out", type=pathlib.Path, default=None, help="write the images file here")
    ap.add_argument("--push", action="store_true", help="push to the image registry instead of loading")
    ap.add_argument("--allow-dirty", action="store_true")
    ap.add_argument("--no-cache", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="print the build commands only")
    args = ap.parse_args()

    catalog = json.loads(args.catalog.read_text())
    registry = args.registry or catalog["registry"]
    platform = catalog["platform"]
    wanted = {n for n in args.only.split(",") if n}
    images = [i for i in catalog["images"] if not wanted or i["name"] in wanted]
    unknown = wanted - {i["name"] for i in catalog["images"]}
    if unknown:
        sys.exit(f"not in the catalog: {', '.join(sorted(unknown))}")

    built, skipped = [], []
    for img in images:
        if not ws_path(args.workspace, img["dockerfile"]).is_file():
            if img.get("status") == "planned":
                skipped.append(f"{img['name']} (planned, no Dockerfile yet)")
                continue
            sys.exit(f"{img['name']}: Dockerfile {img['dockerfile']} not found")
        built.append(build_one(img, args, args.workspace, registry, platform))

    result = {
        "tag": args.tag,
        "platform": platform,
        "registry": registry,
        "pushed": bool(args.push),
        "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "images": built,
    }
    text = json.dumps(result, indent=2) + "\n"
    if args.out:
        args.out.write_text(text)
        print(f"\nwrote {args.out}")
    print(f"\nbuilt {len(built)} image(s)" + (f", skipped {len(skipped)}: " + "; ".join(skipped) if skipped else ""))
    if not args.out:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
