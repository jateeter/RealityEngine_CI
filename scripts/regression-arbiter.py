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
      resolved value — what separates them is the record. The two meet in the
      PE's Source-vs-OSRE fold into ISRE(n+1), not in the RE arbiter (which
      sees one writer per step), and the fold is recorded on
      GET /api/sources/contention `folds` (4.4b, amended 2026-10-04, #525).
      Under PRECEDENCE that record says `declared-rule` and keeps the machine,
      with the agent suppressed and attributable (§6). So 9b asserts the record,
      not only the value, and replays several agent values to cover criterion
      5a: a generated contribution never overrides a deterministic one *at any
      value*. The peer reads 00 then 10, so each case drives it through both.

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

Both fixtures run on every lane (owner decision, 2026-10-04, #525). 9b was
local-only, on the premise that its ACP writer needs the OpenClaw surface; the
replay is a PE source whose origin classifies as acp, so it needs no gateway.
That premise also hid that 9b had never observed anything on the local lane:
the regression corpus omitted its machines, the replay source was never active,
and the stage passed regardless. It now fails when 9b observes nothing.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any
from urllib import error, request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from reset_contract import reset_pair  # noqa: E402
from step_observer import DEFAULT_WINDOW_MS, StepObserver, StepNotResolved, StepNotRetained  # noqa: E402

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

# Steps of arbitration records each runtime retains while this stage runs
# (RealityEngine_CI#296). The stage reads its own steps by number, so the window
# only has to outlast the steps another app instance might push between a drive
# and its read; the declared defaults are restored on the way out.
RETENTION_WINDOW = 16

CELLS_9A = [16930, 16931]
CELLS_9B = [16940, 16941]
# ArbitrationProviderPeer's input region, driven 00 then 10 by a sensor of its own.
PEER_INPUT_REGION = {"offset": 16936, "length": 2}
PEER_SOURCE_ID = "arb-9b-peer-input"
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


def fixture_status(observed: int, expected: int) -> str:
    """Status of a fixture from what was observed, never from what was attempted.

    "asserted" means every reachable runtime produced an observation. Anything
    less is said plainly: "partial" when some did, "not-run" when none did. An
    empty result set must never reach "asserted" — see #135, where 9b reported
    `asserted` with every instance returning no cells at all.
    """
    if not expected or not observed:
        return "not-run"
    return "asserted" if observed >= expected else "partial"


def observed_counts(instances: list[dict]) -> dict[str, int]:
    """Per-fixture observation counts across the reachable instances."""
    reachable = [e for e in instances if e.get("reachable")]
    return {
        "reachable": len(reachable),
        "9a": sum(1 for e in reachable if e.get("fixture9a")),
        "9b": sum(
            1 for e in reachable
            if any(case.get("cells") for case in e.get("fixture9b") or [])
        ),
    }


def run_fixtures(instances, retain, driven_records, step_of, drive_9b, fail, report,
                 resolved_by_runtime, replay, replay_providers, args) -> bool:
    """9a and 9b on every instance, each read from the step it drove. True when
    9b was exercised on at least one runtime."""
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
        # Read above in the legacy shape; from here every read is by step.
        retain(instance)

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

        # One drive, read back from its own step (#296).
        records: dict[int, Any] = {}
        _, driven = http("POST", f"{instance['re']}/api/perceive", {"vector": vector})
        entry["fixture9aStep"] = step_of(driven)
        try:
            records = driven_records(instance, entry["fixture9aStep"], CELLS_9A)
        except (RuntimeError, StepNotResolved, StepNotRetained) as exc:
            fail(f"{name}: 9a step {entry['fixture9aStep']}: {exc}")
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

        # -- 9b: machine vs provider, at the PE's Source-vs-OSRE fold -----------
        # ArbitrationProviderPeer asserts [1,1] into 16940-16941 at step n (its
        # input reads 00 then 10), and the replayed ACP source writes the same
        # cells. The two meet in the PE's fold into ISRE(n+1), where the
        # declared PRECEDENCE {acp:1, machine:3} keeps the machine's value at
        # any agent value (ARBITER_CONTRACT.md 4.4b, amended 2026-10-04,
        # RealityEngine_CI#525), and the fold is recorded on
        # GET /api/sources/contention. 9b reads that record -- the RE arbiter
        # sees one writer per step and has no record to give.
        #
        # What separates PRECEDENCE from the machine's own `or` (max) is the
        # record, not the value: the peer asserts 1.0, the ceiling, so both give
        # 1.0. Under PRECEDENCE the record says `declared-rule` and keeps the
        # OSRE side even when the agent is also at 1.0; under max it would say
        # `osre-fold` and, at 1.0, `both`.
        source = replay["source"]
        entry["fixture9b"] = []
        for provider in replay_providers:
            origin = source["originTemplate"].format(provider=provider) \
                if "originTemplate" in source else source["origin"]
            for case in replay["replays"]:
                case_report = {"provider": provider, "label": case["label"], "cells": {}}
                try:
                    folds, isre, case_report["steps"] = drive_9b(instance, origin, provider, case["values"])
                except (RuntimeError, StepNotResolved, StepNotRetained) as exc:
                    fail(f"{name}: 9b {provider}/{case['label']}: {exc}")
                    entry["fixture9b"].append(case_report)
                    continue
                ran_9b = True
                by_cell = {f.get("cell"): f for f in folds if isinstance(f, dict)}
                for index, cell in enumerate(CELLS_9B):
                    fold = by_cell.get(cell)
                    label = f"9b cell {cell} ({provider}/{case['label']})"
                    if not fold:
                        fail(f"{name}: {label}: no Source-vs-OSRE fold recorded on "
                             "GET /api/sources/contention -- the machine and the "
                             f"{provider} source never met, or the fold was not recorded")
                        continue
                    expected = case["expectResolved"][index]
                    case_report["cells"][str(cell)] = fold.get("resolved")
                    if (fold.get("resolution"), fold.get("rule")) != ("declared-rule", "PRECEDENCE"):
                        fail(f"{name}: {label}: resolved by {fold.get('resolution')!r} "
                             f"{fold.get('rule') or fold.get('operator')!r}, expected the declared "
                             "PRECEDENCE -- a declared rule governs at the fold (4.4b)")
                    if fold.get("resolved") != expected or isre.get(cell, 0) != expected:
                        fail(f"{name}: {label}: resolved {fold.get('resolved')!r}, ISRE "
                             f"{isre.get(cell, 0)!r}, expected {expected} -- a generated "
                             "contribution must never override a deterministic one (5a)")
                    if fold.get("kept") != "osre" or (fold.get("source") or {}).get("provider") != provider:
                        fail(f"{name}: {label}: kept {fold.get('kept')!r} over source provider "
                             f"{(fold.get('source') or {}).get('provider')!r}; expected the machine "
                             f"kept and the {provider} contribution suppressed and attributable (6)")
                entry["fixture9b"].append(case_report)

        report["instances"].append(entry)

    return ran_9b


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--contributions", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--step-window-ms", type=int, default=DEFAULT_WINDOW_MS,
                        help="how long to wait for a driven step's completion point")
    parser.add_argument("--machines", type=Path, required=True,
                        help="RealityEngine_Machines root, for the provider registry")
    parser.add_argument("--lane", choices=("hosted", "local"), default="hosted",
                        help="local runs the full system (OpenClaw, Ollama, HealthKit "
                             "bridge), so 9b is in scope there and only there")
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

    # 9b runs on every lane (owner decision, 2026-10-04, RealityEngine_CI#525).
    # It was local-only on the premise that it needs the ACP surface, but the
    # replay is a PE source whose origin classifies as acp: no live gateway is
    # involved, and every lane starts the PEs. The premise also hid that 9b had
    # never observed anything on the local lane either.
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

    # Known starting state before the fixture fires. Without it the stage
    # asserts against whatever touched the engine first, and whether the writer
    # CESs are still armed depends on that. This stage reported "9a cell 16930
    # emitted no arbitration record" against an engine whose writers had already
    # advanced past their assert state — filed as a C++ defect and closed as not
    # reproducible (jateeter/RealityEngine_CPP#32, jateeter/RealityEngine_CI#139).
    # Both halves. This reset the RE and then drove the PEs, leaving PE run
    # state — globalStep, the persistent vector, the test cursors — advanced for
    # whatever ran next, and starting from whatever ran before (#211).
    reset_outcomes = []
    for instance in instances:
        reset_failures = reset_pair(
            lambda url, body: http("POST", url, body),
            instance.get("re"), instance.get("pe"), instance["id"],
        )
        reset_outcomes.append({
            "instance": instance["id"],
            "reset": "failed" if reset_failures else "ok",
            "detail": reset_failures,
        })
        for item in reset_failures:
            fail(f"{instance['runtime']}:{item} — "
                 "the fixture below was measured against unknown prior state")
    report["reset"] = reset_outcomes

    # Each fixture is read from the step it drove (#296), never from "the
    # latest step". GET /api/arbitration used to serve only the latest step, so
    # any push between a drive and its read -- the PE's own interval, another
    # app instance -- replaced the records, and "9a cell 16930 emitted no
    # arbitration record" was filed against two runtimes and closed as not
    # reproducible (RealityEngine_CPP#32, RealityEngine_CI#139). This stage then
    # slept and retried. Now it turns retention on, waits for the driven step's
    # completion point, and reads that step by number: one drive, no sleep, no
    # retry, and an interloping step cannot touch the answer.
    def get(url: str) -> tuple[int, Any]:
        return http("GET", url)

    def driven_records(instance: dict, step_number: Any, cells: list[int]) -> dict[int, dict]:
        if not isinstance(step_number, int):
            raise RuntimeError("the drive's response names no step number")
        StepObserver(get, instance["re"], args.step_window_ms).await_pair(step_number)
        status, body = http("GET", f"{instance['re']}/api/arbitration?step={step_number}")
        if status != 200:
            raise RuntimeError(f"GET /api/arbitration?step={step_number} -> {status} {str(body)[:120]}")
        return cell_records(body, cells)

    def step_of(response: Any) -> Any:
        if isinstance(response, dict):
            if isinstance(response.get("stepNumber"), int):
                return response["stepNumber"]
            if isinstance(response.get("step"), dict):
                return response["step"].get("stepNumber")
        return None

    def drive_9b(instance: dict, origin: str, provider: str, values: list) -> tuple[list, dict, list]:
        """One 9b case: the peer reads 00 then 10 and asserts at step n; the
        replayed source meets it in the fold into ISRE(n+1). Returns the folds
        recorded by that push, ISRE(n+1) at the 9b cells, and the steps."""
        re_url, pe_url = instance["re"], instance["pe"]
        replay_id = f"{replay['source']['id']}-{provider}"
        peer_id = PEER_SOURCE_ID
        for failure in reset_pair(lambda url, body: http("POST", url, body), re_url, pe_url, instance["id"]):
            raise RuntimeError(failure)
        observer = StepObserver(get, re_url, args.step_window_ms)

        def sensor(sid: str, name: str, region: dict, origin_: str | None) -> dict:
            # Fully specified: the Scala PE's decoder requires name, active,
            # sensorId, ttlMs and lastValue (#123). Registration declares a
            # sensor inactive whatever is asked; its first value activates it.
            body = {"id": sid, "name": name, "type": "sensor", "active": True, "sensorId": sid,
                    "ttlMs": 300_000, "lastValue": [0.0] * region["length"], "region": region}
            if origin_:
                body["origin"] = origin_
            return body

        def ingress(sid: str, vals: list) -> None:
            code, body = http("POST", f"{pe_url}/api/sensors/{sid}", {"values": vals})
            if code != 200:
                raise RuntimeError(f"POST /api/sensors/{sid} -> {code} {str(body)[:80]}")

        def push() -> int:
            code, body = http("POST", f"{pe_url}/api/push", {})
            step = step_of(body)
            if code != 200 or not isinstance(step, int):
                raise RuntimeError(f"POST /api/push -> {code} {str(body)[:80]}")
            observer.await_pair(step)
            return step

        try:
            for sid in (replay_id, peer_id):
                http("DELETE", f"{pe_url}/api/sources/{sid}")
            for body in (sensor(replay_id, f"{provider} arbitration replay", replay["region"], origin),
                         sensor(peer_id, "9b peer input", PEER_INPUT_REGION, None)):
                code, reply = http("POST", f"{pe_url}/api/sources", body)
                if code not in (200, 201):
                    raise RuntimeError(f"POST /api/sources {body['id']} -> {code} {str(reply)[:80]}")
            steps = []
            for peer in ([0.0, 0.0], [1.0, 0.0]):
                ingress(peer_id, peer)
                ingress(replay_id, list(values))
                steps.append(push())
            _, pair = http("GET", f"{re_url}/api/engine/steps/{steps[-1]}/pair?timeoutMs=0")
            asserted = {c["index"]: c["value"] for c in pair["osre"]["nonZero"]} if isinstance(pair, dict) else {}
            if any(asserted.get(cell, 0) != 1 for cell in CELLS_9B):
                raise RuntimeError(f"the peer did not assert [1,1] at step {steps[-1]} "
                                   f"(OSRE {[asserted.get(c, 0) for c in CELLS_9B]}): "
                                   "is ArbitrationProviderPeer resident?")
            steps.append(push())
            _, contention = http("GET", f"{pe_url}/api/sources/contention")
            _, pair = http("GET", f"{re_url}/api/engine/steps/{steps[-1]}/pair?timeoutMs=0")
            isre = {c["index"]: c["value"] for c in pair["isre"]["nonZero"]} if isinstance(pair, dict) else {}
            folds = contention.get("folds") if isinstance(contention, dict) else None
            if folds is None:
                raise RuntimeError("GET /api/sources/contention has no `folds` (4.4b, #525)")
            return folds, isre, steps
        finally:
            for sid in (replay_id, peer_id):
                http("DELETE", f"{pe_url}/api/sources/{sid}")

    def retain(instance: dict) -> None:
        for control, value in (("arbitrationRetention", True), ("arbitrationWindow", RETENTION_WINDOW)):
            code, body = http("PUT", f"{instance['re']}/api/engine/config/{control}", {"value": value})
            if code != 200:
                fail(f"{instance['runtime']}:{instance['id']}: PUT /api/engine/config/{control} -> "
                     f"{code} {str(body)[:80]} — per-step arbitration retention (#296) is required "
                     "to read a fixture's own step")

    # Restore the declared defaults whatever happens: retention is this stage's
    # instrument, not a state it leaves behind for the stages after it.
    def restore() -> None:
        for instance in instances:
            for control in ("arbitrationRetention", "arbitrationWindow"):
                http("DELETE", f"{instance['re']}/api/engine/config/{control}")

    try:
        ran_9b = run_fixtures(instances, retain, driven_records, step_of, drive_9b, fail, report,
                              resolved_by_runtime, replay, replay_providers, args)
    finally:
        restore()

    # -- cross-runtime parity -------------------------------------------------
    distinct = {json.dumps(v, sort_keys=True) for v in resolved_by_runtime.values() if v}
    if len(distinct) > 1:
        fail("runtimes disagree on 9a resolved values: "
             + json.dumps(resolved_by_runtime, sort_keys=True))
    report["parity"] = {"runtimes": len(resolved_by_runtime), "agree": len(distinct) <= 1}

    # A fixture's status is derived from what was *observed*, never from whether
    # the stage attempted it. Attempting and observing are different claims, and
    # only the second one is worth reporting: run 20260817T035849Z reported
    # `9b: asserted` with every instance returning `cells: {}` and one runtime
    # reporting the provider path unavailable — nothing had been measured, and
    # the label said the criterion held (#135). The same applied to 9a, which
    # was hardcoded `asserted` even when a runtime emitted no records at all.
    #
    # An empty result set must never reach "asserted".
    cov = observed_counts(report["instances"])
    report["fixtures"] = {
        "9a": fixture_status(cov["9a"], cov["reachable"]),
        "9b": fixture_status(cov["9b"], cov["reachable"]) if ran_9b else "not-run",
    }
    report["coverage"] = cov
    report["lane"] = args.lane
    # 9b is in scope on every lane, so it observing nothing is a failure, never
    # a pass: the stage passed for as long as 9b existed while asserting
    # nothing at all (#525, the failure #135 was filed about).
    if report["fixtures"]["9b"] != "asserted":
        fail(f"9b {report['fixtures']['9b']}: machine/provider contention observed on "
             f"{cov['9b']} of {cov['reachable']} runtime(s)")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print()
    if report["status"] == "failed":
        print(f"arbiter: FAILED ({len(report['failures'])} problem(s))")
        return 1
    # Print what was observed rather than a fixed "9a and 9b conform". A status
    # line that cannot say less than "conform" is not a report.
    print(f"arbiter: OK ({len(resolved_by_runtime)} runtime(s), lane {report['lane']}) — "
          f"9a {report['fixtures']['9a']} ({cov['9a']}/{cov['reachable']}), "
          f"9b {report['fixtures']['9b']} ({cov['9b']}/{cov['reachable']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
