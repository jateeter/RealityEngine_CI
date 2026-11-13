#!/usr/bin/env python3
"""Copy the release's third-party images to ghcr.io, by digest (owner, 2026-11-12).

release/mirrors.json names each source (a Docker Hub image pinned by digest) and
its mirror. Docker Hub serves layers from a TLS 1.2-only CDN, so a release
install pulls the mirrors instead.

  release/mirror-images.py --check   every third-party image in release/compose.yml
                                     and release/init/reinit.py is a mirror from
                                     the catalog (offline)
  release/mirror-images.py --push    copy each source to its mirror with
                                     `docker buildx imagetools create` (the
                                     manifest list unchanged, so the digest is
                                     kept), and check the mirror's digest and an
                                     anonymous pull token for it
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

CI = Path(__file__).resolve().parents[1]
FIRST_PARTY = re.compile(r"^(\$\{RE_IMAGE_[A-Z_]+\}|ghcr\.io/jateeter/re-)")


def catalog() -> list[dict[str, str]]:
    return json.loads((CI / "release" / "mirrors.json").read_text())["images"]


def referenced() -> set[str]:
    refs = set(re.findall(r"^\s+image:\s*\"?([^\s\"]+)\"?", (CI / "release" / "compose.yml").read_text(), flags=re.M))
    refs |= set(re.findall(r'^[A-Z_]+_IMAGE\s*=\s*"([^"]+)"', (CI / "release" / "init" / "reinit.py").read_text(), flags=re.M))
    return {r for r in refs if not FIRST_PARTY.match(r)}


def check() -> int:
    mirrors = {i["mirror"] for i in catalog()}
    problems = []
    for i in catalog():
        if i["source"].split("@")[1] != i["mirror"].split("@")[1]:
            problems.append(f"{i['mirror']}: its digest is not its source's")
    for ref in sorted(referenced()):
        if ref.startswith("ghcr.io/open-webui/"):
            continue  # already on ghcr.io (TLS 1.3)
        if ref not in mirrors:
            problems.append(f"{ref}: a third-party image that is not a mirror in release/mirrors.json")
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    print(f"mirrors: {len(catalog())} in the catalog; " + ("ok" if not problems else f"{len(problems)} problem(s)"))
    return 1 if problems else 0


def push() -> int:
    failed = 0
    for i in catalog():
        target = i["mirror"].split("@")[0]
        want = i["mirror"].split("@")[1]
        subprocess.run(["docker", "buildx", "imagetools", "create", "--tag", target, i["source"]], check=True)
        out = subprocess.run(["docker", "buildx", "imagetools", "inspect", target], check=True,
                             capture_output=True, text=True).stdout
        got = re.search(r"^Digest:\s+(\S+)", out, flags=re.M)
        repo = target.removeprefix("ghcr.io/").rsplit(":", 1)[0]
        try:
            with urllib.request.urlopen(f"https://ghcr.io/token?scope=repository:{repo}:pull", timeout=20) as r:
                public = "token" in json.load(r)
        except Exception:  # noqa: BLE001 - reported
            public = False
        ok = got and got.group(1) == want
        print(f"{'ok  ' if ok else 'FAIL'} {target} {got.group(1) if got else '?'}"
              + ("" if public else "  (not public: set the package's visibility to public)"))
        failed += 0 if ok else 1
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--push", action="store_true")
    args = ap.parse_args()
    if args.push:
        return push()
    return check()


if __name__ == "__main__":
    raise SystemExit(main())
