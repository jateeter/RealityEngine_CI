#!/usr/bin/env python3
"""Enforce the corpus exit criteria across repo boundaries (#118).

`RealityEngine_Machines/docs/CORPUS_EXIT_CRITERIA.md` §3.7 states what makes a
dependent regeneration correct. Every part of it is checkable, and none of it was
checked by anything: `corpus-gates` sees only RealityEngine_Machines, so the
corpus↔agent contract — the thing the criteria exist to protect — had no gate on
either side of the boundary.

That gap is not theoretical. Regenerating the agent corpus for
localOpenClawStack#25 produced two regressions that only the criteria caught:
1,328 agent specs instead of 1,323, because the arbitration conformance fixtures
must stay agent-free; and a `--fresh` run that deleted
`agents/profiles/regression.txt`, silently breaking the regression lane.

Checks, in the order §3 states them:

  §3.2  the join key is normalised `machine.name`, and it joins everything
  §3.3  the counts reconcile, and the 5 uncovered are the arbitration fixtures
  §3.4  observe-mode bindings are egress-only
  §3.7  axis names agree between corpus and sidecar

Skips cleanly when localOpenClawStack is absent, so it can run in a job that has
only the corpus checked out — it then verifies the corpus-side facts alone.

Usage:
  check-corpus-exit-criteria.py --machines <dir> [--openclaw <dir>]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

EXPECTED_MACHINES = 1328
EXPECTED_DOMAINS = 12
EXPECTED_AGENTS = 1323
EXPECTED_AGENT_BINDINGS = 1058
EXPECTED_PROJECTIONS = 1185
# Deliberately agent-free: an agent is a `generated` contributor, which is the
# non-determinism these fixtures exist to disprove (criteria §3.3).
EXPECTED_UNCOVERED = {
    "ArbitrationProviderPeer",
    "ArbitrationProviderTarget",
    "ArbitrationReader",
    "ArbitrationWriterA",
    "ArbitrationWriterB",
}


def norm(value: object) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def load_machine(path: Path) -> dict:
    document = json.loads(path.read_text(encoding="utf-8"))
    return document.get("machine", document)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--machines", required=True, type=Path)
    parser.add_argument("--openclaw", type=Path, default=None)
    args = parser.parse_args()

    domains_dir = args.machines / "machines" / "domains"
    if not domains_dir.is_dir():
        print(f"exit-criteria: FAIL no corpus at {domains_dir}", file=sys.stderr)
        return 1

    failures: list[str] = []

    def check(ok: bool, label: str, detail: str = "") -> None:
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    # ---- §3.1 corpus shape ----------------------------------------------
    machine_paths = sorted(domains_dir.glob("*/*.json"))
    domains = {path.parent.name for path in machine_paths}
    check(len(machine_paths) == EXPECTED_MACHINES, "§3.1 machine count",
          f"{len(machine_paths)} (expected {EXPECTED_MACHINES})")
    check(len(domains) == EXPECTED_DOMAINS, "§3.1 domain count",
          f"{len(domains)} (expected {EXPECTED_DOMAINS})")

    # ---- §3.2 identity ---------------------------------------------------
    by_name: dict[str, str] = {}
    binding_count = projection_count = 0
    observe_with_writeback: list[str] = []
    corpus_axes: dict[str, list] = {}
    for path in machine_paths:
        machine = load_machine(path)
        metadata = machine.get("metadata") or {}
        name = machine.get("name")
        if name:
            by_name[norm(name)] = path.stem
        binding = metadata.get("agentBinding") or {}
        projection = metadata.get("openClawProjection") or {}
        if binding:
            binding_count += 1
            if binding.get("mode") == "observe":
                policy = binding.get("autonomyPolicy") or {}
                if policy.get("canWriteBack") or policy.get("writeBackType") not in (None, "none"):
                    observe_with_writeback.append(path.stem)
        if projection:
            projection_count += 1
            if projection.get("semantics"):
                corpus_axes[norm(name)] = list(projection["semantics"])

    check(len(by_name) == len(machine_paths), "§3.2 machine.name is unique",
          f"{len(by_name)} distinct names for {len(machine_paths)} machines")

    # ---- §3.3 / §3.4 corpus-side counts ----------------------------------
    check(binding_count == EXPECTED_AGENT_BINDINGS, "§3.3 agentBinding count",
          f"{binding_count} (expected {EXPECTED_AGENT_BINDINGS})")
    check(projection_count == EXPECTED_PROJECTIONS, "§3.3 openClawProjection count",
          f"{projection_count} (expected {EXPECTED_PROJECTIONS})")
    check(not observe_with_writeback, "§3.4 observe bindings are egress-only",
          f"{len(observe_with_writeback)} with a write-back: {observe_with_writeback[:3]}")

    # ---- cross-repo: only when the agent corpus is present ----------------
    agents_dir = args.openclaw / "machine-behaviors" / "agents" if args.openclaw else None
    if not agents_dir or not agents_dir.is_dir():
        print("  skip  §3.3/§3.7 agent corpus — localOpenClawStack not checked out")
    else:
        specs = sorted(agents_dir.glob("*/*.oc-agent.json"))
        agent_axes: dict[str, list] = {}
        joined: set[str] = set()
        orphans: list[str] = []
        for spec_path in specs:
            spec = json.loads(spec_path.read_text(encoding="utf-8"))
            machine = spec.get("machine") or {}
            key = norm(machine.get("name"))
            if key in by_name:
                joined.add(by_name[key])
            else:
                orphans.append(spec_path.name)
            write_back = (spec.get("agentBinding") or {}).get("writeBack") or {}
            if write_back.get("semantics"):
                agent_axes[key] = list(write_back["semantics"])

        check(len(specs) == EXPECTED_AGENTS, "§3.3 agent spec count",
              f"{len(specs)} (expected {EXPECTED_AGENTS})")
        check(not orphans, "§3.2 every agent joins a machine",
              f"{len(orphans)} orphans: {orphans[:3]}")
        uncovered = {path.stem for path in machine_paths} - joined
        check(uncovered == EXPECTED_UNCOVERED, "§3.3 uncovered machines are the fixtures",
              f"{sorted(uncovered)}")

        mismatched = [key for key, names in agent_axes.items()
                      if key in corpus_axes and corpus_axes[key] != names]
        check(not mismatched, "§3.7 axis names match the corpus exactly",
              f"{len(mismatched)} mismatched")

    print()
    if failures:
        print(f"exit-criteria: FAIL ({len(failures)}) — " + "; ".join(failures))
        return 1
    print("exit-criteria: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
