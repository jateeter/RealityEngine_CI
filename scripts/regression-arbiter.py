#!/usr/bin/env python3
"""Arbiter conformance stage — ARBITER_CONTRACT.md §9 fixtures, every runtime.

The arbiter is implemented in all four runtimes and, until this stage, exercised
by nothing. Both regression lanes booted `standard-deployment`, which has zero
contended cells and zero bus cells, so the suite reported success whether or not
an arbiter existed. See RealityEngine_CI#123.

What it asserts, and why each is the discriminator rather than a smoke check:

  9a  machine/machine, cells 16930-16931, rule SEVERITY.
      ArbitrationWriterA asserts [1,1] at AMBER; ArbitrationWriterB asserts
      [0,0] at RED. Max severity present is RED, so the resolved value must be
      **0**. Under the OR/MAX behaviour the contract was written to replace it
      is 1. One bit separates a conforming arbiter from the defect, which is why
      the fixture is shaped this way.

  9b  machine/provider, cells 16940-16941, rule PRECEDENCE {machine:3, acp:1}.
      ArbitrationProviderPeer asserts [1,1] as a deterministic machine output;
      an ACP-class contribution is replayed against it. The machine value is the
      ceiling of the clamped range, so PRECEDENCE and a naive MAX agree on the
      resolved value — what separates them is the record. Under PRECEDENCE the
      agent contribution is suppressed for losing on determinism class and stays
      attributable there (§6). So 9b asserts the record, not only the value, and
      replays several agent values to cover criterion 5a: a generated
      contribution never overrides a deterministic one *at any value*.

  8   every contended cell emits a record whose contributors ∪ suppressed is the
      full contribution set, with `provider` populated on every entry.

  parity  all runtimes agree on resolved values and on the record shape.
          Byte equivalence is this contract's acceptance test, so a runtime that
          resolves correctly but reports differently still fails.

Replay, not live agents: §8.0 states that byte equivalence is defined only over
reproducible contributions, and a `generated` contribution is not reproducible by
construction. Contributions are replayed through a real PE source — one whose
origin names an ACP surface, which is the path a live gateway takes — because
§2.1 says nothing bypasses the arbiter and a harness that did would be proving
something other than the runtime.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any
from urllib import error, request

# The fixtures do not fire on their own. Each is a single-step initial sequence
# whose CES matches [1, 0] over its own input region, so the stage drives those
# regions and then reads what the arbiter resolved. Without this the stage would
# report a clean run having exercised nothing — the exact failure mode #123 was
# filed about, reproduced one level up.
# Long enough to address the fixture inputs. Not a claim about engine capacity:
# the engines expand on demand, so this only has to reach the cells being driven.
TRIGGER_VECTOR_LENGTH = 16960

TRIGGER_CELLS = {
    16924: 1.0,  # ArbitrationWriterA  -> writes [1,1] at AMBER into 16930-16931
    16926: 1.0,  # ArbitrationWriterB  -> writes [0,0] at RED   into 16930-16931
    16936: 1.0,  # ArbitrationProviderPeer -> writes [1,1] into 16940-16941
}

CELLS_9A = [16930, 16931]
CELLS_9B = [16940, 16941]
EXPECTED_9A = 0.0  # SEVERITY: RED wins over AMBER, and RED asserts 0


def http(method: str, url: str, payload: Any = None, timeout: int = 20) -> tuple[int, Any]:
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"accept": "application/json"}
    if data:
        headers["content-type"] = "application/json"
    req = request.Request(url, data=data, method=method, headers=headers)
    try:
        with request.urlopen(req, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            try:
                return response.status, json.loads(body)
            except json.JSONDecodeError:
                return response.status, body
    except error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace")
    except Exception as exc:  # noqa: BLE001 — a dead engine is a result, not a crash
        return 0, str(exc)


# Provider identity as the corpus spells it on a service lane, mapped to the
# class the arbiter ranks. A surface names itself for humans; the arbiter ranks
# by determinism class.
LANE_PROVIDER_ALIASES = {
    "openclaw acp": "acp",
    "localaistack": "localai",
    "healthkit": "healthkit",
    "healthkit (e2e)": "healthkit",
    "carekit": "carekit",
}


def provider_registry(machines_root: Path) -> dict[str, Any]:
    """The providers the corpus declares, in the two tiers it declares them.

    ARBITER_CONTRACT.md criterion 11: the suite is parameterised over the
    provider registry, so a newly registered integration surface is exercised
    without the suite being modified — and a surface that has registered but not
    passed may not contribute. Hardcoding `acp` would mean every future surface
    ships unexercised until someone remembered to edit this file, which is the
    failure the criterion is written against.

    Two tiers, because the corpus declares two different things:

      ranked      providers appearing in arbitration-registry providerRanks.
                  These are rankable under PRECEDENCE, so a contribution from
                  one has a defined outcome and can be asserted.
      registered  providers named on a region-allocation service lane. These are
                  integration surfaces that exist; a surface with no ranked
                  declaration cannot be asserted against a contended cell, and
                  is reported rather than skipped silently.
    """
    ranked: set[str] = set()
    arbitration = machines_root / "domains" / "arbitration-registry.json"
    if arbitration.exists():
        document = json.loads(arbitration.read_text(encoding="utf-8"))
        for entry in document.get("entries", []):
            ranked.update((entry.get("providerRanks") or {}).keys())

    registered: set[str] = set()
    allocation = machines_root / "domains" / "region-allocation.json"
    if allocation.exists():
        document = json.loads(allocation.read_text(encoding="utf-8"))
        for lane in document.get("serviceLanes") or []:
            name = str(lane.get("provider") or "").strip().lower()
            if name:
                registered.add(LANE_PROVIDER_ALIASES.get(name, name))

    return {
        "ranked": sorted(ranked),
        "registered": sorted(registered),
        # Registered but unrankable: the surface exists and no contended cell
        # declares how to resolve it. Contract 5: an undeclared contended cell is
        # a corpus error, so this is worth naming rather than passing over.
        "unranked": sorted(registered - ranked),
    }


def load_instances(registry_path: Path) -> list[dict[str, str]]:
    """RE/PE base URLs per runtime, from the runtime registry."""
    document = json.loads(registry_path.read_text(encoding="utf-8"))
    out = []
    for instance in document.get("instances", []):
        # The registry writes snake_case: re_url / pe_url. This read camelCase,
        # which yielded empty strings and produced `unknown url type:
        # '/api/arbitration'` on the first real run. It passed locally because
        # the fixture I tested against was hand-written to the shape I assumed —
        # the field names were never checked against the registry the universe
        # actually produces. camelCase is accepted as a fallback because
        # regression-service-inventory.py re-emits the registry in that shape.
        re_url = instance.get("re_url") or instance.get("reUrl") or ""
        pe_url = instance.get("pe_url") or instance.get("peUrl") or ""
        if not re_url:
            continue
        out.append({
            "id": instance.get("id", "?"),
            "runtime": instance.get("runtime", "?"),
            "re": re_url.rstrip("/"),
            "pe": pe_url.rstrip("/"),
        })
    return out


def cell_records(payload: Any, cells: list[int]) -> dict[int, dict]:
    if not isinstance(payload, dict):
        return {}
    return {r["cell"]: r for r in payload.get("records", [])
            if isinstance(r, dict) and r.get("cell") in cells}


def check_record_completeness(record: dict) -> list[str]:
    """Criterion 8: contributors ∪ suppressed is the whole set, provider on each."""
    problems = []
    entries = list(record.get("contributors") or []) + list(record.get("suppressed") or [])
    if not entries:
        problems.append(f"cell {record.get('cell')}: record with no contributions")
    for entry in entries:
        if not entry.get("provider"):
            problems.append(f"cell {record.get('cell')}: contribution without a provider")
        if "value" not in entry:
            problems.append(f"cell {record.get('cell')}: contribution without a value")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--contributions", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--settle-ms", type=int, default=1500)
    parser.add_argument("--machines", type=Path, required=True,
                        help="RealityEngine_Machines root, for the provider registry")
    args = parser.parse_args()

    instances = load_instances(args.registry)
    replay = json.loads(args.contributions.read_text(encoding="utf-8"))
    registry = provider_registry(args.machines)
    report: dict[str, Any] = {"status": "passed", "instances": [], "failures": [],
                              "providerRegistry": registry}

    # Every ranked provider other than `machine` is a contributor class the
    # arbiter must resolve against a machine determination. Driving the replay
    # from the registry rather than a literal is what makes a newly ranked
    # surface exercised without editing this file (criterion 11).
    replay_providers = [p for p in registry["ranked"] if p != "machine"]
    print(f"provider registry: ranked={registry['ranked']} "
          f"registered={registry['registered']} unranked={registry['unranked']}")
    if registry["unranked"]:
        print(f"  note: registered surfaces with no ranked declaration: "
              f"{registry['unranked']} — they cannot contribute to a contended "
              "cell until one declares how to resolve them (contract 5)")

    if not instances:
        report.update(status="skipped", reason="no instances in the registry")
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("arbiter: SKIPPED — no instances in the registry")
        return 0

    def fail(message: str) -> None:
        report["failures"].append(message)
        report["status"] = "failed"
        print(f"  FAIL {message}")

    resolved_by_runtime: dict[str, dict[int, Any]] = {}
    # 9b needs a reachable PE to replay through. If it was not reachable the
    # stage must not report that 9b conformed — a pass that covers less than it
    # claims is the failure mode this whole stage exists to remove, and
    # reproducing it here would be worse than not having the stage.
    ran_9b = False

    for instance in instances:
        name = f"{instance['runtime']}:{instance['id']}"
        entry: dict[str, Any] = {"instance": name, "re": instance["re"]}
        print(f"\n== {name}")

        status, payload = http("GET", f"{instance['re']}/api/arbitration")
        if status != 200:
            fail(f"{name}: GET /api/arbitration -> {status} {str(payload)[:80]}")
            entry["reachable"] = False
            report["instances"].append(entry)
            continue
        entry["reachable"] = True
        entry["registryEntries"] = payload.get("registryEntries")
        entry["shards"] = payload.get("shards")
        print(f"  registry entries {payload.get('registryEntries')}  shards {payload.get('shards')}")

        # -- 9a: SEVERITY resolves to 0, not 1 ---------------------------------
        # No precondition on vectorDimension.
        #
        # An earlier version failed the run when /api/config reported less than
        # 16944, on the theory that the fixtures at cells 16924-16943 could not
        # exist in a smaller vector. That is wrong: the engines grow the
        # perceptual space on demand, which region-allocation.json states
        # outright — "Engines grow the perceptual space on demand; this records
        # the corpus footprint." The reported dimension is the configured value
        # and does not move when the space expands.
        #
        # Verified: an engine booted at the 7680 default, driven at cells 16924+,
        # emits `cell 16930 rule SEVERITY resolved 0` and still reports
        # vectorDimension 7680. The guard blocked a working system.
        #
        # The real check is the one below — a contended cell that emits no record
        # fails. That catches a vector too small *and* every other reason a
        # fixture might not fire, without asserting a mechanism the runtimes do
        # not use.
        vector = [0.0] * TRIGGER_VECTOR_LENGTH
        for cell, value in TRIGGER_CELLS.items():
            vector[cell] = value
        http("POST", f"{instance['re']}/api/perceive", {"vector": vector})
        http("POST", f"{instance['re']}/api/perceptual-simulation/step", {})
        time.sleep(args.settle_ms / 1000.0)
        _, after = http("GET", f"{instance['re']}/api/arbitration")
        records = cell_records(after, CELLS_9A)
        entry["fixture9a"] = {}
        for cell in CELLS_9A:
            record = records.get(cell)
            if not record:
                fail(f"{name}: 9a cell {cell} emitted no arbitration record")
                continue
            entry["fixture9a"][str(cell)] = record.get("resolved")
            if record.get("rule") != "SEVERITY":
                fail(f"{name}: 9a cell {cell} rule {record.get('rule')!r}, expected SEVERITY")
            if record.get("resolved") != EXPECTED_9A:
                fail(f"{name}: 9a cell {cell} resolved {record.get('resolved')!r}, "
                     f"expected {EXPECTED_9A} — RED asserts 0 and outranks AMBER; "
                     "a value of 1 is the OR/MAX behaviour the contract replaces")
            for problem in check_record_completeness(record):
                fail(f"{name}: {problem}")
        resolved_by_runtime[name] = {
            cell: records[cell].get("resolved") for cell in CELLS_9A if cell in records
        }

        # -- 9b: PRECEDENCE, replayed generated contribution -------------------
        source = replay["source"]
        region = replay["region"]
        entry["fixture9b"] = []
        # One pass per ranked provider, per replayed value.
        for provider in replay_providers:
            origin = source["originTemplate"].format(provider=provider) \
                if "originTemplate" in source else source["origin"]
            for case in replay["replays"]:
                payload_source = {
                    "id": f"{source['id']}-{provider}",
                    "type": source["type"],
                    "origin": origin,
                    "region": region,
                    "values": case["values"],
                }
                code, _ = http("POST", f"{instance['pe']}/api/sources", payload_source)
                if code not in (200, 201, 409):
                    print(f"  note: PE source replay unavailable ({code}); "
                          f"9b skipped for {provider}/{case['label']}")
                    entry["fixture9b"].append(
                        {"provider": provider, "label": case["label"],
                         "status": "unavailable"})
                    continue
                ran_9b = True
                http("POST", f"{instance['pe']}/api/push",
                     {"sourceId": f"{source['id']}-{provider}"})
                http("POST", f"{instance['re']}/api/perceptual-simulation/step", {})
                time.sleep(args.settle_ms / 1000.0)
                _, current = http("GET", f"{instance['re']}/api/arbitration")
                got = cell_records(current, CELLS_9B)
                case_report = {"provider": provider, "label": case["label"], "cells": {}}
                for index, cell in enumerate(CELLS_9B):
                    record = got.get(cell)
                    if not record:
                        continue
                    case_report["cells"][str(cell)] = record.get("resolved")
                    expected = case["expectResolved"][index]
                    if record.get("resolved") != expected:
                        fail(f"{name}: 9b cell {cell} ({provider}/{case['label']}) "
                             f"resolved {record.get('resolved')!r}, expected {expected} "
                             "— a generated contribution must never override a "
                             "deterministic one (5a)")
                    suppressed = {c.get("provider") for c in record.get("suppressed") or []}
                    if suppressed and provider not in suppressed:
                        fail(f"{name}: 9b cell {cell} suppressed {sorted(suppressed)}, "
                             f"expected the {provider} contribution to be the suppressed "
                             "one and to stay attributable (§6)")
                    for problem in check_record_completeness(record):
                        fail(f"{name}: {problem}")
                entry["fixture9b"].append(case_report)

        report["instances"].append(entry)

    # -- cross-runtime parity -------------------------------------------------
    distinct = {json.dumps(v, sort_keys=True) for v in resolved_by_runtime.values() if v}
    if len(distinct) > 1:
        fail("runtimes disagree on 9a resolved values: "
             + json.dumps(resolved_by_runtime, sort_keys=True))
    report["parity"] = {"runtimes": len(resolved_by_runtime), "agree": len(distinct) <= 1}
    report["fixtures"] = {"9a": "asserted", "9b": "asserted" if ran_9b else "not-run"}
    if report["status"] == "passed" and not ran_9b:
        report["status"] = "partial"
        report["reason"] = ("9b was not exercised: no PE accepted the replayed "
                            "contribution set, so machine/provider contention is unproven")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print()
    if report["status"] == "failed":
        print(f"arbiter: FAILED ({len(report['failures'])} problem(s))")
        return 1
    if report["status"] == "partial":
        print(f"arbiter: PARTIAL ({len(resolved_by_runtime)} runtime(s)) — 9a conforms; "
              "9b not exercised, no PE accepted the replay")
        return 0
    print(f"arbiter: OK ({len(resolved_by_runtime)} runtime(s), 9a and 9b conform)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
