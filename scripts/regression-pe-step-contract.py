#!/usr/bin/env python3
"""PE push response shape — SURFACE_SPEC.md, `POST /api/push` response shape.

The push response is how the Reality Engine's result travels back to the
Perception Engine. It was never specified, and all three runtimes diverged on it
for an identical computation: LSP omitted `perceptualSpace` under `compact` and
emitted an `inputVector` the others did not; Scala omitted `eventBus` and
`perceptualSpaceIsDebugProjection` and ignored `compact`.

That is not cosmetic. Anything walking the response — including
regression-universal-vectors.py, whose signature extraction is the cross-runtime
parity gate — saw three different pictures of the same reality and reported it
as engine divergence. Two issues were filed against the wrong runtimes before
the return path was identified as the difference.

This stage drives one push per running PE and compares emitted key sets against
the contract, so the shape is observable rather than assumed. It is deliberately
an *external* check: the surface is internal to the PE/RE pair, but a contract
nothing outside can see is a contract nothing enforces.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from reset_contract import reset_pair  # noqa: E402

# SURFACE_SPEC.md, "POST /api/push response shape".
ALWAYS = {
    "stepNumber",
    "timestamp",
    "perceptualSpace",
    "perceptualSpaceIsDebugProjection",
    "activeRegions",
    "mergeBatch",
    "eventBus",
}
FULL_ONLY = {"machineResults"}
COMPACT_KEYS = ALWAYS
FULL_KEYS = ALWAYS | FULL_ONLY

# Probe points where the runtimes are known to disagree today, each with the
# issue that owns it. Reported on every run, but not fatal.
#
# Not an excuse list — a register with a shrinking horizon. The divergences are
# real and filed; making them fail the stage now would turn a green stage red on
# defects nobody is about to fix in the same change, and this repo already
# learned where that leads: `regression-reset-contract.py` is deliberately not
# wired into the harness because "a harness stage that always fails is a harness
# stage everyone learns to ignore" (scripts/CLAUDE.md).
#
# Anything diverging at a probe point *not* listed here fails. Delete an entry
# when its issue closes and the gate tightens with no other edit — that is the
# whole mechanism, so resist adding entries to quiet a new finding.
KNOWN_SHAPE_DIVERGENCE = {
    # C++ emits `dispatch`; LSP and Scala omit the key. Scala also emits `id`
    # and LSP omits `error`, so this splits three ways.
    "response": "#231 — response top level is unspecified",
    # LSP emits `valuesPacked`; C++ gates its emitter on `compact` and Scala has
    # no emitter at all.
    "step.mergeBatch[]": "#208 — valuesPacked, reopened 2026-09-03",
}


def http(method: str, url: str, payload: Any = None, timeout: int = 25) -> tuple[int, Any]:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as exc:
        return exc.code, {}
    except Exception as exc:  # noqa: BLE001 — an unreachable PE is a result, not a crash
        return 0, {"error": str(exc)}


def load_instances(registry_path: Path) -> list[dict[str, str]]:
    data = json.loads(registry_path.read_text(encoding="utf-8"))
    return [
        {
            "id": inst.get("id", "?"),
            "runtime": inst.get("runtime", "?"),
            "pe": inst["pe_url"],
            "re": inst["re_url"],
        }
        for inst in data.get("instances", [])
        if inst.get("status", "running") == "running" and inst.get("pe_url") and inst.get("re_url")
    ]


def probe_event() -> dict[str, Any]:
    """A minimal stimulus.

    The response shape must not depend on which machine fired, so this does not
    need the parity harness's event discovery. It does carry machineId /
    machineName / sequenceName: the Scala PE's SourceConfig decoder rejects a
    `test` source without them with a 400, so a source that omits them makes
    that runtime unmeasurable rather than revealing anything about it.
    """
    return {
        "type": "test",
        "name": "pe-step-contract probe",
        "active": True,
        "machineId": "pe-step-contract-probe",
        "machineName": "PE Step Contract Probe",
        "sequenceName": "probe",
        "region": {"offset": 40, "length": 4},
        "inputs": [[1.0, 1.0, 1.0, 1.0]],
        "loop": False,
    }


def shape_probe(payload: Any) -> tuple[dict[str, list[str]], list[str]]:
    """Key sets at every level the push response spans, not only `step`.

    Returns `({probe point: sorted keys}, intra-runtime problems)`.

    This read `set(step.keys())` and stopped, which is one level deep. Two
    places the runtimes actually diverge sit outside it and were therefore
    invisible to the gate that exists to catch exactly this (#231):

    * **The response top level.** `dispatch` is a sibling of `step`, not a
      member of it. C++ emits it; LSP and Scala do not emit the key at all.
    * **Inside `mergeBatch`.** The element shape was never specified, so LSP's
      `valuesPacked` split the runtimes, was fixed, and regressed — with no
      gate looking at that depth to notice (#208).

    `mergeBatch` elements are unioned rather than sampled: a runtime whose
    elements disagree with *each other* is its own defect, reported separately
    below, and taking element 0 as representative would hide it.
    """
    problems: list[str] = []
    if not isinstance(payload, dict):
        return {}, ["response was not an object"]

    shape: dict[str, list[str]] = {"response": sorted(payload.keys())}

    step = payload.get("step")
    if not isinstance(step, dict):
        return shape, problems
    shape["step"] = sorted(step.keys())

    batch = step.get("mergeBatch")
    if isinstance(batch, list):
        element_sets = [frozenset(op.keys()) for op in batch if isinstance(op, dict)]
        if element_sets:
            shape["step.mergeBatch[]"] = sorted(set().union(*element_sets))
            if len(set(element_sets)) > 1:
                spread = sorted(sorted(s) for s in set(element_sets))
                # json.dumps, not an f-string interpolation of the list: a
                # Python repr lands single-quoted in the report and in the
                # failure line, where every other key set is JSON.
                problems.append(
                    f"mergeBatch elements disagree with each other: {json.dumps(spread)}"
                )
    return shape, problems


def push_keys(
    instance: dict[str, str], compact: bool, event: dict[str, Any]
) -> tuple[set[str], str | None, dict[str, list[str]], list[str]]:
    """`(step keys, error, full nested shape, intra-runtime problems)`."""
    source_id = f"pe-step-contract-{instance['runtime']}-{'c' if compact else 'f'}"
    source = dict(event, id=source_id)
    status, _ = http("POST", f"{instance['pe']}/api/sources", source)
    if status < 200 or status >= 300:
        return set(), f"source register -> {status}", {}, []
    try:
        status, payload = http("POST", f"{instance['pe']}/api/push", {"compact": compact})
        if status < 200 or status >= 300:
            return set(), f"push -> {status}", {}, []
        shape, problems = shape_probe(payload)
        if "step" not in shape:
            return set(), "response carried no `step` object", shape, problems
        return set(shape["step"]), None, shape, problems
    finally:
        http("DELETE", f"{instance['pe']}/api/sources/{source_id}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=Path("/tmp/re-registry/re-registry.json"))
    parser.add_argument("--machines", type=Path, default=Path("../RealityEngine_Machines/machines"))
    parser.add_argument("--out", type=Path)
    parser.add_argument("--settle-ms", type=int, default=400)
    args = parser.parse_args()

    if not args.registry.is_file():
        print(f"pe-step-contract: no registry at {args.registry}", file=sys.stderr)
        return 2

    instances = load_instances(args.registry)
    if not instances:
        print("pe-step-contract: no running instances in the registry", file=sys.stderr)
        return 2

    event = probe_event()
    report: dict[str, Any] = {"status": "passed", "failures": [], "instances": []}

    def fail(message: str) -> None:
        report["failures"].append(message)
        report["status"] = "failed"
        print(f"  FAIL {message}")

    for inst in instances:
        name = f"{inst['runtime']}:{inst['id']}"
        print(f"\n== {name}")
        # Both halves: this reset the RE and then pushed through the PE, so the
        # key sets below were read against PE run state carried in from the
        # preceding stage, and it left its own behind for the next one (#211).
        for item in reset_pair(lambda url, body: http("POST", url, body),
                               inst.get("re"), inst.get("pe"), name):
            fail(f"{item} — key sets below were read against unknown prior state")
        time.sleep(args.settle_ms / 1000.0)

        entry: dict[str, Any] = {"instance": name}
        for compact, expected in ((True, COMPACT_KEYS), (False, FULL_KEYS)):
            label = "compact" if compact else "full"
            keys, err, shape, problems = push_keys(inst, compact, event)
            if err:
                fail(f"{name}: {label} push unusable — {err}")
                entry[label] = {"error": err, "shape": shape}
                continue
            missing = sorted(expected - keys)
            extra = sorted(keys - expected)
            entry[label] = {"keys": sorted(keys), "missing": missing, "unexpected": extra, "shape": shape}
            print(f"  {label:<8} {len(keys)} step key(s), {len(shape)} probe point(s)")
            # A runtime disagreeing with itself is a local defect, not a
            # cross-runtime one, and must not be reported as divergence.
            for problem in problems:
                fail(f"{name}: {label} {problem}")
            if missing:
                fail(f"{name}: {label} response missing {missing} — SURFACE_SPEC requires them")
            if extra:
                # Unexpected keys are a divergence too: a consumer written
                # against one runtime's extras breaks on the others.
                fail(f"{name}: {label} response carries unspecified {extra}")
        report["instances"].append(entry)

    # Cross-runtime equality is the point, and is worth asserting directly
    # rather than inferring from each runtime passing its own check.
    #
    # Applied at every probe point, not only `step`. Uniformity is checkable
    # before the declared key set is settled — a key one runtime emits and
    # another omits is a divergence whether or not the spec has an opinion yet —
    # which is why this catches `dispatch` and `mergeBatch[].valuesPacked` today
    # while SURFACE_SPEC still specifies `step` alone (#231).
    for label in ("compact", "full"):
        observed = {
            e["instance"]: e[label]["shape"]
            for e in report["instances"]
            if isinstance(e.get(label), dict) and isinstance(e[label].get("shape"), dict)
        }
        if len(observed) < 2:
            continue
        for probe in sorted({p for shape in observed.values() for p in shape}):
            # Absent probe point and empty key set are different findings: the
            # first says a runtime produced no such structure at all.
            by_runtime = {
                inst: (json.dumps(shape[probe]) if probe in shape else "<absent>")
                for inst, shape in observed.items()
            }
            if len(set(by_runtime.values())) == 1:
                continue
            clusters: dict[str, list[str]] = {}
            for inst, keys in by_runtime.items():
                clusters.setdefault(keys, []).append(inst)
            shape_desc = " | ".join(
                f"{'+'.join(sorted(members))}={keys}"
                for keys, members in sorted(clusters.items(), key=lambda kv: (-len(kv[1]), kv[0]))
            )
            message = f"runtimes disagree on the {label} `{probe}` key set: {shape_desc}"
            known = KNOWN_SHAPE_DIVERGENCE.get(probe)
            if known:
                # Recorded, not hidden: it appears in the report and on stdout
                # every run, so it cannot quietly become permanent.
                report.setdefault("knownDivergence", []).append(
                    {"probe": probe, "variant": label, "issue": known, "detail": shape_desc}
                )
                print(f"  KNOWN {message}  [{known}]")
            else:
                fail(message)

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print()
    if report["status"] == "failed":
        print(f"pe-step-contract: FAILED ({len(report['failures'])} problem(s))")
        return 1
    print(f"pe-step-contract: OK ({len(report['instances'])} runtime(s) agree on the step shape)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
