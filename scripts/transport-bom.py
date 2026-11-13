#!/usr/bin/env python3
"""The bill of materials of the transport inventory (owner, 2026-11-12).

config/transport-bom-components.json names the components behind every link of
config/transport-inventory.json and what each lane runs for each. This resolves
that into config/transport-bom.json and docs/TRANSPORT_BOM.md:

- compose: each service's image reference, read from the compose file in the
  workspace (the sibling repositories), or its build context;
- releaseImages: the image, its repository and Dockerfile from
  release/images.json (a missing entry is reported);
- host: the tool and its floor, read from the file that names it;
- source, external, user, planned, none: as written.

It also checks the map against the inventory: every link is served by at least
one component, and every link a component names exists. An image referenced
without a digest is listed under `unpinned`.

The BOM records what the repositories pin, never commits: a release records
the commit of each repository in its manifest (scripts/release-manifest.py).

Usage:
  python3 scripts/transport-bom.py            # write the BOM
  python3 scripts/transport-bom.py --check    # fail if the committed BOM is stale
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

CI_DIR = Path(__file__).resolve().parent.parent
WS = CI_DIR.parent
LANES = ("native", "docker", "release")


def workspace_file(rel: str) -> Path:
    """A workspace path: RealityEngine_CI/... is this checkout, whatever its directory is called."""
    repo, _, rest = rel.partition("/")
    return (CI_DIR if repo == "RealityEngine_CI" else WS / repo) / rest


def compose_service(rel: str, service: str) -> dict[str, Any]:
    path = workspace_file(rel)
    if not path.is_file():
        return {"service": service, "unresolved": f"{rel} is not checked out"}
    text = path.read_text()
    m = re.search(rf"^  {re.escape(service)}:\n((?:(?:    .*)?\n)*)", text, flags=re.M)
    if not m:
        return {"service": service, "unresolved": f"{rel} has no service {service}"}
    block = m.group(1)
    image = re.search(r"^    image:\s*\"?([^\s\"]+)\"?", block, flags=re.M)
    build = re.search(r"^    build:\s*(\S.*)?$", block, flags=re.M)
    if image:
        return {"service": service, "image": image.group(1)}
    if build:
        context = (build.group(1) or "").strip() or "(build block)"
        return {"service": service, "build": f"{rel.split('/')[0]}/{context.lstrip('./')}" if context.startswith(".") else context}
    return {"service": service, "unresolved": "neither image nor build"}


def release_images() -> dict[str, dict[str, Any]]:
    doc = json.loads((CI_DIR / "release" / "images.json").read_text())
    return {i["name"]: {**i, "registry": doc["registry"]} for i in doc["images"]}


def floor(spec: str) -> dict[str, str]:
    rel, _, var = spec.partition(" ")
    path = workspace_file(rel)
    if not path.is_file():
        return {"floorFrom": spec, "unresolved": f"{rel} is not checked out"}
    m = re.search(rf'^\s*{re.escape(var)}="?([^"\s]+)"?', path.read_text(), flags=re.M)
    return {"floorFrom": spec, "floor": m.group(1)} if m else {"floorFrom": spec, "unresolved": f"{var} not found"}


def resolve(entry: dict[str, Any], images: dict[str, dict[str, Any]]) -> dict[str, Any]:
    if "compose" in entry:
        return {"compose": entry["compose"], "services": [compose_service(entry["compose"], s) for s in entry["services"]]}
    if "releaseImages" in entry:
        out = []
        for name in entry["releaseImages"]:
            i = images.get(name)
            out.append({"name": name, "missing": "not in release/images.json"} if not i else
                       {"name": name, "image": f"{i['registry']}/{name}:<release>", "repo": i["repo"],
                        "dockerfile": i["dockerfile"], **({"status": i["status"]} if i.get("status") else {})})
        return {"releaseImages": out}
    if "host" in entry:
        return {"host": entry["host"], **floor(entry["floor"])}
    if "constant" in entry:
        rel, _, name = entry["constant"].partition(" ")
        path = workspace_file(rel)
        m = re.search(rf'^{re.escape(name)}\s*=\s*"([^"]+)"', path.read_text(), flags=re.M) if path.is_file() else None
        return {"services": [{"service": name, "image": m.group(1)} if m else
                             {"service": name, "unresolved": f"{name} not found in {rel}"}], "from": entry["constant"]}
    return dict(entry)


def build(spec: dict[str, Any], inventory: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    images = release_images()
    link_ids = [link["id"] for link in inventory["links"]]
    problems: list[str] = []
    served: dict[str, list[str]] = {lid: [] for lid in link_ids}
    components = []
    for c in spec["components"]:
        for lid in c["links"]:
            if lid not in served:
                problems.append(f"{c['id']}: names link {lid!r}, which is not in the inventory")
            else:
                served[lid].append(c["id"])
        lanes = {lane: resolve(c["lanes"][lane], images) for lane in LANES}
        components.append({**{k: v for k, v in c.items() if k != "lanes"}, "lanes": lanes})
    problems += [f"link {lid}: no component serves it" for lid, cs in served.items() if not cs]
    unpinned = sorted({s["image"] for c in components for lane in c["lanes"].values()
                       for s in lane.get("services", []) if "image" in s and "@sha256:" not in s["image"]})
    unresolved = sorted({f"{c['id']} ({lane}): {s['unresolved']}" for c in components for lane, e in c["lanes"].items()
                         for s in e.get("services", []) if "unresolved" in s}
                        | {f"{c['id']} ({lane}): {e['unresolved']}" for c in components for lane, e in c["lanes"].items()
                           if "unresolved" in e}
                        | {f"{c['id']} ({lane}): {i['name']} {i['missing']}" for c in components for lane, e in c["lanes"].items()
                           for i in e.get("releaseImages", []) if "missing" in i})
    planned = sorted(f"{c['id']} ({lane}): {e['planned']}" for c in components for lane, e in c["lanes"].items() if "planned" in e)
    bom = {"schemaVersion": "1.0.0",
           "generatedBy": "scripts/transport-bom.py from config/transport-bom-components.json, "
                          "config/transport-inventory.json, release/images.json and the workspace's compose files",
           "components": components,
           "linksServed": served,
           "unpinned": unpinned, "planned": planned, "unresolved": unresolved}
    return bom, problems


def lane_cell(e: dict[str, Any]) -> str:
    if "services" in e:
        return "<br>".join(f"`{s.get('image') or s.get('build') or s.get('unresolved')}`" for s in e["services"])
    if "releaseImages" in e:
        return "<br>".join(f"`{i.get('image', i['name'])}`" + (f" ({i['status']})" if i.get("status") else "")
                           + (" (missing)" if "missing" in i else "") for i in e["releaseImages"])
    if "source" in e:
        return f"{e['source']}: " + ", ".join(f"`{a}`" for a in e["artifacts"])
    if "host" in e:
        return f"host `{e['host']}` ≥ {e.get('floor', '?')}"
    for key in ("planned", "none", "external", "user"):
        if key in e:
            return f"*{key}*: {e[key]}"
    return json.dumps(e)


def markdown(bom: dict[str, Any]) -> str:
    rows = ["| Component | Native | Docker | Release | Links |", "|---|---|---|---|---|"]
    for c in bom["components"]:
        rows.append(f"| **{c['name']}** (`{c['id']}`) | " + " | ".join(lane_cell(c["lanes"][lane]) for lane in LANES)
                    + f" | {len(c['links'])} |")
    lists = ""
    for title, key in (("Images not pinned by digest", "unpinned"), ("Planned", "planned"), ("Unresolved", "unresolved")):
        items = bom[key]
        lists += f"\n## {title}\n\n" + ("\n".join(f"- {x}" for x in items) if items else "None.") + "\n"
    return ("# Transport inventory BOM\n\n"
            "Generated by `scripts/transport-bom.py`; do not edit. The components behind every link of "
            "`config/transport-inventory.json`, and what each lane runs for each (owner, 2026-11-12). "
            "The full record, with the links each component serves, is `config/transport-bom.json`; "
            "the map it is generated from is `config/transport-bom-components.json`. Commits are a release's, "
            "recorded in its manifest.\n\n" + "\n".join(rows) + "\n" + lists)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="fail if the committed BOM differs from a fresh one")
    args = ap.parse_args()
    spec = json.loads((CI_DIR / "config" / "transport-bom-components.json").read_text())
    inventory = json.loads((CI_DIR / "config" / "transport-inventory.json").read_text())
    bom, problems = build(spec, inventory)
    if problems:
        print(f"transport-bom: {len(problems)} problem(s)", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1
    text = json.dumps(bom, indent=2, ensure_ascii=False) + "\n"
    md = markdown(bom)
    out_json, out_md = CI_DIR / "config" / "transport-bom.json", CI_DIR / "docs" / "TRANSPORT_BOM.md"
    if args.check:
        stale = [p.name for p, want in ((out_json, text), (out_md, md)) if not p.is_file() or p.read_text() != want]
        if stale:
            print(f"transport-bom: stale: {', '.join(stale)}; run python3 scripts/transport-bom.py", file=sys.stderr)
            return 1
        print(f"transport-bom: current ({len(bom['components'])} components, {len(bom['linksServed'])} links)")
        return 0
    out_json.write_text(text)
    out_md.write_text(md)
    print(f"transport-bom: {len(bom['components'])} components, {len(bom['linksServed'])} links; "
          f"{len(bom['unpinned'])} unpinned image(s), {len(bom['planned'])} planned, {len(bom['unresolved'])} unresolved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
