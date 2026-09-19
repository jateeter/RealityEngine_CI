#!/usr/bin/env python3
"""
regression-export-parity.py — do the runtimes export the same machine document?

`GET /api/machines/:id/export` is how a machine moves between engines, and
`POST /api/machines` ingests whatever it is handed (SURFACE_SPEC, "POST
/api/machines always ingests"). **An export that does not match is an export
that silently changes the machine.**

Nothing gated this. Every defect in the export surface so far was found by
hand-diffing two payloads:

  - RealityEngine_Scala#104 — 6 event fields against C++ and LSP's 10, so the
    Manager's live activation layer was inert under Scala;
  - RealityEngine_LSP#104 — `outputEvents[].timestamp` hardcoded to 0;
  - RealityEngine_CI#436 — four more, including `outputMergeTransformation`
    omitted entirely, so a machine exported with a non-default fold came back as
    the default on re-ingestion, silently retuning a training variable.

That last one is the argument for this stage. It is not a shape difference a
reader would notice; it is a value that disappears, and the only way to see it
is to compare the documents.

## What is excluded, and why it is by PATH rather than by key name

`parity_identity.strip_engine_identity` drops `id` and `timestamp` wherever they
appear, which is correct for a step payload — every id there is minted. It is
wrong here. In an export, `sequences[].id`, `events[].id` and
`outputEvents[].id` are **corpus-declared** and are the most important thing to
compare; only `.machine.id` is minted.

So the exclusions are path-shaped:

  .machine.id                  the engine-minted machine id (#146, #397)
  ...timestamp                 load timestamps, stamped at ingestion, so two
                               engines started at different times always differ
                               (RealityEngine_LSP#104)

Everything else is compared, including every corpus-declared id and every
region offset.

## Quorum

3-of-3 (`docs/QUORUM_CONTRACT.md`). A runtime that will not answer is not
agreement; a machine absent from one runtime is reported as such rather than
silently dropped from the comparison. Machines are matched by corpus **name**,
never by id.

Usage:
  python3 scripts/regression-export-parity.py
  python3 scripts/regression-export-parity.py --machines 25
  python3 scripts/regression-export-parity.py --all --out report.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib import error, request

# Load timestamps. Stamped when the machine is ingested, so two engines started
# at different times report different values for the same corpus machine — an
# engine-scoped fact, like a minted id, and excluded for the same reason.
TIMESTAMP_PATH = re.compile(r"\.timestamp$")

# The one minted id in an export. Every other id in the document is declared by
# the corpus and is compared.
MINTED_ID_PATHS = frozenset({".machine.id"})


def read_instances(source: str) -> list[dict]:
    if source.startswith(("http://", "https://")):
        with request.urlopen(source, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    else:
        payload = json.loads(Path(source).read_text(encoding="utf-8"))
    return payload.get("instances", [])


def get_json(url: str) -> tuple[Any, str | None]:
    try:
        with request.urlopen(url, timeout=300) as response:
            return json.loads(response.read().decode("utf-8")), None
    except error.HTTPError as exc:
        return None, f"HTTP {exc.code}"
    except (error.URLError, OSError, ValueError) as exc:
        return None, f"{type(exc).__name__}: {exc}"


def leaves(node: Any, path: str = "") -> dict[str, Any]:
    """Every leaf in the document, keyed by its path.

    Paths carry list indices, so a reordering shows as differing leaves rather
    than as equal sets. That is deliberate: `sequences[].events[]` came back in
    a different order on one runtime, and a set comparison would have called
    that equal while a consumer reading events positionally saw something else
    (#436).
    """
    out: dict[str, Any] = {}
    if isinstance(node, dict):
        for key, value in node.items():
            out.update(leaves(value, f"{path}.{key}"))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            out.update(leaves(value, f"{path}[{index}]"))
    else:
        out[path] = node
    return out


def comparable(flat: dict[str, Any]) -> dict[str, Any]:
    return {p: v for p, v in flat.items()
            if p not in MINTED_ID_PATHS and not TIMESTAMP_PATH.search(p)}


def machines_by_name(instance: dict) -> tuple[dict[str, str], str | None]:
    payload, err = get_json(f"{instance['re_url']}/api/machines")
    if err:
        return {}, f"{instance['id']}: GET /api/machines {err}"
    machines = payload.get("machines", payload)
    if not isinstance(machines, list):
        return {}, f"{instance['id']}: /api/machines has no machines array"
    return {str(m["name"]): str(m["id"])
            for m in machines if isinstance(m, dict) and m.get("name") and m.get("id")}, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry",
                    default=os.environ.get("RE_REGISTRY_URL",
                                           "/tmp/re-registry/re-registry.json"))
    ap.add_argument("--machines", type=int, default=12,
                    help="How many machines to compare (default 12).")
    ap.add_argument("--all", action="store_true", help="Compare every shared machine.")
    ap.add_argument("--out", help="Write the full report to this path.")
    args = ap.parse_args()

    try:
        instances = read_instances(args.registry)
    except Exception as exc:  # noqa: BLE001
        print(f"instance registry unreadable at {args.registry}: {exc}", file=sys.stderr)
        return 2

    report: dict = {"quorumComposition": [i["id"] for i in instances],
                    "compared": [], "failures": []}
    print(f"quorum composition: {', '.join(report['quorumComposition']) or '(empty)'}")
    if len(instances) < 2:
        print("fewer than two runtimes — nothing to compare", file=sys.stderr)
        return 1

    catalogs: dict[str, dict[str, str]] = {}
    for instance in instances:
        catalog, err = machines_by_name(instance)
        if err:
            report["failures"].append(err)
            print(f"  ✗ {err}")
            continue
        catalogs[instance["id"]] = catalog
    if len(catalogs) < len(instances):
        print("\nQUORUM NOT FORMED — not comparing")
        _write(args.out, report)
        return 1

    shared = sorted(set.intersection(*(set(c) for c in catalogs.values())))
    if not shared:
        report["failures"].append("no machine is held by every runtime")
        print("\nFAIL no machine is held by every runtime")
        _write(args.out, report)
        return 1

    # Deterministic selection, so two runs of the gate compare the same
    # machines and a failure is reproducible without recording which were
    # picked. Sorted by name, then evenly spaced across the corpus rather than
    # taking the first N — the first N share a domain, and a domain is exactly
    # the scope a shape defect is likely to be confined to.
    selected = shared if args.all else [
        shared[i * len(shared) // min(args.machines, len(shared))]
        for i in range(min(args.machines, len(shared)))
    ]
    print(f"comparing {len(selected)} of {len(shared)} shared machines")

    failures = 0
    for name in selected:
        flats: dict[str, dict[str, Any]] = {}
        unreadable = False
        for instance in instances:
            rid = instance["id"]
            payload, err = get_json(
                f"{instance['re_url']}/api/machines/{catalogs[rid][name]}/export")
            if err:
                report["failures"].append(f"{rid}: export of {name!r} {err}")
                print(f"  ✗ {rid}: export of {name!r} {err}")
                unreadable = True
                continue
            flats[rid] = comparable(leaves(payload))
        if unreadable:
            failures += 1
            continue

        ids = sorted(flats)
        base_id, base = ids[0], flats[ids[0]]
        diffs: dict[str, dict[str, Any]] = {}
        for rid in ids[1:]:
            other = flats[rid]
            for path in sorted(set(base) | set(other)):
                if base.get(path) != other.get(path):
                    diffs.setdefault(path, {})[rid] = other.get(path, "<absent>")
                    diffs[path][base_id] = base.get(path, "<absent>")
        report["compared"].append({"machine": name, "differences": len(diffs)})
        if diffs:
            failures += 1
            line = f"{name}: {len(diffs)} differing path(s)"
            report["failures"].append(line)
            print(f"  ✗ {line}")
            # Name the paths. A count says the documents differ; the paths say
            # which field to look at, and that is the difference between a
            # finding and a ticket someone has to reproduce.
            for path, values in list(diffs.items())[:5]:
                rendered = ", ".join(f"{r}={str(v)[:40]!r}" for r, v in sorted(values.items()))
                print(f"      {path}: {rendered}")
            if len(diffs) > 5:
                print(f"      … and {len(diffs) - 5} more (see the report)")
            report.setdefault("differences", {})[name] = {
                p: v for p, v in list(diffs.items())[:50]}
        else:
            print(f"  ✓ {name}")

    print()
    if failures:
        print(f"FAIL {failures} of {len(selected)} machines export differently")
        _write(args.out, report)
        return 1
    print(f"PASS {len(selected)} machines export identically across "
          f"{len(instances)} runtimes")
    _write(args.out, report)
    return 0


def _write(path: str | None, report: dict) -> None:
    if path:
        Path(path).write_text(json.dumps(report, indent=2, sort_keys=True))
        print(f"report: {path}")


if __name__ == "__main__":
    sys.exit(main())
