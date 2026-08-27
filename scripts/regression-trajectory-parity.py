#!/usr/bin/env python3
"""Cross-engine trajectory parity: do the engines evolve identically?

The claim the multi-engine deployment rests on is that from a `--fresh`
deployment, every engine given the same seed sequence evolves the same way.
Nothing proved it. `regression-universal-vectors.py` compares single-step
responses and re-synchronises the engines between events — it registers a
source, pushes, deletes the source, repeats. Two engines can agree at every
step examined in isolation and still be on different trajectories, and a loop
that diverges the moment it is left alone passes that stage (RealityEngine_CI#148).

This stage seeds once and lets each engine run its own closed loop, then
compares the two histories the engines record at their own observation points:

    ISRE-History = {ISRE(1) … ISRE(n)}   what each corpus was presented with
    OREV-History = {OREV(1) … OREV(n-1)} what each corpus produced

Both are read from `GET {re}/api/{isre,orev}-history`, which every runtime
serves in the shape SURFACE_SPEC.md governs. A probe written against one engine
runs unmodified against all of them; that is a requirement, not a convenience.

What this deliberately does not do:

* **No baseline engine.** Agreement is a property of the set (#138). Engines are
  grouped into agreement clusters and any split is the finding, so a two-to-one
  disagreement never silently anoints the majority as correct.
* **No arbiter internals.** `mergeBatch` is a private algorithm expected to
  change under training. Its effect is entirely captured as the gap between the
  seed and the ISRE actually presented, which needs no access to it.
* **No region comparison.** Regions are an abstraction laid across the input
  space reality vector. It is the vector that must be equivalent; region
  equivalence follows from it.
* **No sorting, no identity filtering.** These histories carry vectors, not
  names — there is no engine-minted id to strip and no ordering to normalise.
  The histories are ordered by construction and compared in that order.

Divergence is reported as **the first disagreeing step and cell**. The
histories are sequences: everything after the first divergence is downstream of
it, and reporting n steps of consequences as n findings buries the one fact
that locates the defect.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time
from typing import Any
from urllib import error, request

TRAJECTORIES = ("isre", "orev")


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
    except (error.URLError, TimeoutError, OSError) as exc:
        return 0, {"error": str(exc)}


def get_json(url: str, timeout: int = 20) -> tuple[int, Any]:
    return request_json(request.Request(url, headers={"accept": "application/json"}), timeout)


def post_json(url: str, payload: Any, timeout: int = 30) -> tuple[int, Any]:
    req = request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"content-type": "application/json", "accept": "application/json"},
    )
    return request_json(req, timeout)


def delete_json(url: str, timeout: int = 15) -> tuple[int, Any]:
    return request_json(request.Request(url, method="DELETE", headers={"accept": "application/json"}), timeout)


def load_instances(registry_url: str) -> list[dict[str, Any]]:
    # The registry is addressable two ways and both are in use: the corpus
    # parity loop passes the URL the shim serves, and regression-test.sh passes
    # the file startUniverse writes — every other stage it drives takes the
    # path. Accepting only the URL made this the one tool that could not be
    # dropped into the harness, and it failed with a urllib traceback that named
    # neither the path nor the reason (regression run gha-33125776815-1).
    if "://" not in registry_url:
        path = Path(registry_url)
        if not path.is_file():
            raise SystemExit(f"registry file not found: {path}")
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SystemExit(f"registry file unreadable at {path}: {exc}") from exc
        status = 200
    else:
        status, payload = get_json(registry_url)
    if status != 200:
        raise SystemExit(f"registry unreachable at {registry_url} (status {status})")
    entries = payload.get("instances", payload if isinstance(payload, list) else [])
    instances = []
    for entry in entries:
        re_url = entry.get("re_url") or entry.get("reUrl")
        pe_url = entry.get("pe_url") or entry.get("peUrl")
        if re_url and pe_url:
            instances.append({"id": entry.get("id"), "re": re_url.rstrip("/"), "pe": pe_url.rstrip("/")})
    return instances


def dense(entry: dict[str, Any]) -> dict[int, float]:
    """Sparse entry -> {index: value}. A cell absent from `nonZero` is zero."""
    return {int(cell["index"]): float(cell["value"]) for cell in entry.get("nonZero", [])}


def first_divergence(entries: dict[str, list[dict[str, Any]]]) -> dict[str, Any] | None:
    """First (step, cell) where the engines do not all agree.

    Length disagreement is reported at the step it appears rather than as a
    cell mismatch: an engine that stopped stepping and an engine that stepped
    to a different value are different defects and must not read the same.
    """
    names = sorted(entries)
    lengths = {name: len(entries[name]) for name in names}
    common = min(lengths.values())

    for step in range(common):
        step_entries = {name: entries[name][step] for name in names}

        numbers = {name: e.get("stepNumber") for name, e in step_entries.items()}
        if len(set(numbers.values())) > 1:
            return {"step": step, "kind": "stepNumber", "values": numbers,
                    "clusters": cluster(numbers)}

        widths = {name: e.get("length") for name, e in step_entries.items()}
        if len(set(widths.values())) > 1:
            return {"step": step, "kind": "length", "values": widths,
                    "clusters": cluster(widths)}

        vectors = {name: dense(e) for name, e in step_entries.items()}
        cells = sorted({cell for v in vectors.values() for cell in v})
        for cell in cells:
            values = {name: v.get(cell, 0.0) for name, v in vectors.items()}
            if len(set(values.values())) > 1:
                return {"step": step, "cell": cell, "kind": "value", "values": values,
                        "clusters": cluster(values)}

    if len(set(lengths.values())) > 1:
        return {"step": common, "kind": "historyLength", "values": lengths,
                "clusters": cluster(lengths)}
    return None


def cluster(values: dict[str, Any]) -> list[list[str]]:
    """Engines grouped by what they said. A split is the finding; no engine is
    the reference, so the clusters are reported rather than a diff against one."""
    groups: dict[str, list[str]] = {}
    for name, value in values.items():
        groups.setdefault(json.dumps(value, sort_keys=True), []).append(name)
    return sorted((sorted(members) for members in groups.values()), key=lambda m: (-len(m), m))


def seed_vector(dimension: int, cells: dict[int, float]) -> list[float]:
    vector = [0.0] * dimension
    for index, value in cells.items():
        if index < dimension:
            vector[index] = value
    return vector


def run_seed_sequence(instance: dict[str, Any], seeds: list[list[float]], source_id: str,
                      region: dict[str, int], settle_ms: int) -> list[str]:
    """Apply the seed sequence to one engine, letting its own loop run.

    One source, registered once and left in place for the whole sequence. The
    stage this replaces created and deleted a source per event, which reset the
    engine between steps — the exact thing that made a trajectory unobservable.
    """
    failures: list[str] = []
    pe = instance["pe"]

    # Every field is sent explicitly, including the ones C++ and LSP default.
    # Scala's decoder requires `type`, `active`, `lastValue` and `lastUpdated`
    # and 400s on a body missing any of them, where the other two fill in
    # defaults. That asymmetry is a divergence on the *request* side of a public
    # surface and deserves its own finding; sending the full body here keeps
    # this stage measuring trajectories rather than re-measuring that.
    status, _ = post_json(f"{pe}/api/sources", {
        "id": source_id,
        "type": "sensor",
        "name": "trajectory-parity seed",
        "region": region,
        "active": True,
        "sensorId": source_id,
        "lastValue": [0.0] * region["length"],
        "lastUpdated": None,
        "ttlMs": 600000,
    })
    if status not in (200, 201):
        return [f"{instance['id']}: source registration failed (status {status})"]

    try:
        for index, seed in enumerate(seeds):
            status, _ = post_json(f"{pe}/api/sensors/{source_id}",
                                  {"values": seed[region["offset"]:region["offset"] + region["length"]]})
            if status != 200:
                failures.append(f"{instance['id']}: sensor write {index} failed (status {status})")
                break
            status, _ = post_json(f"{pe}/api/push", {"compact": True})
            if status != 200:
                failures.append(f"{instance['id']}: push {index} failed (status {status})")
                break
            if settle_ms:
                time.sleep(settle_ms / 1000.0)
    finally:
        delete_json(f"{pe}/api/sources/{source_id}")
    return failures


def fetch_history(instance: dict[str, Any], kind: str) -> tuple[list[dict[str, Any]], str | None]:
    status, payload = get_json(f"{instance['re']}/api/engine/{kind}-history")
    if status != 200:
        return [], f"{instance['id']}: GET /api/engine/{kind}-history returned {status}"
    history = payload.get("history")
    if not isinstance(history, list):
        return [], f"{instance['id']}: {kind}-history payload has no history array"
    return history, None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", default="http://127.0.0.1:5999/re-registry.json")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--run-id", default=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    parser.add_argument("--steps", type=int, default=6, help="seed sequence length")
    parser.add_argument("--offset", type=int, default=12, help="seed region offset")
    parser.add_argument("--length", type=int, default=4, help="seed region length")
    parser.add_argument("--settle-ms", type=int, default=250)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    instances = load_instances(args.registry)
    if len(instances) < 2:
        print(f"FAIL trajectory parity needs at least two runtimes, found {len(instances)}", file=sys.stderr)
        return 1

    region = {"offset": args.offset, "length": args.length}
    # A seed that walks: every step differs from the last, so a runtime that
    # silently stopped stepping shows up as a shorter history rather than as a
    # sequence of identical entries indistinguishable from a working one.
    seeds = [seed_vector(args.offset + args.length,
                         {args.offset + (step % args.length): 1.0 + step})
             for step in range(args.steps)]

    source_id = f"trajectory-parity-{args.run_id}"
    failures: list[str] = []
    for instance in instances:
        failures.extend(run_seed_sequence(instance, seeds, source_id, region, args.settle_ms))

    summary: dict[str, Any] = {
        "runId": args.run_id,
        "instances": [i["id"] for i in instances],
        "seedSteps": args.steps,
        "seedRegion": region,
        "trajectories": {},
    }

    for kind in TRAJECTORIES:
        histories: dict[str, list[dict[str, Any]]] = {}
        for instance in instances:
            history, err = fetch_history(instance, kind)
            if err:
                failures.append(err)
                continue
            histories[instance["id"]] = history

        record: dict[str, Any] = {
            "lengths": {name: len(h) for name, h in histories.items()},
            "divergence": None,
        }
        if len(histories) < 2:
            failures.append(f"{kind}-history: fewer than two runtimes answered; parity not demonstrated")
        elif not any(histories.values()):
            failures.append(f"{kind}-history: empty on every runtime after {args.steps} pushes")
        else:
            divergence = first_divergence(histories)
            record["divergence"] = divergence
            if divergence:
                shape = " | ".join("+".join(members) for members in divergence["clusters"])
                where = f"step {divergence['step']}"
                if "cell" in divergence:
                    where += f" cell {divergence['cell']}"
                failures.append(f"{kind}-history diverges at {where} ({divergence['kind']}): {shape}")
        summary["trajectories"][kind] = record

    summary["failures"] = failures
    (args.out / "trajectory-summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")

    if failures:
        for item in failures:
            print(f"FAIL {item}", file=sys.stderr)
        return 1
    lengths = summary["trajectories"]["isre"]["lengths"]
    print(f"PASS trajectory parity: ISRE/OREV histories identical across "
          f"{len(instances)} runtimes ({min(lengths.values())} steps)")
    print(args.out / "trajectory-summary.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
