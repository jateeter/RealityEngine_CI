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


def push_keys(instance: dict[str, str], compact: bool, event: dict[str, Any]) -> tuple[set[str], str | None]:
    source_id = f"pe-step-contract-{instance['runtime']}-{'c' if compact else 'f'}"
    source = dict(event, id=source_id)
    status, _ = http("POST", f"{instance['pe']}/api/sources", source)
    if status < 200 or status >= 300:
        return set(), f"source register -> {status}"
    try:
        status, payload = http("POST", f"{instance['pe']}/api/push", {"compact": compact})
        if status < 200 or status >= 300:
            return set(), f"push -> {status}"
        step = payload.get("step")
        if not isinstance(step, dict):
            return set(), "response carried no `step` object"
        return set(step.keys()), None
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
            keys, err = push_keys(inst, compact, event)
            if err:
                fail(f"{name}: {label} push unusable — {err}")
                entry[label] = {"error": err}
                continue
            missing = sorted(expected - keys)
            extra = sorted(keys - expected)
            entry[label] = {"keys": sorted(keys), "missing": missing, "unexpected": extra}
            print(f"  {label:<8} {len(keys)} key(s)")
            if missing:
                fail(f"{name}: {label} response missing {missing} — SURFACE_SPEC requires them")
            if extra:
                # Unexpected keys are a divergence too: a consumer written
                # against one runtime's extras breaks on the others.
                fail(f"{name}: {label} response carries unspecified {extra}")
        report["instances"].append(entry)

    # Cross-runtime equality is the point, and is worth asserting directly
    # rather than inferring from each runtime passing its own check.
    for label in ("compact", "full"):
        shapes = {
            json.dumps(e[label].get("keys"), sort_keys=True)
            for e in report["instances"]
            if isinstance(e.get(label), dict) and "keys" in e[label]
        }
        if len(shapes) > 1:
            fail(f"runtimes disagree on the {label} step shape: {sorted(shapes)}")

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
