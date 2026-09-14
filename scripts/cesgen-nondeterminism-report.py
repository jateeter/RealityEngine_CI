#!/usr/bin/env python3
"""Name the machines whose CES evaluation is not deterministic.

**Why any difference is a defect.** A Critical Event Sequence is a
representation of a regular expression. Three runtimes evaluating the same
expression over the same input must produce the same result, and the same
runtime must produce it again on a later run. There is no acceptable variance
here — so `disagreement` (runtimes differ from each other) and `intermittent`
(a runtime differs from itself) are two shapes of one defect, not a defect and
a tolerance.

This is why the report does not summarise. A count tells you a domain is
unstable; it cannot tell you which machine to open, and the machine is the unit
someone can actually fix.

Compares two sets of CES contract shards — typically a prior recording against a
fresh one over an unchanged corpus — and attributes every difference to a
machine file:

  verdict-moved   the same chain classified differently between runs
  stream-differs  both runs called it agreed, but the recorded output differs
  appeared/vanished  a chain present in one run and not the other

Usage:
  scripts/cesgen-nondeterminism-report.py --baseline DIR --current DIR [--json OUT]
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

VERDICT_KEYS = ("contracts", "disagreements", "intermittent",
                "noRuntimeEmits", "unmeasurable")
VERDICT_NAME = {"contracts": "agreed", "disagreements": "disagreement",
                "intermittent": "intermittent", "noRuntimeEmits": "no-runtime-emits",
                "unmeasurable": "unmeasurable"}


def load(shard: Path) -> dict[str, dict[str, Any]]:
    """chain id -> {verdict, stream, machineFile} for every chain in a shard."""
    try:
        doc = json.loads(shard.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    out: dict[str, dict[str, Any]] = {}
    for key in VERDICT_KEYS:
        for entry in doc.get(key, []):
            chain = entry.get("chain")
            if not chain:
                continue
            out[chain] = {
                "verdict": VERDICT_NAME[key],
                "machineFile": entry.get("machineFile") or chain.split("::")[0],
                # Only `agreed` carries a single authoritative stream; the others
                # carry clusters or nothing, and comparing those would report
                # presentation order as behaviour.
                "stream": entry.get("outputStream") if key == "contracts" else None,
            }
    return out


def compare(baseline: Path, current: Path) -> dict[str, Any]:
    findings: dict[str, list[dict[str, Any]]] = defaultdict(list)
    scopes: dict[str, dict[str, int]] = {}

    for cur_shard in sorted(current.glob("*.json")):
        base_shard = baseline / cur_shard.name
        if not base_shard.is_file():
            continue
        a, b = load(base_shard), load(cur_shard)
        scope = cur_shard.stem
        counts = {"verdict-moved": 0, "stream-differs": 0, "appeared": 0, "vanished": 0}

        for chain in sorted(set(a) | set(b)):
            ea, eb = a.get(chain), b.get(chain)
            if ea and not eb:
                kind, detail = "vanished", {"was": ea["verdict"]}
            elif eb and not ea:
                kind, detail = "appeared", {"now": eb["verdict"]}
            elif ea["verdict"] != eb["verdict"]:
                kind, detail = "verdict-moved", {"was": ea["verdict"], "now": eb["verdict"]}
            elif ea["verdict"] == "agreed" and ea["stream"] != eb["stream"]:
                kind, detail = "stream-differs", {"verdict": "agreed"}
            else:
                continue
            counts[kind] += 1
            findings[(eb or ea)["machineFile"]].append(
                {"scope": scope, "chain": chain, "kind": kind, **detail})
        scopes[scope] = counts

    machines = {m: sorted(v, key=lambda f: f["chain"]) for m, v in findings.items()}
    return {
        "purpose": ("Machines whose CES evaluation differed between two recordings of an "
                    "unchanged corpus. A CES is a regular expression; any difference is a "
                    "defect, not variance."),
        "machineCount": len(machines),
        "chainCount": sum(len(v) for v in machines.values()),
        "byScope": scopes,
        "machines": dict(sorted(machines.items(),
                                key=lambda kv: (-len(kv[1]), kv[0]))),
    }


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--baseline", type=Path, required=True)
    p.add_argument("--current", type=Path, required=True)
    p.add_argument("--json", type=Path, help="also write the full finding set here")
    args = p.parse_args()

    report = compare(args.baseline, args.current)
    if not report["machines"]:
        print("no non-determinism: every chain classified identically in both recordings")
        return 0

    print(f"{report['machineCount']} machine(s) differed across "
          f"{report['chainCount']} chain(s)\n")
    width = max(len(m) for m in report["machines"])
    for machine, fs in report["machines"].items():
        kinds = defaultdict(int)
        for f in fs:
            kinds[f["kind"]] += 1
        print(f"  {machine:<{width}}  {len(fs):>3} chain(s)  "
              + ", ".join(f"{n} {k}" for k, n in sorted(kinds.items())))
        for f in fs[:3]:
            moved = (f"{f.get('was','?')} -> {f.get('now','?')}"
                     if f["kind"] == "verdict-moved" else f["kind"])
            print(f"      {f['chain'].split('::', 1)[-1]}  [{moved}]")
        if len(fs) > 3:
            print(f"      ... and {len(fs) - 3} more")
    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(f"\nfull findings -> {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
