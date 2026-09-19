#!/usr/bin/env python3
"""
regression-machine-set-parity.py — do the runtimes hold the same corpus?

**This is a precondition of every parity result, not one result among them.**
If the runtimes hold different machines, a trajectory or byte comparison is
measuring stimulus rather than behaviour, and it reports the difference as an
engine divergence. `scripts/CLAUDE.md` already names that hazard for sources:

  > Sources must be equalised before anything is compared. An active source one
  > PE has and another does not is stimulus, and the trajectory comparison will
  > faithfully report the difference as engine divergence.

The same is true of machines, and there was no gate for it. Scala once ran with
six extra `localai/*` machines — 1344 against cpp and lsp's 1338 — and every
parity stage passed. It was found by the CES contract recorder, long after a
load-count check should have caught it (RealityEngine_Scala#114, #356).

## Why a stage of its own

The comparison already existed, correctly, inside
`regression-reset-contract.py::compare_machines`. It does not fire, for a reason
that is structural rather than an oversight:

  - that stage returns at its **availability** check if any runtime's PE does
    not answer `POST /api/reset`, and load parity is computed after it. Measured
    on a live universe with one PE down, `loadParity.ok` is `null` — not false,
    not true, never run;
  - and it is written against RealityEngine_CI#163's settled contract rather
    than current behaviour, so it announces that its failures are expected. A
    machine-set split landing among expected failures is a split nobody acts on.

Machine-set parity needs **one `GET /api/machines` per runtime**. It needs no
PE, no reset, no seeded source and no settled contract, so it has no business
sharing a stage with any of them.

## What it compares

Corpus **names**. Machine ids are minted per runtime — the same corpus machine
is `machine-1789677668723-235803635` on C++ and `machine-1U4PASL-6KJA1USAFM6O`
on LSP — so comparing them would require an equality id generation forbids
(SURFACE_SPEC, "Byte equivalence applies"; #146, #397). Names are corpus-declared
and asserted globally unique (RealityEngine_Machines `name_uniqueness_test.py`).

Order is **not** compared. `GET /api/machines` declares no order, and a field
that carries no order but is compared as though it does cannot be checked at all
(#197). The comparison is over sets, and the report names the machines that
differ rather than the position at which they do.

Quorum is 3-of-3 (`docs/QUORUM_CONTRACT.md`). A runtime that does not answer is
not agreement: the composition is reported up front, and a runtime whose corpus
could not be read is a failure rather than an absent row.

Usage:
  python3 scripts/regression-machine-set-parity.py
  python3 scripts/regression-machine-set-parity.py --registry http://127.0.0.1:5999/re-registry.json
  python3 scripts/regression-machine-set-parity.py --out report.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from urllib import error, request


def read_instances(source: str) -> list[dict]:
    """The instance registry, from a URL or a path."""
    if source.startswith(("http://", "https://")):
        with request.urlopen(source, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    else:
        payload = json.loads(Path(source).read_text(encoding="utf-8"))
    return payload.get("instances", [])


def machine_names(instance: dict) -> tuple[set[str], str | None]:
    """The corpus this runtime holds, by name, or a reason it could not be read.

    An unreadable corpus is reported as an error and never as an empty set. The
    two are different findings — "this runtime holds nothing" and "this runtime
    would not say" — and collapsing them would let a dead engine read as a
    machine-set divergence, or worse, let two dead engines agree.
    """
    url = f"{instance['re_url']}/api/machines"
    try:
        with request.urlopen(url, timeout=300) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        return set(), f"{instance['id']}: GET /api/machines returned {exc.code}"
    except (error.URLError, OSError, ValueError) as exc:
        return set(), f"{instance['id']}: {type(exc).__name__}: {exc}"

    machines = payload.get("machines", payload)
    if not isinstance(machines, list):
        return set(), f"{instance['id']}: /api/machines payload has no machines array"
    names = {str(m.get("name")) for m in machines if isinstance(m, dict) and m.get("name")}
    if len(names) != len(machines):
        # Two machines under one name on a single runtime. Not a cross-runtime
        # finding, but it makes the set comparison below lie by one, so it is
        # reported rather than silently deduplicated.
        return names, (f"{instance['id']}: {len(machines)} machines but "
                       f"{len(names)} distinct names — duplicates on one runtime")
    return names, None


def cluster(sets: dict[str, set[str]]) -> list[list[str]]:
    """Group runtimes by the corpus they hold, largest group first."""
    groups: dict[str, list[str]] = {}
    for rid, names in sorted(sets.items()):
        groups.setdefault(json.dumps(sorted(names)), []).append(rid)
    return sorted(groups.values(), key=lambda g: (-len(g), g[0]))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry",
                    default=os.environ.get("RE_REGISTRY_URL",
                                           "/tmp/re-registry/re-registry.json"))
    ap.add_argument("--out", help="Write the full report to this path.")
    args = ap.parse_args()

    try:
        instances = read_instances(args.registry)
    except Exception as exc:  # noqa: BLE001 — the registry being unreadable is the message
        print(f"instance registry unreadable at {args.registry}: {exc}", file=sys.stderr)
        return 2

    report: dict = {"quorumComposition": [i["id"] for i in instances],
                    "counts": {}, "failures": []}
    print(f"quorum composition: {', '.join(report['quorumComposition']) or '(empty)'}")

    if len(instances) < 2:
        print("fewer than two runtimes — nothing to compare", file=sys.stderr)
        report["failures"].append("fewer than two runtimes in the instance registry")
        _write(args.out, report)
        return 1

    sets: dict[str, set[str]] = {}
    for instance in instances:
        names, err = machine_names(instance)
        if err:
            report["failures"].append(err)
            print(f"  ✗ {err}")
            if not names:
                continue
        sets[instance["id"]] = names
        report["counts"][instance["id"]] = len(names)
        print(f"  {instance['id']}: {len(names)} machines")

    # A runtime that did not answer is not agreement. Refuse rather than compare
    # the remainder and print a verdict that reads like parity.
    if len(sets) < len(instances):
        print("\nQUORUM NOT FORMED — not comparing")
        _write(args.out, report)
        return 1

    groups = cluster(sets)
    if len(groups) > 1:
        shape = " | ".join("+".join(g) for g in groups)
        report["failures"].append(f"runtimes hold different machine sets: {shape}")
        print(f"\nFAIL runtimes hold different machine sets: {shape}")

        # Name the machines, not just the counts. A count difference says a
        # split exists; the names say which machine to look at, and that is the
        # difference between a finding and a ticket someone has to reproduce.
        union: set[str] = set().union(*sets.values())
        report["differences"] = {}
        for name in sorted(union):
            holders = sorted(rid for rid, names in sets.items() if name in names)
            if len(holders) != len(sets):
                missing = sorted(set(sets) - set(holders))
                report["differences"][name] = {"heldBy": holders, "absentFrom": missing}
                print(f"    {name}: held by {'+'.join(holders)}, absent from {'+'.join(missing)}")
        _write(args.out, report)
        return 1

    print(f"\nPASS all {len(sets)} runtimes hold the same "
          f"{len(next(iter(sets.values())))} machines")
    _write(args.out, report)
    return 0


def _write(path: str | None, report: dict) -> None:
    if path:
        Path(path).write_text(json.dumps(report, indent=2, sort_keys=True))
        print(f"report: {path}")


if __name__ == "__main__":
    sys.exit(main())
