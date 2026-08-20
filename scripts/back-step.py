#!/usr/bin/env python3
"""Back-step the universe: return every machine to the state it held one step ago.

Re-testing a divergence found at machine n+1 needs the corpus that produced it —
machines 1..n as they stood, not a corpus rebuilt from scratch. Replaying the run
from a reset to get there is wasteful in a deterministic universe, and worse, it
is not the same scenario: replaying resets machines 1..n to their initial state,
whereas at iteration n+1 they carry the state their own run left them in.

The state that matters is each machine's **active Reality Event list**. Matching
runs against the REs that are currently active, and a match propagates `active`
to the connected REs, so that list is what the machine will do next. Back-
stepping means setting each machine's active RE list to the value it held at
step n-1.

## How this is done

Through `POST /api/machines/:id/checkpoints` and
`POST /api/machines/:machineId/checkpoints/:cpId/restore`, which all three
runtimes serve. Each stores a full snapshot of the machine and restores it by
replacing the registered machine with that snapshot — C++ keeps a `Machine`
copy, LSP clones through `machine-from-json … :full t`, and Scala holds
`machine.clone()`. Every one of those carries per-RE `state`, which is what
encodes active, so the checkpoint captures the active RE list by construction.

That is a **superset** of what a back-step strictly needs: it also restores
cursors and the per-cycle matched flags. For returning the universe to step n-1
that is the wanted behaviour — those are also step n-1 values. It is called out
because no runtime offers a way to set the active RE list on its own, so this is
the closest available primitive rather than a literal implementation of the
operation.

## Cost

One capture is two HTTP calls per machine per runtime, so a capture at every
step of a cumulative sweep is O(machines x steps x runtimes). Capture at the
steps you may want to return to, not unconditionally.

## Known gap

C++ serves `GET /api/machines/:id` from a stale copy: it reports the machine as
loaded, not as running, so its active RE list reads as the initial set no matter
how far the machine has advanced. Capture and restore still work there — they
operate on the live registry — but `verify` cannot confirm the result on C++
until that is fixed. LSP and Scala report live state (RealityEngine_Scala#48).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any
from urllib import error, request


def _request(url: str, method: str = "GET", body: Any = None,
             timeout: int = 60) -> tuple[int, Any]:
    req = request.Request(
        url, method=method,
        data=json.dumps(body).encode("utf-8") if body is not None else None,
        headers={"content-type": "application/json", "accept": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw) if raw else {}
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            return exc.code, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return exc.code, {"raw": raw}
    except (error.URLError, TimeoutError, OSError) as exc:
        return 0, {"error": str(exc)}


def instances(registry_url: str) -> list[dict[str, str]]:
    status, payload = _request(registry_url)
    if status != 200:
        raise SystemExit(f"registry unreachable at {registry_url} (status {status})")
    out = []
    for entry in payload.get("instances", []):
        re_url = entry.get("re_url") or entry.get("reUrl")
        if re_url:
            out.append({"id": entry.get("id"), "re": re_url.rstrip("/")})
    return out


def machines_on(instance: dict[str, str]) -> list[dict[str, Any]]:
    status, payload = _request(f"{instance['re']}/api/machines")
    if status != 200:
        return []
    return [m for m in payload.get("machines", []) if isinstance(m, dict)]


def active_res(instance: dict[str, str], machine_id: str) -> list[str] | None:
    """The machine's active Reality Events, by id. None when unreported.

    Empty and None are different answers: empty means the runtime reported REs
    and none were active, None means it reported no REs at all — which is what
    C++ does from its stale copy, and what Scala did before #48.
    """
    status, payload = _request(f"{instance['re']}/api/machines/{machine_id}")
    if status != 200:
        return None
    machine = payload.get("machine") or payload
    sequences = machine.get("sequences")
    if not isinstance(sequences, list):
        return None
    saw_any = False
    active: list[str] = []
    for sequence in sequences:
        vectors = sequence.get("vectors") if isinstance(sequence, dict) else None
        if not isinstance(vectors, list):
            continue
        for vector in vectors:
            if not isinstance(vector, dict):
                continue
            saw_any = True
            if vector.get("isActive"):
                active.append(str(vector.get("id")))
    return sorted(active) if saw_any else None


def capture(registry_url: str, label: str) -> dict[str, Any]:
    """Checkpoint every machine on every runtime. Returns a restorable manifest."""
    manifest: dict[str, Any] = {
        "label": label,
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "runtimes": {},
    }
    for instance in instances(registry_url):
        entries = []
        for machine in machines_on(instance):
            mid = machine.get("id")
            if not mid:
                continue
            status, payload = _request(
                f"{instance['re']}/api/machines/{mid}/checkpoints", "POST", {"label": label})
            cp = payload.get("checkpointId") or payload.get("id")
            entries.append({
                "machineId": mid,
                "machineName": machine.get("name"),
                "checkpointId": cp,
                "ok": status in (200, 201) and bool(cp),
                # Recorded so a restore can be checked against what was captured
                # rather than merely reported as having happened.
                "activeREs": active_res(instance, mid),
            })
        manifest["runtimes"][instance["id"]] = {"re": instance["re"], "machines": entries}
    return manifest


def restore(registry_url: str, manifest: dict[str, Any]) -> list[str]:
    failures = []
    by_id = {i["id"]: i for i in instances(registry_url)}
    for runtime, data in manifest.get("runtimes", {}).items():
        instance = by_id.get(runtime) or {"id": runtime, "re": data.get("re", "")}
        for entry in data.get("machines", []):
            cp, mid = entry.get("checkpointId"), entry.get("machineId")
            if not cp or not mid:
                failures.append(f"{runtime}: {entry.get('machineName')} has no checkpoint to restore")
                continue
            status, _ = _request(
                f"{instance['re']}/api/machines/{mid}/checkpoints/{cp}/restore", "POST", {})
            if status != 200:
                failures.append(
                    f"{runtime}: restore {entry.get('machineName')} -> {status}")
    return failures


def verify(registry_url: str, manifest: dict[str, Any]) -> tuple[int, int, list[str]]:
    """Compare the live active RE list against what the manifest captured."""
    by_id = {i["id"]: i for i in instances(registry_url)}
    checked = matched = 0
    notes = []
    for runtime, data in manifest.get("runtimes", {}).items():
        instance = by_id.get(runtime)
        if not instance:
            continue
        unreported = 0
        for entry in data.get("machines", []):
            want = entry.get("activeREs")
            if want is None:
                unreported += 1
                continue
            got = active_res(instance, entry["machineId"])
            checked += 1
            if got == want:
                matched += 1
            else:
                notes.append(f"{runtime}: {entry.get('machineName')} active REs "
                             f"{got} != captured {want}")
        if unreported:
            notes.append(f"{runtime}: {unreported} machine(s) report no Reality Events — "
                         f"back-step cannot be verified here (C++ serves a stale copy)")
    return checked, matched, notes


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", default="http://127.0.0.1:5999/re-registry.json")
    parser.add_argument("--capture", metavar="FILE", type=Path,
                        help="checkpoint every machine on every runtime, write the manifest here")
    parser.add_argument("--restore", metavar="FILE", type=Path,
                        help="restore every machine from the manifest — the back-step")
    parser.add_argument("--verify", metavar="FILE", type=Path,
                        help="compare live active RE lists against a manifest")
    parser.add_argument("--label", default="back-step")
    args = parser.parse_args()

    if args.capture:
        manifest = capture(args.registry, args.label)
        args.capture.parent.mkdir(parents=True, exist_ok=True)
        args.capture.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
        for runtime, data in sorted(manifest["runtimes"].items()):
            ms = data["machines"]
            reported = sum(1 for m in ms if m["activeREs"] is not None)
            print(f"  {runtime:8} captured {sum(1 for m in ms if m['ok'])}/{len(ms)} machines, "
                  f"{reported} reporting Reality Events")
        print(args.capture)
        return 0

    if args.restore:
        manifest = json.loads(args.restore.read_text(encoding="utf-8"))
        failures = restore(args.registry, manifest)
        for f in failures:
            print(f"FAIL {f}", file=sys.stderr)
        if failures:
            return 1
        total = sum(len(d["machines"]) for d in manifest["runtimes"].values())
        print(f"back-stepped {total} machine snapshot(s) to '{manifest.get('label')}'")
        return 0

    if args.verify:
        manifest = json.loads(args.verify.read_text(encoding="utf-8"))
        checked, matched, notes = verify(args.registry, manifest)
        for n in notes:
            print(f"  {n}")
        print(f"active RE lists matching the manifest: {matched}/{checked}")
        return 0 if checked and matched == checked else 1

    parser.error("one of --capture, --restore or --verify is required")


if __name__ == "__main__":
    raise SystemExit(main())
