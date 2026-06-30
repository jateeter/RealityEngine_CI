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
    for path in sorted(machine_dir.glob("*.json")):
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
        if runtime and pe_url and item.get("status", "running") == "running":
            instances.append({"id": item.get("id", runtime), "runtime": runtime, "pe_url": pe_url.rstrip("/")})
    if not instances:
        raise SystemExit(f"no running PE instances found in {registry}")
    return instances


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value)


def extract_signature(payload: Any) -> Any:
    """Extract stable effect data while avoiding timestamps/ids."""
    hits: list[Any] = []

    def walk(value: Any) -> None:
        if isinstance(value, dict):
            if any(k in value for k in ("machineId", "sequenceId", "outputVector", "outputVectors", "mergeBatch")):
                keep = {}
                for key in ("machineId", "sequenceId", "vectorId", "outputVectorId", "status", "success", "pushed", "stepCount"):
                    if key in value:
                        keep[key] = value[key]
                if "outputVector" in value:
                    keep["outputVector"] = value["outputVector"]
                if "outputVectors" in value:
                    keep["outputVectors"] = value["outputVectors"]
                if keep:
                    hits.append(keep)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(payload)
    if hits:
        return sorted(hits, key=lambda item: json.dumps(item, sort_keys=True))
    if isinstance(payload, dict):
        return {key: payload.get(key) for key in sorted(payload) if key in {"success", "pushed", "stepCount", "count"}}
    return payload


def signature_diff(baseline: Any, actual: Any) -> dict[str, Any]:
    return {
        "baselineSignature": baseline,
        "actualSignature": actual,
    }


def run_event(instance: dict[str, str], event: dict[str, Any], run_id: str) -> tuple[int, Any]:
    pe_url = instance["pe_url"]
    source_id = f"regression-{run_id}-{event['id']}-{instance['runtime']}"
    source = {
        "id": source_id,
        "type": "regression",
        "name": f"Regression {event['id']} {event['machineName']}",
        "active": True,
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
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    events = load_event_fixture(args.event_fixture, args.events) if args.event_fixture else discover_events(args.machines, args.events)
    (args.out / "selected-events.json").write_text(json.dumps({"events": events}, indent=2, sort_keys=True), encoding="utf-8")
    instances = load_instances(args.registry)
    failures: list[str] = []
    comparisons: list[dict[str, Any]] = []
    summary: dict[str, Any] = {"runId": args.run_id, "events": events, "instances": instances, "results": [], "comparisons": comparisons}

    for event in events:
        signatures: dict[str, Any] = {}
        instance_order: list[str] = []
        for instance in instances:
            status, payload = run_event(instance, event, args.run_id)
            instance_key = instance["id"]
            instance_order.append(instance_key)
            response_file = args.out / f"{event['id']}-{safe_name(instance_key)}.json"
            response_file.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
            signature = extract_signature(payload)
            signatures[instance_key] = signature
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
        unique = {json.dumps(sig, sort_keys=True) for sig in signatures.values()}
        if len(unique) != 1:
            baseline_key = instance_order[0] if instance_order else ""
            baseline = signatures.get(baseline_key)
            for instance_key in instance_order[1:]:
                actual = signatures.get(instance_key)
                if json.dumps(actual, sort_keys=True) != json.dumps(baseline, sort_keys=True):
                    comparison = {
                        "event": event["id"],
                        "machineFile": event.get("machineFile"),
                        "machineId": event.get("machineId"),
                        "sequenceId": event.get("sequenceId"),
                        "baselineInstance": baseline_key,
                        "actualInstance": instance_key,
                        **signature_diff(baseline, actual),
                    }
                    comparisons.append(comparison)
                    failures.append(f"{event['id']} parity mismatch: {instance_key} differs from {baseline_key}")
            if len(instance_order) == 1:
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
