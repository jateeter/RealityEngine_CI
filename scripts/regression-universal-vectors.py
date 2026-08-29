#!/usr/bin/env python3
"""Run live universal input event parity checks across active PE instances."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
import time
from typing import Any
from urllib import error, request


sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from parity_identity import (  # noqa: E402
    parity_signature,
    shared_keys,
    uniformity_violations,
)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def post_json(url: str, payload: Any, timeout: int = 20) -> tuple[int, Any]:
    body = json.dumps(payload).encode("utf-8")
    req = request.Request(
        url,
        data=body,
        method="POST",
        headers={"content-type": "application/json", "accept": "application/json"},
    )
    return request_json(req, timeout)


def delete_json(url: str, timeout: int = 10) -> tuple[int, Any]:
    req = request.Request(url, method="DELETE", headers={"accept": "application/json"})
    return request_json(req, timeout)


def request_json(req: request.Request, timeout: int) -> tuple[int, Any]:
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw) if raw else {}
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw}
        return exc.code, payload


def jget(obj: Any, *keys: str, default: Any = None) -> Any:
    cur = obj
    for key in keys:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(key)
    return cur if cur is not None else default


def machine_input_region(machine: dict[str, Any]) -> dict[str, int] | None:
    mapping = machine.get("perceptualMapping") or {}
    region = mapping.get("input") or mapping.get("inputRegion")
    if not isinstance(region, dict):
        return None
    try:
        offset = int(region["offset"])
        length = int(region["length"])
    except Exception:
        return None
    if offset < 0 or length <= 0:
        return None
    return {"offset": offset, "length": length}


def vector_values(seq: dict[str, Any], length: int) -> list[float] | None:
    vectors = seq.get("vectors")
    if not isinstance(vectors, list) or not vectors:
        return None
    raw = vectors[0]
    if isinstance(raw, dict):
        raw = raw.get("values") or raw.get("vector") or raw.get("elements")
    if not isinstance(raw, list):
        return None
    values: list[float] = []
    for item in raw:
        if isinstance(item, dict):
            item = item.get("value")
        try:
            values.append(float(item))
        except Exception:
            return None
    if len(values) != length:
        return None
    return values


def stable_sequence_id(seq: dict[str, Any], fallback: str) -> str:
    for key in ("id", "sequenceId", "name"):
        value = seq.get(key)
        if value:
            return str(value)
    return fallback


def discover_events(machine_dir: Path, limit: int) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    # rglob, not glob: the corpus keeps every machine under machines/core/ and
    # machines/domains/<name>/, and nothing at the top level. A non-recursive
    # glob matched zero files out of 1,321, so this stage failed with
    # "discovered 0 suitable universal events" on every run that reached it.
    # sorted() over the recursive walk keeps the selection deterministic, which
    # the "deterministic-corpus-scan" selection policy depends on.
    for path in sorted(machine_dir.rglob("*.json")):
        try:
            root = load_json(path)
        except Exception:
            continue
        machine = root.get("machine") if isinstance(root, dict) else None
        if not isinstance(machine, dict):
            continue
        region = machine_input_region(machine)
        if not region:
            continue
        sequences = machine.get("inputSequences")
        if not isinstance(sequences, list):
            continue
        for seq_index, seq in enumerate(sequences):
            metadata = seq.get("metadata") if isinstance(seq, dict) else {}
            expected = metadata.get("expectedOutputCount") if isinstance(metadata, dict) else None
            if expected is not None:
                try:
                    if int(expected) <= 0:
                        continue
                except Exception:
                    pass
            values = vector_values(seq, region["length"])
            if values is None:
                continue
            events.append(
                {
                    "id": f"event-{len(events) + 1}",
                    "selectionPolicy": "deterministic-corpus-scan",
                    "machineFile": path.name,
                    "machineId": machine.get("id") or machine.get("machineId") or path.stem,
                    "machineName": machine.get("name", path.stem),
                    "sequenceId": stable_sequence_id(seq, f"{path.stem}-sequence-{seq_index + 1}"),
                    "sequenceName": seq.get("name", "unnamed"),
                    "expectedOutputCount": expected,
                    "region": region,
                    "values": values,
                }
            )
            break
        if len(events) >= limit:
            break
    if len(events) < limit:
        raise SystemExit(f"only discovered {len(events)} suitable universal events in {machine_dir}; need {limit}")
    return events


def load_event_fixture(path: Path, limit: int) -> list[dict[str, Any]]:
    payload = load_json(path)
    events = payload.get("events") if isinstance(payload, dict) else payload
    if not isinstance(events, list):
        raise SystemExit(f"event fixture {path} must contain an events array")
    selected: list[dict[str, Any]] = []
    for index, event in enumerate(events[:limit]):
        if not isinstance(event, dict):
            raise SystemExit(f"event fixture {path} entry {index + 1} is not an object")
        region = event.get("region")
        values = event.get("values")
        if not isinstance(region, dict) or not isinstance(values, list):
            raise SystemExit(f"event fixture {path} entry {index + 1} must include region and values")
        if len(values) != int(region.get("length", -1)):
            raise SystemExit(f"event fixture {path} entry {index + 1} values length does not match region.length")
        selected.append(
            {
                **event,
                "id": event.get("id", f"event-{index + 1}"),
                "selectionPolicy": event.get("selectionPolicy", f"fixture:{path.name}"),
            }
        )
    if len(selected) < limit:
        raise SystemExit(f"event fixture {path} contains {len(selected)} event(s); need {limit}")
    return selected


def load_instances(registry: Path) -> list[dict[str, str]]:
    try:
        data = load_json(registry)
    except Exception as exc:
        raise SystemExit(f"could not read registry {registry}: {exc}") from exc
    instances = []
    for item in data.get("instances", []):
        runtime = item.get("runtime")
        pe_url = item.get("pe_url")
        re_url = item.get("re_url")
        if runtime and pe_url and item.get("status", "running") == "running":
            # re_url is carried so the stage can establish a known starting
            # state; see reset_instances (#139).
            instances.append({
                "id": item.get("id", runtime),
                "runtime": runtime,
                "pe_url": pe_url.rstrip("/"),
                "re_url": (re_url or "").rstrip("/"),
            })
    if not instances:
        raise SystemExit(f"no running PE instances found in {registry}")
    return instances


def reset_instances(instances: list[dict[str, str]]) -> list[dict[str, Any]]:
    """Establish a known starting state before asserting anything.

    The stage pushes five events against a persistent perceptual space and used
    to assert on whatever state it found — a previous stage, ambient integration
    traffic, or a prior run. A stage in that shape cannot distinguish a runtime
    defect from leftover state, which is how "arbitration records are never
    emitted" came to be filed and closed as not reproducible
    (jateeter/RealityEngine_CPP#32, jateeter/RealityEngine_CI#139).

    Reset is per-run, not per-event: the five-event sequence is cumulative by
    design — each event's result depends on what the previous one wrote, and
    that is the property the stage exists to compare. Resetting between events
    would test five independent single-event runs instead.

    Reported rather than assumed: a reset that silently failed would put the
    stage back where it started, so the outcome per instance goes in the report.
    """
    outcomes: list[dict[str, Any]] = []
    for instance in instances:
        re_url = instance.get("re_url")
        if not re_url:
            outcomes.append({"instance": instance["id"], "reset": "skipped", "reason": "registry carries no re_url"})
            continue
        status, _ = post_json(f"{re_url}/api/engine/reset", {})
        ok = 200 <= status < 300
        outcomes.append({
            "instance": instance["id"],
            "reset": "ok" if ok else "failed",
            "status": status,
        })
    return outcomes


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value)


def extract_signature(payload: Any, shared: set[str] | None = None) -> Any:
    """One runtime's comparable observation of a step.

    Delegates to scripts/lib/parity_identity.py so the observability rules are
    stated once and applied at every probe point rather than re-invented here.

    The whitelist this replaced kept `machineId` and dropped the region offsets.
    Machine ids are minted per runtime — the corpus declares none — so every
    event with a non-empty `activeRegions` split three ways unconditionally,
    while payloads carrying no machineId fell through to `{"success": true}`
    and passed trivially. Neither outcome measured anything (#146).
    """
    return parity_signature(payload, shared)


def active_region_order_violations(instance_id: str, payload: Any) -> list[str]:
    """`activeRegions` must arrive in the canonical order.

    SURFACE_SPEC.md, "Active regions": offset, then length, then machineId, then
    type, all ascending. Every runtime sorts before serializing.

    Checked here rather than assumed because this stage is what the old
    behaviour broke. All three runtimes built the list by walking their own
    machine collection in their own iteration order and reported the same
    regions in three different orders (#197) — so no two agreed byte-for-byte,
    `agreement_clusters` never found a majority, and every divergence reported
    as "no majority — runtimes split evenly" whatever the engines had done. A
    regression here would silently restore that, and it would look like an
    engine disagreement rather than an ordering one.
    """
    regions = jget(payload, "step", "activeRegions") or jget(payload, "activeRegions")
    if not isinstance(regions, list) or len(regions) < 2:
        return []

    def key(region: Any) -> tuple[Any, ...]:
        if not isinstance(region, dict):
            return ()
        return (region.get("offset", 0), region.get("length", 0),
                region.get("machineId", ""), region.get("type", ""))

    keys = [key(r) for r in regions]
    if keys != sorted(keys):
        first = next((i for i in range(1, len(keys)) if keys[i] < keys[i - 1]), None)
        return [f"{instance_id}: activeRegions not in canonical order at index {first} "
                f"({keys[first - 1]} before {keys[first]}) — SURFACE_SPEC.md, Active regions (#197)"]
    return []


def agreement_clusters(signatures: dict[str, Any], instance_order: list[str]) -> list[list[str]]:
    """Group instances by identical signature, largest cluster first.

    Byte equivalence is a property of the set, not of a designated member. This
    replaced a comparison against instance_order[0] — whichever instance the
    registry listed first, which was also the engine localAIStack writes to, so
    two runtimes agreeing exactly with each other were both reported as
    diverging (#138).

    Ties are left tied: with runtimes split evenly there is no majority, and
    resolving it arbitrarily would reinstate the designated-baseline problem.
    """
    clusters: dict[str, list[str]] = {}
    for instance_key in instance_order:
        clusters.setdefault(json.dumps(signatures.get(instance_key), sort_keys=True), []).append(instance_key)
    return sorted(
        (sorted(members) for members in clusters.values()),
        key=lambda members: (-len(members), members),
    )


def signature_diff(baseline: Any, actual: Any) -> dict[str, Any]:
    return {
        "baselineSignature": baseline,
        "actualSignature": actual,
    }


def run_event(instance: dict[str, str], event: dict[str, Any], run_id: str) -> tuple[int, Any]:
    pe_url = instance["pe_url"]
    source_id = f"regression-{run_id}-{event['id']}-{instance['runtime']}"
    # "test" is the canonical source shape (C++ is the definition,
    # RealityEngine_CI#91) and is what a region + inputs + loop source is.
    # This posted type "regression", which is not a source type at all: the
    # Scala PE decodes SourceConfig on a type discriminator of
    # test|simulated|sensor and answered every event with
    # "Unknown source type: regression" as an HTTP 400, while C++ and LSP
    # accepted it. The harness was the divergent party, and it made the Scala
    # runtime unmeasurable rather than revealing anything about it.
    source = {
        "id": source_id,
        "type": "test",
        "name": f"Regression {event['id']} {event['machineName']}",
        "active": True,
        "machineId": event["machineId"],
        "machineName": event["machineName"],
        "sequenceName": event["sequenceName"],
        "region": event["region"],
        "inputs": [event["values"]],
        "loop": False,
    }
    try:
        status, payload = post_json(f"{pe_url}/api/sources", source)
        if status < 200 or status >= 300:
            return status, {"phase": "source-register", "response": payload}
        status, payload = post_json(f"{pe_url}/api/push", {"compact": True})
        return status, payload
    finally:
        try:
            delete_json(f"{pe_url}/api/sources/{source_id}")
        except Exception:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=Path("/tmp/re-registry/re-registry.json"))
    parser.add_argument("--machines", type=Path, default=Path("../RealityEngine_Machines/machines"))
    parser.add_argument("--events", type=int, default=5)
    parser.add_argument("--event-fixture", type=Path, help="Pinned event fixture JSON. Defaults to deterministic corpus scan.")
    parser.add_argument("--out", type=Path, default=Path(".regression-tests/latest/universal-vectors"))
    parser.add_argument("--run-id", default=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    # On by default: a stage that asserts against whatever state it finds cannot
    # tell a runtime defect from leftover state (#139).
    parser.add_argument("--no-reset", dest="reset", action="store_false",
                        help="Do not reset the engines first; measure accumulated state deliberately.")
    parser.add_argument("--settle-ms", type=int, default=400,
                        help="Pause after the reset before the first event.")
    parser.set_defaults(reset=True)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    events = load_event_fixture(args.event_fixture, args.events) if args.event_fixture else discover_events(args.machines, args.events)
    (args.out / "selected-events.json").write_text(json.dumps({"events": events}, indent=2, sort_keys=True), encoding="utf-8")
    instances = load_instances(args.registry)
    failures: list[str] = []
    comparisons: list[dict[str, Any]] = []
    summary: dict[str, Any] = {"runId": args.run_id, "events": events, "instances": instances, "results": [], "comparisons": comparisons}

    # Known starting state before the first assertion (#139). Skippable for a
    # caller deliberately measuring accumulated state.
    if args.reset:
        summary["reset"] = reset_instances(instances)
        failed = [r for r in summary["reset"] if r.get("reset") == "failed"]
        if failed:
            # Not fatal: the run is still informative, and refusing to start
            # would make a reset regression look like a parity regression. But
            # it is recorded as a failure so the result is not read as clean.
            for item in failed:
                failures.append(
                    f"engine reset failed on {item['instance']} (HTTP {item['status']}) — "
                    "results below were measured against unknown prior state"
                )
        time.sleep(args.settle_ms / 1000.0)
    else:
        summary["reset"] = [{"reset": "disabled", "reason": "--no-reset"}]

    for event in events:
        signatures: dict[str, Any] = {}
        instance_order: list[str] = []
        payloads: dict[str, Any] = {}
        statuses: dict[str, int] = {}
        for instance in instances:
            status, payload = run_event(instance, event, args.run_id)
            instance_key = instance["id"]
            instance_order.append(instance_key)
            payloads[instance_key] = payload
            statuses[instance_key] = status
            response_file = args.out / f"{event['id']}-{safe_name(instance_key)}.json"
            response_file.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

        # Shared keys are a property of the set, so signatures cannot be built
        # until every runtime has answered. Asymmetric keys are reported as
        # contract violations rather than intersected away in silence (#146).
        shared = shared_keys(payloads)
        violations = uniformity_violations(payloads)
        if violations:
            summary.setdefault("uniformityViolations", []).append(
                {"event": event["id"], "violations": violations}
            )
        for instance in instances:
            instance_key = instance["id"]
            payload = payloads[instance_key]
            status = statuses[instance_key]
            signature = extract_signature(payload, shared)
            signatures[instance_key] = signature
            # Ordering is a contract, not an accident of iteration. Reported
            # separately from parity: an unsorted list is this runtime failing
            # its own obligation, not two runtimes disagreeing, and conflating
            # them is exactly how #197 stayed invisible.
            failures.extend(active_region_order_violations(instance_key, payload))
            summary["results"].append(
                {
                    "event": event["id"],
                    "machineFile": event.get("machineFile"),
                    "machineId": event.get("machineId"),
                    "sequenceId": event.get("sequenceId"),
                    "selectionPolicy": event.get("selectionPolicy"),
                    "instanceId": instance["id"],
                    "runtime": instance["runtime"],
                    "status": status,
                    "signature": signature,
                    "responseFile": str(response_file),
                }
            )
            if status < 200 or status >= 300:
                failures.append(f"{event['id']} {instance['id']} ({instance['runtime']}) HTTP {status}")
        # Byte equivalence is a property of the *set*, not of a designated
        # member. This compared every runtime against instance_order[0] — which
        # is whichever instance the registry happened to list first, and which
        # is also the engine localAIStack's bridge writes to (#46). On
        # 2026-08-17 that engine held 17 machines while the others held 7, so
        # every comparison ran against the contaminated party: two runtimes that
        # agreed exactly with each other were both reported as diverging, and
        # RealityEngine_LSP#38 was filed on that reading. See #138.
        #
        # Group by signature instead. Agreement is reported either way, so a
        # reader can tell "one runtime is the outlier" from "all three disagree"
        # without knowing which instance came first.
        agreement = agreement_clusters(signatures, instance_order)
        summary.setdefault("agreement", []).append(
            {"event": event["id"], "clusters": agreement}
        )

        if len(agreement) != 1:
            # The largest cluster is the reference, and ties are reported as
            # ties rather than resolved arbitrarily — with two runtimes
            # disagreeing 1-1 there is no majority and saying so is the honest
            # result.
            largest = max(len(members) for members in agreement)
            majorities = [m for m in agreement if len(m) == largest]
            tied = len(majorities) > 1
            reference_members = majorities[0]
            reference_sig = signatures.get(reference_members[0])

            for members in agreement:
                if members is reference_members or members == reference_members:
                    continue
                actual = signatures.get(members[0])
                comparisons.append(
                    {
                        "event": event["id"],
                        "machineFile": event.get("machineFile"),
                        "machineId": event.get("machineId"),
                        "sequenceId": event.get("sequenceId"),
                        "referenceInstances": reference_members,
                        "divergentInstances": members,
                        "referenceIsTied": tied,
                        **signature_diff(reference_sig, actual),
                    }
                )
            shape = " | ".join("+".join(members) for members in agreement)
            note = " (no majority — runtimes split evenly)" if tied else ""
            failures.append(f"{event['id']} parity mismatch: {shape}{note}")
        if len(instance_order) == 1:
            # Unchanged in meaning, moved out of the mismatch branch: a single
            # signature cannot demonstrate parity whether or not it "agrees".
            failures.append(f"{event['id']} parity mismatch with only one runtime signature")

    summary["failures"] = failures
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    (args.out / "normalized-comparison.json").write_text(
        json.dumps({"runId": args.run_id, "comparisons": comparisons, "failures": failures}, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    if failures:
        for item in failures:
            print(f"FAIL {item}", file=sys.stderr)
        return 1
    print(f"PASS universal vector parity: {len(events)} events across {len(instances)} runtimes")
    print(args.out / "summary.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
