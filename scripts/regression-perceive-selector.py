#!/usr/bin/env python3
"""
regression-perceive-selector.py — is the `only` subset selector honoured, and
is it free of side effects?

`POST /api/perceive` and `POST /api/push` accept an optional `only` selector
(`SURFACE_SPEC.md`, "POST /api/perceive takes an optional `only` selector";
RealityEngine_CI#367). It exists because a step answers ~1.6 MB at full corpus
and the transient allocation during serialization — not the working set —
exhausted two runtimes' heaps mid-sweep.

## Why a stage of its own, and why it is shaped like this

A filter is the easiest thing in this system to get wrong in a way nothing
reports, because **both of its failure modes look like success**:

  - *ignored* — the selector is parsed, accepted, and does nothing. The caller
    gets a correct answer, just a much larger one, and every assertion about the
    entries it wanted still passes. This is what LSP did: it filtered
    `mergeBatch`, `eventBus` and `activeRegions` and left `machineResults`
    whole, so a selected push still answered 1.36 MB — the selector's entire
    purpose, untouched, behind a selector that demonstrably worked.

  - *applied too early* — the selector is honoured on the wire and also changes
    what the engine computes. This is what C++ did: its Perception Engine
    forwarded `only` to the Reality Engine, the RE filters `machineResults` like
    every other field, and `aggregate_machine_outputs` reads that field to build
    the next InputSpaceVector. Measured on the live universe, one push, 1338
    machines resident:

        no selector   machineResults=1338   feeding the aggregator: 408
        only=<name>   machineResults=1      feeding the aggregator:   0

    A caller asking to be shown less silently got a different trajectory.

So this stage asks three separate questions, and a run that answers only the
first is the run that would have passed while both defects were live:

  1. **Honoured** — a selector narrows what comes back, on every surface, on
     every runtime.
  2. **Falsifiable** — a selection that matches nothing returns nothing. Not an
     error, and above all not the universe: a filter that silently widens on a
     miss cannot be distinguished from one that was ignored, and every
     assertion about the entries the caller wanted would still pass.
  3. **Inert** — driving the same steps with and without a selector leaves the
     runtime in the same state. This is the only one of the three that catches
     "applied too early", and it is deliberately a *within-runtime* comparison.
     Comparing runtimes to each other cannot catch it: if all three forwarded
     the selector they would starve their aggregators identically, agree
     perfectly, and the quorum would certify the defect.

## State is equalised before anything is compared

Every runtime is reset before it is probed. This is not tidiness — without it
the cross-runtime comparison is unsound, and it reported a false divergence
during this stage's own development: `mergeBatch` came back 193 on C++ and LSP
against 145 on Scala, which reads exactly like an engine defect. It was not.
The three runtimes had accumulated different numbers of steps, and driven from a
common reset they are identical at every push (201/1539, 698/2036, 915/2253).

`scripts/CLAUDE.md` already names this hazard for sources:

  > Sources must be equalised before anything is compared. An active source one
  > PE has and another does not is stimulus, and the trajectory comparison will
  > faithfully report the difference as engine divergence.

Accumulated steps are stimulus in exactly the same way. So the reset is a
precondition of the comparison rather than part of the inertness check, and
`--skip-inertness` does not skip it: without a reset the cross-runtime verdict
is reported as unsound rather than passed.

## Attribution

Selection is by sequence id, never by region — a region can have more than one
writer, a sequence id cannot — and by machine **name**, never id, because ids
are minted per runtime and are not comparable across the quorum (#146, #397).
For the same reason the cross-runtime comparison below is over *counts and
names*, not over the payloads themselves.

Quorum is 3-of-3 (`docs/QUORUM_CONTRACT.md`). A runtime that does not answer is
a failure, not an absent row: two live runtimes agreeing is not a quorum, and a
selector stage in particular must never report agreement it did not observe.

Usage:
  python3 scripts/regression-perceive-selector.py
  python3 scripts/regression-perceive-selector.py --registry http://127.0.0.1:5999/re-registry.json
  python3 scripts/regression-perceive-selector.py --skip-inertness   # no reset/drive
  python3 scripts/regression-perceive-selector.py --out report.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Callable
from urllib import error, request

# How many pushes each arm of the inertness comparison drives. Small on purpose:
# the aggregator's contribution reaches the next input vector on the step after
# it is merged, so one push cannot show the difference and two can. Three leaves
# a margin without making the stage a sweep.
INERTNESS_STEPS = 3

# A selector that cannot match. Not a random string: the point of the check is
# that a *well formed* request for something absent returns an empty selection,
# so the id has to be the shape a caller would really send.
ABSENT_SEQUENCE_ID = "regression-absent-sequence-id-0000"

SELECTED_FIELDS = ("machineResults", "mergeBatch", "eventBus", "activeRegions")


def read_instances(source: str) -> list[dict]:
    """The instance registry, from a URL or a path."""
    if source.startswith(("http://", "https://")):
        with request.urlopen(source, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    else:
        payload = json.loads(Path(source).read_text(encoding="utf-8"))
    return payload.get("instances", [])


def post(url: str, body: dict, timeout: int = 600) -> tuple[int, object]:
    data = json.dumps(body).encode("utf-8")
    req = request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except (error.URLError, OSError, ValueError) as exc:
        return 0, f"{type(exc).__name__}: {exc}"


def get(url: str, timeout: int = 600) -> tuple[int, object]:
    try:
        with request.urlopen(url, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except (error.URLError, OSError, ValueError) as exc:
        return 0, f"{type(exc).__name__}: {exc}"


def step_of(payload: object) -> dict | None:
    """The step, whether the surface returns it bare or wrapped.

    `POST /api/perceive` answers the step itself; `POST /api/push` wraps it as
    `{success, step, ...}`. Both are compared here, so the unwrapping has to be
    explicit rather than assumed from the URL.
    """
    if not isinstance(payload, dict):
        return None
    inner = payload.get("step")
    if isinstance(inner, dict):
        return inner
    return payload if "mergeBatch" in payload or "machineResults" in payload else None


def sizes(step: dict | None) -> dict[str, int | None]:
    """Entry counts per selectable field. `None` means the key is absent.

    Absent and empty are kept distinct throughout. `includeActiveRegions: false`
    omits the key, and reading an omission as "zero entries survived the filter"
    would let a runtime that was never asked pass as one that filtered
    correctly.
    """
    out: dict[str, int | None] = {}
    for field in SELECTED_FIELDS:
        if step is None or field not in step:
            out[field] = None
            continue
        value = step[field]
        out[field] = len(value) if isinstance(value, (list, dict)) else None
    return out


def pick_target(re_url: str) -> tuple[dict | None, str | None]:
    """A machine that declares at least one sequence, with its name and ids.

    Read from the corpus the runtime actually holds rather than from the
    Machines repo: the selector names things this engine must recognise, and a
    machine present on disk but absent from the runtime would make the whole
    stage read as "the filter dropped everything".
    """
    status, payload = get(f"{re_url}/api/machines")
    if status != 200:
        return None, f"GET /api/machines returned {status}"
    machines = payload.get("machines", payload) if isinstance(payload, dict) else payload
    if not isinstance(machines, list):
        return None, "/api/machines payload has no machines array"
    for machine in machines:
        if not isinstance(machine, dict):
            continue
        name = machine.get("name")
        ids = [s for s in (machine.get("sequenceIds") or []) if isinstance(s, str)]
        if name and ids:
            return {"name": name, "sequenceIds": ids}, None
    return None, "no machine in this runtime's corpus declares a sequence id"


def dimension(re_url: str) -> tuple[int | None, str | None]:
    """The runtime's grown Reality Event length.

    Read per runtime and never assumed from the launch value: `VECTOR_DIMENSION`
    is a seed, and every engine grows the event during machine loading
    (#364). A vector built to the seed would be zero-filled by the engine and
    the stage would be driving a shorter stimulus than it believes.
    """
    status, payload = get(f"{re_url}/api/config")
    if status != 200 or not isinstance(payload, dict):
        return None, f"GET /api/config returned {status}"
    for key in ("eventDimension", "dimension", "vectorDimension"):
        value = payload.get(key)
        if isinstance(value, int) and value > 0:
            return value, None
    return None, "/api/config reports no event dimension"


def probe_surface(url: str, base: dict, target: dict) -> dict:
    """Honoured-and-falsifiable, on one surface of one runtime."""
    cases = {
        "unfiltered": dict(base),
        "by-name": {**base, "only": {"machineNames": [target["name"]]}},
        "by-sequence": {**base, "only": {"sequenceIds": target["sequenceIds"]}},
        "absent-sequence": {**base, "only": {"sequenceIds": [ABSENT_SEQUENCE_ID]}},
        "names-nothing": {**base, "only": {}},
    }
    observed: dict[str, object] = {}
    for label, body in cases.items():
        status, payload = post(url, body)
        if status != 200:
            observed[label] = {"error": f"HTTP {status}", "detail": str(payload)[:400]}
            continue
        step = step_of(payload)
        if step is None:
            observed[label] = {"error": "response carried no step"}
            continue
        observed[label] = {"counts": sizes(step), "bytes": len(json.dumps(payload))}
    return observed


def judge_surface(observed: dict) -> list[str]:
    """What the observations on one surface prove, and what they refuse."""
    failures: list[str] = []
    for label, result in observed.items():
        if isinstance(result, dict) and "error" in result:
            failures.append(f"{label}: {result['error']}")
    if failures:
        return failures

    full = observed["unfiltered"]["counts"]

    # 1. Honoured. Compared against the unfiltered count rather than against a
    #    fixed number, so the check means the same thing at any corpus size.
    for label in ("by-name", "by-sequence"):
        counts = observed[label]["counts"]
        narrowed = [f for f in SELECTED_FIELDS
                    if full.get(f) is not None and counts.get(f) is not None
                    and counts[f] < full[f]]
        if not narrowed:
            failures.append(
                f"{label}: selector changed nothing — "
                f"{ {f: full.get(f) for f in SELECTED_FIELDS} } unfiltered vs "
                f"{ {f: counts.get(f) for f in SELECTED_FIELDS} } selected")
        # machineResults is called out by name because it is the dominant term
        # and the one a partial implementation leaves behind.
        if full.get("machineResults") and counts.get("machineResults") == full.get("machineResults"):
            failures.append(
                f"{label}: machineResults not filtered — {counts['machineResults']} entries "
                f"with a selector, same as without. This is the field the selector exists for "
                f"(1422 KB of a 1637 KB step at full corpus).")

    # 2. Falsifiable. A miss returns nothing; it must not widen back to the
    #    universe, which is indistinguishable from the selector being ignored.
    for label in ("absent-sequence", "names-nothing"):
        counts = observed[label]["counts"]
        for field in SELECTED_FIELDS:
            if counts.get(field) is None or full.get(field) is None:
                continue
            if counts[field] != 0:
                failures.append(
                    f"{label}: {field} kept {counts[field]} entries where the selection "
                    f"matches nothing"
                    + (" — the selector was ignored, not applied"
                       if counts[field] == full[field] else ""))
    return failures


def persistent_vector(pe_url: str) -> tuple[list[float] | None, str | None]:
    """The Perception Engine's own vector — the witness the inertness check needs.

    `assembledVector` on `GET /api/state` is what every runtime's machine-output
    aggregator writes into, and it becomes the next push's stimulus. That makes
    it the shortest path between "the selector reached the computation" and
    something observable: a starved aggregator merges fewer outputs and this
    vector moves.

    The Reality Engine's own `perceptualSpace` would diverge too, one hop later,
    but reading it costs 17 MB per fetch against this one's 4 MB and says the
    same thing less directly.
    """
    status, payload = get(f"{pe_url}/api/state")
    if status == 200 and isinstance(payload, dict):
        vector = payload.get("assembledVector")
        if isinstance(vector, list):
            return vector, None
    return None, f"GET {pe_url}/api/state carried no assembledVector (HTTP {status})"


def drive(pe_url: str, steps: int, only: dict | None) -> str | None:
    for index in range(steps):
        body: dict = {"compact": True}
        if only is not None:
            body["only"] = only
        status, _ = post(f"{pe_url}/api/push", body)
        if status != 200:
            return f"push {index} returned {status}"
    return None


def check_inertness(instance: dict, target: dict, reset) -> dict:
    """Does asking to be shown less change what the engine does?

    Two arms from the same reset state, same number of pushes, differing only in
    whether a selector was attached. The perceptual space afterwards must be
    identical. A runtime that forwards the selector into its own computation
    fails here and passes everything else.

    Within one runtime deliberately. Three runtimes that all forward the
    selector agree with each other perfectly, so a cross-runtime comparison
    would certify the defect rather than catch it.
    """
    pe_url = instance["pe_url"]
    arms: dict[str, list[float]] = {}
    for label, only in (("without", None), ("with", {"machineNames": [target["name"]]})):
        failed = reset(instance)
        if failed:
            return {"ok": None, "skipped": failed}
        failed = drive(pe_url, INERTNESS_STEPS, only)
        if failed:
            return {"ok": False, "error": f"{label} selector: {failed}"}
        vector, failed = persistent_vector(pe_url)
        if vector is None:
            return {"ok": None, "skipped": failed}
        arms[label] = vector

    if arms["with"] == arms["without"]:
        return {"ok": True, "cells": len(arms["with"])}
    differing = [i for i, (a, b) in enumerate(zip(arms["with"], arms["without"])) if a != b]
    return {
        "ok": False,
        "error": (f"the selector changed what the engine computed: "
                  f"{len(differing)} of {len(arms['without'])} cells of the Perception "
                  f"Engine's assembled vector differ after "
                  f"{INERTNESS_STEPS} identical pushes"),
        "firstDifferingCells": differing[:12],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry",
                    default=os.environ.get("RE_REGISTRY_URL",
                                           "/tmp/re-registry/re-registry.json"))
    ap.add_argument("--skip-inertness", action="store_true",
                    help="Skip the with/without drive comparison. It is the only check that "
                         "catches a selector applied to the computation rather than to the "
                         "reply, so skipping it is a narrower run, not a faster equivalent. "
                         "It does NOT skip the reset that equalises the runtimes: that is a "
                         "precondition of comparing them at all.")
    ap.add_argument("--out", help="Write the full report to this path.")
    args = ap.parse_args()

    try:
        instances = read_instances(args.registry)
    except Exception as exc:  # noqa: BLE001 — the registry being unreadable is the message
        print(f"instance registry unreadable at {args.registry}: {exc}", file=sys.stderr)
        return 2
    if not instances:
        print(f"no instances in {args.registry}", file=sys.stderr)
        return 2

    # Imported regardless of --skip-inertness: the reset is a precondition of
    # the cross-runtime comparison, not part of the inertness check.
    reset: Callable[[dict], str | None] | None = None
    if True:
        sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
        try:
            from reset_contract import reset_instances  # type: ignore[import-not-found]
        except ImportError as exc:
            print(f"note: inertness check unavailable ({exc}); running the other two",
                  file=sys.stderr)
        else:
            def reset(instance: dict) -> str | None:
                # `reset_instances` returns failure strings rather than raising,
                # and the registry spells the urls `re_url`/`pe_url` while the
                # contract defaults to `re`/`pe`.
                failures = reset_instances(post, [instance], re_key="re_url", pe_key="pe_url")
                return "; ".join(failures) if failures else None

    # Equalise before measuring. See "State is equalised before anything is
    # compared" above: two runtimes at different step counts are being driven by
    # different stimulus, and every count below scales with that.
    equalised = True
    if reset is None:
        equalised = False
    else:
        for instance in instances:
            failed = reset(instance)
            if failed:
                equalised = False
                break

    report: dict = {"instances": {}, "failures": [], "equalised": equalised}
    for instance in instances:
        rid = instance.get("id", "?")
        entry: dict = {}
        report["instances"][rid] = entry

        dim, failed = dimension(instance["re_url"])
        if dim is None:
            report["failures"].append(f"{rid}: {failed}")
            entry["error"] = failed
            continue
        entry["dimension"] = dim

        target, failed = pick_target(instance["re_url"])
        if target is None:
            report["failures"].append(f"{rid}: {failed}")
            entry["error"] = failed
            continue
        entry["target"] = target

        # The Reality Engine takes the vector; the Perception Engine assembles
        # its own from the sources it holds and takes none.
        for surface, url, base in (
            ("RE /api/perceive", f"{instance['re_url']}/api/perceive", {"vector": [0.0] * dim}),
            ("PE /api/push", f"{instance['pe_url']}/api/push", {"includeMachineResults": True}),
        ):
            observed = probe_surface(url, base, target)
            entry[surface] = observed
            for failure in judge_surface(observed):
                report["failures"].append(f"{rid} {surface}: {failure}")

        if reset is not None and not args.skip_inertness:
            entry["inertness"] = check_inertness(instance, target, reset)
            if entry["inertness"].get("ok") is False:
                report["failures"].append(f"{rid}: {entry['inertness']['error']}")
            elif entry["inertness"].get("ok") is None:
                report["failures"].append(
                    f"{rid}: inertness not measured — {entry['inertness'].get('skipped')}. "
                    f"Unmeasured is not passed: this is the only check that catches a "
                    f"selector applied to the computation.")

    # Cross-runtime: the same selector must select the same *number* of entries
    # everywhere. Counts and names, never the payloads — ids are minted per
    # runtime (#146, #397).
    #
    # Sound only against equalised state. Reported as unsound rather than
    # skipped: "we did not check" and "we checked and they agree" are different
    # findings, and a stage that quietly downgrades to the first while printing
    # the second is the failure class this whole file exists to catch.
    if not equalised:
        report["failures"].append(
            "cross-runtime comparison not made: the runtimes could not be reset to a "
            "common state, and counts from runtimes at different step counts compare "
            "stimulus rather than behaviour")
    for surface in ("RE /api/perceive", "PE /api/push") if equalised else ():
        for case in ("by-name", "by-sequence", "absent-sequence", "names-nothing"):
            seen: dict[str, str] = {}
            for rid, entry in report["instances"].items():
                observed = entry.get(surface)
                if not isinstance(observed, dict) or case not in observed:
                    continue
                result = observed[case]
                if isinstance(result, dict) and "counts" in result:
                    seen[rid] = json.dumps(result["counts"], sort_keys=True)
            if len(seen) < len(report["instances"]):
                report["failures"].append(
                    f"{surface} {case}: only {len(seen)} of {len(report['instances'])} "
                    f"runtimes answered — quorum is 3-of-3, and a runtime that did not "
                    f"answer is not agreement")
            if len(set(seen.values())) > 1:
                detail = "; ".join(f"{rid}={counts}" for rid, counts in sorted(seen.items()))
                report["failures"].append(f"{surface} {case}: runtimes disagree — {detail}")

    ok = not report["failures"]
    report["ok"] = ok

    print(f"perceive `only` selector — {len(report['instances'])} runtimes, "
          f"{INERTNESS_STEPS} pushes per inertness arm, "
          f"state {'equalised' if equalised else 'NOT equalised'}")
    for rid, entry in sorted(report["instances"].items()):
        if "error" in entry:
            print(f"  {rid:<8} unreadable: {entry['error']}")
            continue
        for surface in ("RE /api/perceive", "PE /api/push"):
            observed = entry.get(surface, {})
            row = []
            for case in ("unfiltered", "by-name", "by-sequence", "absent-sequence"):
                result = observed.get(case, {})
                if "counts" in result:
                    row.append(f"{case}={result['counts'].get('machineResults')}")
            print(f"  {rid:<8} {surface:<18} machineResults: {'  '.join(row)}")
        inert = entry.get("inertness")
        if inert is not None:
            verdict = {True: "inert", False: "CHANGED THE COMPUTATION", None: "not measured"}[inert.get("ok")]
            print(f"  {rid:<8} {'selector inertness':<18} {verdict}")

    if report["failures"]:
        print("\nfailures:")
        for failure in report["failures"]:
            print(f"  - {failure}")

    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nreport: {args.out}")

    print(f"\n{'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
