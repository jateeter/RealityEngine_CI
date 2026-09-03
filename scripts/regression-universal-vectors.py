#!/usr/bin/env python3
"""Run live universal input event parity checks across active PE instances.

Records both halves of every observation: what each runtime *did* (the response
payloads) and what each runtime was *given* (the source set it held at the
moment of the push). A parity verdict without the second half cannot distinguish
an engine defect from a stimulus inequality, which is how #162 came to record 13
diverging perceptual-space cells whose direction was undeterminable after the
fact (#174).
"""

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
from reset_contract import reset_pair  # noqa: E402


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


def get_json(url: str, timeout: int = 20) -> tuple[int, Any]:
    req = request.Request(url, method="GET", headers={"accept": "application/json"})
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

    **Both halves.** This reset the RE and left the PE alone, which is only half
    a starting point: `POST {re}/api/engine/reset` clears CES activation and the
    histories, while `globalStep`, the persistent vector and the test cursors
    live in the PE and survived it. The stage then pushed five events against
    whatever those carried over from the preceding stage. It showed: on
    2026-09-03 the three runtimes entered this comparison at `globalStep` 12,
    12 and 17, with lsp-1 holding 0.5 in 13 perceptual-space cells the other two
    had at 0 — reported as a five-event parity failure that was partly stimulus.
    Delegated to reset_contract.reset_pair so the pair is defined once (#211).
    """
    outcomes: list[dict[str, Any]] = []
    for instance in instances:
        failures = reset_pair(post_json, instance.get("re_url"), instance.get("pe_url"), instance["id"])
        outcomes.append({
            "instance": instance["id"],
            "reset": "failed" if failures else "ok",
            "detail": failures,
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


def source_census(sources: Any) -> dict[str, list[dict[str, Any]]]:
    """A comparable, id-free view of what one PE was holding.

    Keyed on machine **name**, never on id. Ids are minted per runtime — the
    corpus declares none — so an id-keyed census splits three ways
    unconditionally and measures nothing (#146). The same rule the machine
    comparisons already follow.

    Only the fields that make a source *stimulus* are kept: its kind, whether it
    was active, and the region it writes. `lastValue`, `lastUpdated` and the
    per-runtime id are deliberately dropped — they differ between runtimes for
    reasons that say nothing about what the engines were given.
    """
    census: dict[str, list[dict[str, Any]]] = {}
    if not isinstance(sources, list):
        return census
    for src in sources:
        if not isinstance(src, dict):
            continue
        key = src.get("machineName") or src.get("name") or "<unnamed>"
        region = src.get("region") if isinstance(src.get("region"), dict) else None
        census.setdefault(str(key), []).append(
            {
                "type": src.get("type"),
                "active": bool(src.get("active")),
                "region": {"offset": region.get("offset"), "length": region.get("length")} if region else None,
            }
        )
    for entries in census.values():
        entries.sort(key=lambda e: json.dumps(e, sort_keys=True))
    return census


def source_set_divergence(censuses: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    """Where the runtimes were holding different stimulus. None when equal.

    Reported as membership (a machine name one runtime has and another does not)
    separately from disagreement (a name both hold, described differently),
    because they have different causes: the first is a registration difference,
    the second is usually an activation one.
    """
    if len(censuses) < 2:
        return None
    if len({json.dumps(c, sort_keys=True) for c in censuses.values()}) == 1:
        return None

    every_name: set[str] = set()
    for census in censuses.values():
        every_name |= set(census)

    missing: dict[str, list[str]] = {}
    differing: dict[str, dict[str, Any]] = {}
    for name in sorted(every_name):
        holders = [inst for inst, census in censuses.items() if name in census]
        if len(holders) != len(censuses):
            missing[name] = sorted(holders)
            continue
        variants = {inst: censuses[inst][name] for inst in censuses}
        if len({json.dumps(v, sort_keys=True) for v in variants.values()}) > 1:
            differing[name] = variants

    return {
        "equal": False,
        "counts": {inst: sum(len(v) for v in census.values()) for inst, census in sorted(censuses.items())},
        "heldBySome": missing,
        "describedDifferently": differing,
    }


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


def run_event(instance: dict[str, str], event: dict[str, Any], run_id: str) -> tuple[int, Any, Any]:
    """Push one event at one runtime, and record what that runtime was holding.

    Returns `(status, payload, sources)`. The source snapshot is taken **after
    the push and before the injected source is removed**, so it is the set that
    produced the response rather than the set that happens to remain afterwards.

    The stage used to record only what the engines *did*, never what they were
    *given* (#174). When a divergence turned out to be a PE source-set
    inequality rather than an engine defect, the artifacts could not tell you
    which — #162 left 13 perceptual-space cells split cpp against lsp/scala with
    the other 14,375 agreeing, a signature that reads as stimulus, and its
    direction was undeterminable after the fact because nothing recorded the
    stimulus. Capturing it costs one GET per runtime per event.
    """
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
    def snapshot_sources() -> Any:
        # Recorded even when it fails: "the source set could not be read" is
        # itself a finding, and a silent [] would read as "held nothing".
        try:
            status, payload = get_json(f"{pe_url}/api/sources")
        except Exception as exc:  # noqa: BLE001 - diagnosis must not break the run
            return {"error": f"GET /api/sources raised {exc!r}"}
        if status != 200:
            return {"error": f"GET /api/sources returned {status}"}
        sources = payload.get("sources") if isinstance(payload, dict) else None
        return sources if isinstance(sources, list) else {"error": "payload carried no sources array"}

    try:
        status, payload = post_json(f"{pe_url}/api/sources", source)
        if status < 200 or status >= 300:
            return status, {"phase": "source-register", "response": payload}, snapshot_sources()
        status, payload = post_json(f"{pe_url}/api/push", {"compact": True})
        return status, payload, snapshot_sources()
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
                    f"engine reset failed on {item['instance']} ({'; '.join(item['detail'])}) — "
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
        censuses: dict[str, dict[str, Any]] = {}
        source_files: dict[str, str] = {}
        for instance in instances:
            status, payload, sources = run_event(instance, event, args.run_id)
            instance_key = instance["id"]
            instance_order.append(instance_key)
            payloads[instance_key] = payload
            statuses[instance_key] = status
            response_file = args.out / f"{event['id']}-{safe_name(instance_key)}.json"
            response_file.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
            # Alongside the response, at the same point in the run (#174).
            sources_file = args.out / f"{event['id']}-{safe_name(instance_key)}-sources.json"
            sources_file.write_text(
                json.dumps({"instance": instance_key, "runtime": instance["runtime"], "sources": sources},
                           indent=2, sort_keys=True),
                encoding="utf-8",
            )
            source_files[instance_key] = str(sources_file)
            if isinstance(sources, list):
                censuses[instance_key] = source_census(sources)

        # Was the stimulus equal? Answered before any parity verdict is read,
        # so a divergence can be attributed rather than assumed to be semantics.
        # Only runtimes whose source set could actually be read take part —
        # comparing against a runtime that answered an error would manufacture
        # an inequality out of a failed GET.
        stimulus = source_set_divergence(censuses) if len(censuses) == len(instances) else None
        unreadable = sorted(set(instance_order) - set(censuses))
        summary.setdefault("sourceParity", []).append(
            {
                "event": event["id"],
                "equal": None if unreadable else stimulus is None,
                "unreadable": unreadable,
                "divergence": stimulus,
                "sourceFiles": source_files,
            }
        )

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
                    "sourceFile": source_files.get(instance_key),
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
                        "sourceSetsEqual": None if unreadable else stimulus is None,
                        "sourceSetDivergence": stimulus,
                        **signature_diff(reference_sig, actual),
                    }
                )
            shape = " | ".join("+".join(members) for members in agreement)
            note = " (no majority — runtimes split evenly)" if tied else ""
            # The stimulus verdict rides on the failure line itself. A reader of
            # the nightly issue sees whether the runtimes were given the same
            # thing without opening the artifact bundle — which is the whole
            # point of recording it (#174).
            if unreadable:
                stim = f" [stimulus unknown — source set unreadable on {'+'.join(unreadable)}]"
            elif stimulus is None:
                stim = " [stimulus equal — same sources on every runtime]"
            else:
                stim = f" [stimulus DIFFERS — source counts {stimulus['counts']}; may not be an engine defect]"
            failures.append(f"{event['id']} parity mismatch: {shape}{note}{stim}")
        if len(instance_order) == 1:
            # Unchanged in meaning, moved out of the mismatch branch: a single
            # signature cannot demonstrate parity whether or not it "agrees".
            failures.append(f"{event['id']} parity mismatch with only one runtime signature")

    summary["failures"] = failures
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    (args.out / "normalized-comparison.json").write_text(
        json.dumps(
            {
                "runId": args.run_id,
                "comparisons": comparisons,
                # Carried here as well as in summary.json: this file is what a
                # divergence triage opens first, and the stimulus question has
                # to be answerable from it (#174).
                "sourceParity": summary.get("sourceParity", []),
                "failures": failures,
            },
            indent=2, sort_keys=True,
        ),
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
