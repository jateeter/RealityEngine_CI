#!/usr/bin/env python3
"""Incremental corpus parity: does the corpus stay equivalent across engines as it grows?

`regression-trajectory-parity.py` answers whether the C++, LSP and Scala
runtimes evolve identically under one seed sequence against whatever corpus
happens to be loaded. It says nothing about *which* corpus, and a stack that
agrees on twelve machines has not been shown to agree on 1328 — divergence that
only appears once a particular machine is present is exactly the defect a
single whole-corpus run cannot locate.

This stage adds one machine at a time and re-runs the trajectory comparison
after each, so the corpus grows through every state between one machine and the
whole thing and the first machine whose presence splits the runtimes is named.

Each iteration:

1. `POST {re}/api/engine/reset` and `POST {pe}/api/reset` on every runtime, so
   the histories about to be compared start empty. Engine reset clears the
   ISRE/OSRE histories *and* zeroes the step counter — without the latter,
   `stepNumber` means something different per runtime after the first reset
   (RealityEngine_CI#148) and every iteration after the first would report a
   spurious split.
2. `POST {re}/api/machines` with the corpus JSON verbatim, on every runtime.
3. `POST {pe}/api/sources/bootstrap-from-machines`, so the PE half of the pair
   sees the machine too.
4. Activate every interned test source, push, and compare ISRE/OSRE histories.

The stimulus is the corpus's own. Loading a machine interns its
`inputSequences` as a test source over the machine's own region, so at
iteration n the sequences of machines 1..n are all interned and activating them
applies the merged set — one push advances every machine's sequence a step at
once. Iteration 1 runs machine 1's sequences, iteration 2 runs machines 1 and 2
merged, and so on, which is both the stimulus the app actually uses and a
harder test than a synthetic seed: it exercises the machines against each other
in the shared space rather than one at a time in isolation.

The step count defaults to the longest interned sequence, so a machine added
late is walked right through its own pattern instead of being truncated by a
fixed count.

Three result classes are kept apart, per the CI verification posture. They fail
independently and conflating them has repeatedly turned one defect into a
misdiagnosis of another:

* **load parity** — did every runtime accept the machine, and does every
  runtime now report the same machine count?
* **trajectory parity** — do the ISRE/OSRE histories agree?
* **iteration health** — did the seed sequence apply without transport errors?

No engine is a baseline. Runtimes are grouped into agreement clusters and a
split is reported as the split it is, so a two-to-one disagreement never
silently anoints the majority (#138).

Machine identity is matched by corpus `name`, never by id. The corpus declares
no id; each runtime mints its own (`machine-1787…`, `machine-1U358SX…`), so any
check that reaches for an id reports divergence unconditionally (#145).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path
from typing import Any


def load_trajectory_module() -> Any:
    """Import the trajectory-parity stage as a module.

    Its filename is hyphenated, so it cannot be imported by name. Reusing it
    rather than restating the comparison keeps one definition of what parity
    means — a second implementation would drift from it and the drift would
    read as an engine defect.
    """
    path = Path(__file__).with_name("regression-trajectory-parity.py")
    spec = importlib.util.spec_from_file_location("trajectory_parity", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot import trajectory parity stage from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TP = load_trajectory_module()


# ── corpus ────────────────────────────────────────────────────────────────────

def corpus_entries(machines_root: Path) -> list[str]:
    """Every machine JSON under machines/, as sorted machines/-relative paths.

    Sorted so a run is reproducible and `--start-index` means the same thing
    across invocations.
    """
    if not machines_root.is_dir():
        raise SystemExit(f"machine corpus directory not found: {machines_root}")
    return sorted(
        str(p.relative_to(machines_root))
        for p in machines_root.rglob("*.json")
    )


def read_machine(machines_root: Path, rel: str) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """Corpus file -> (wrapper, machine). None if it is not a machine document."""
    try:
        wrapper = json.loads((machines_root / rel).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(wrapper, dict):
        return None
    machine = wrapper.get("machine")
    if not isinstance(machine, dict) or "version" not in wrapper:
        return None
    return wrapper, machine


def non_binary_reason(machine: dict[str, Any]) -> str | None:
    """Why this machine is multi-valued, or None if it is binary.

    A machine's `perceptualMapping.bitsPerElement` declares the width of an
    element, and so the alphabet its cells range over. One bit is a Boolean
    cell; more than one is a multi-valued cell, whatever values the machine
    happens to use today.

    That declaration is the discriminator, and it is trustworthy: across the
    1328-machine corpus no machine declaring `bitsPerElement: 1` carries a
    declared value above 1 anywhere in its elements or output vectors. 1273
    machines declare 1, 54 declare 8, and 1 declares 4.

    Segregating on the declaration rather than on observed values is
    deliberate. 53 of the 55 wide machines currently use only 0 and 1, so a
    value-based rule would admit them and then be surprised the first time one
    of them emitted a 2 — which is exactly how FallDetection was reached at
    machine #691 after 691 apparently clean passes.

    Multi-valued machines are out of scope for this sweep and are collected for
    separate study rather than tested and failed: the merge fold, the arbiter's
    comparators and the ontology's gate semantics are all stated over Boolean
    cells, so a multi-valued machine is not something these engines currently
    claim to agree about (RealityEngine_CI#158).
    """
    bits = (machine.get("perceptualMapping") or {}).get("bitsPerElement")
    if not isinstance(bits, (int, float)) or bits <= 1:
        return None
    # Noted separately because it distinguishes a machine that merely *may* be
    # multi-valued from one that demonstrably *is*, which matters when picking
    # where to start on the mathematics.
    exercised = 0
    for sequence in machine.get("sequences") or []:
        for vector in sequence.get("vectors") or []:
            for element in vector.get("elements") or []:
                value = element.get("value")
                if isinstance(value, (int, float)) and value > 1:
                    exercised += 1
            for output in vector.get("outputVectors") or []:
                for cell in output.get("vector") or []:
                    if isinstance(cell, (int, float)) and cell > 1:
                        exercised += 1
    if exercised:
        return f"bitsPerElement={int(bits)}, {exercised} declared value(s) above 1"
    return f"bitsPerElement={int(bits)}, all declared values 0/1"


def region_span(machine: dict[str, Any], side: str) -> tuple[int, int] | None:
    """(start, end) of a machine's input or output region, or None."""
    region = (machine.get("perceptualMapping") or {}).get(side)
    if not isinstance(region, dict):
        return None
    try:
        offset, length = int(region["offset"]), int(region["length"])
    except (KeyError, TypeError, ValueError):
        return None
    return (offset, offset + length) if length > 0 else None


def spans_overlap(a: tuple[int, int] | None, b: tuple[int, int] | None) -> bool:
    return bool(a and b and a[0] < b[1] and b[0] < a[1])


# Pairs whose feedback ring is deliberate. RSRingLatchStage A and B are a test
# machine: an RS bistable split across two stages so the minimal provable
# feedback ring can be exercised end to end. Their descriptions say so, but
# nothing in the corpus marks it machine-readably, so the exemption is named
# here rather than inferred.
INTENTIONAL_RINGS: set[frozenset[str]] = {
    frozenset({"RS Ring Latch Stage A", "RS Ring Latch Stage B"}),
}


def guardrail_violations(machine: dict[str, Any],
                         loaded: dict[str, tuple[Any, Any]]) -> list[str]:
    """Cycles where a machine's response overwrites the stimulus that caused it.

    A response must never land on the cells that initiated it: that closes a
    stimulation -> response -> stimulation loop which re-fires every step. It is
    explorable on purpose in digital-logic and not permitted otherwise.

    Reported as its own class. A loop is a corpus defect, and every runtime
    would chase it identically, so surfacing it as a trajectory divergence would
    name the wrong thing.

    Upstream output feeding a *different* machine's input is the integration
    mechanism and is not a violation — only the cycle back onto the initiator is.
    """
    name = machine.get("name") or ""
    mine_in, mine_out = region_span(machine, "input"), region_span(machine, "output")
    violations = []

    if spans_overlap(mine_in, mine_out):
        violations.append(
            f"{name}: output {mine_out} overlaps its own input {mine_in} — self-stimulating")

    for other_name, (other_in, other_out) in loaded.items():
        if other_name == name:
            continue
        if spans_overlap(mine_out, other_in) and spans_overlap(other_out, mine_in):
            if frozenset({name, other_name}) in INTENTIONAL_RINGS:
                continue
            violations.append(
                f"{name} out{mine_out} -> in{other_in} {other_name}, and "
                f"{other_name} out{other_out} -> in{mine_in} {name} — response "
                f"overwrites the stimulus that caused it")
    return violations


def input_region(machine: dict[str, Any]) -> dict[str, int] | None:
    region = (machine.get("perceptualMapping") or {}).get("input")
    if not isinstance(region, dict):
        return None
    try:
        offset, length = int(region["offset"]), int(region["length"])
    except (KeyError, TypeError, ValueError):
        return None
    return {"offset": offset, "length": length} if length > 0 else None


# ── engine operations ─────────────────────────────────────────────────────────

def reset_instances(instances: list[dict[str, Any]]) -> list[str]:
    """Clear RE engine state (and its histories) and PE push state."""
    failures = []
    for instance in instances:
        status, _ = TP.post_json(f"{instance['re']}/api/engine/reset", {})
        if status != 200:
            failures.append(f"{instance['id']}: POST /api/engine/reset returned {status}")
        status, _ = TP.post_json(f"{instance['pe']}/api/reset", {})
        if status != 200:
            failures.append(f"{instance['id']}: POST /api/reset returned {status}")
    return failures


def machine_names(instance: dict[str, Any]) -> tuple[list[str], str | None]:
    """Machine names currently loaded on one runtime, in the order presented.

    Names, not ids: the corpus declares names and every runtime mints its own
    ids, so names are the only cross-runtime handle (#145).
    """
    status, payload = TP.get_json(f"{instance['re']}/api/machines")
    if status != 200:
        return [], f"{instance['id']}: GET /api/machines returned {status}"
    machines = payload.get("machines")
    if not isinstance(machines, list):
        return [], f"{instance['id']}: /api/machines payload has no machines array"
    return [str(m.get("name")) for m in machines if isinstance(m, dict)], None


def space_width(instance: dict[str, Any]) -> int | None:
    """Width of this runtime's perceptual space, or None if it will not say.

    Read from `GET /api/config`, which reports `vectorDimension` identically on
    all three runtimes. `GET /api/engine/stats` also carries a width but only on
    LSP — cpp returns `totalMachines`/`totalVectors`/`domainWorkerPool` and
    scala returns `sequenceStats`, so a capacity check written against stats
    silently does nothing on two engines of three.
    """
    status, payload = TP.get_json(f"{instance['re']}/api/config")
    if status != 200 or not isinstance(payload, dict):
        return None
    width = payload.get("vectorDimension")
    return int(width) if isinstance(width, (int, float)) else None


def clear_machines(instances: list[dict[str, Any]]) -> list[str]:
    """Remove every machine from every runtime (isolated mode only).

    Ids are fetched per runtime because each runtime minted its own.
    """
    failures = []
    for instance in instances:
        status, payload = TP.get_json(f"{instance['re']}/api/machines")
        if status != 200:
            failures.append(f"{instance['id']}: GET /api/machines returned {status}")
            continue
        for machine in payload.get("machines") or []:
            mid = machine.get("id") if isinstance(machine, dict) else None
            if not mid:
                continue
            status, _ = TP.delete_json(f"{instance['re']}/api/machines/{mid}")
            if status != 200:
                failures.append(f"{instance['id']}: DELETE /api/machines/{mid} returned {status}")
    return failures


def load_machine(instances: list[dict[str, Any]], wrapper: dict[str, Any]) -> list[str]:
    failures = []
    for instance in instances:
        status, payload = TP.post_json(f"{instance['re']}/api/machines", wrapper)
        if status not in (200, 201):
            detail = payload.get("error") or payload.get("message") or ""
            failures.append(
                f"{instance['id']}: POST /api/machines returned {status}"
                + (f" ({detail})" if detail else "")
            )
    return failures


def patch_json(url: str, payload: Any, timeout: int = 20) -> tuple[int, Any]:
    """PATCH helper; the trajectory-parity module carries GET/POST/DELETE only."""
    from urllib import request
    req = request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="PATCH",
        headers={"content-type": "application/json", "accept": "application/json"},
    )
    return TP.request_json(req, timeout)


def pe_sources(instance: dict[str, Any]) -> tuple[list[dict[str, Any]], str | None]:
    status, payload = TP.get_json(f"{instance['pe']}/api/sources")
    if status != 200:
        return [], f"{instance['id']}: GET /api/sources returned {status}"
    sources = payload.get("sources")
    if not isinstance(sources, list):
        return [], f"{instance['id']}: /api/sources payload has no sources array"
    return [s for s in sources if isinstance(s, dict)], None


def source_signature(source: dict[str, Any]) -> tuple[Any, ...]:
    """What a source *is*, with the runtime-minted id stripped.

    Two PEs presenting the same source must compare equal even though they
    numbered it differently, so identity is (name, region, type, active) — the
    things that determine what the source contributes to a push.
    """
    region = source.get("region") or {}
    return (source.get("name"), region.get("offset"), region.get("length"),
            source.get("type"), bool(source.get("active")))


def clear_sources(instances: list[dict[str, Any]]) -> list[str]:
    """Remove every source from every PE.

    Trajectory parity compares what each engine *did* with what it was given.
    That only means anything if they were given the same thing: an active source
    on one PE and not another writes its own values into that engine's ISRE on
    every push, and the comparison then reports a difference in configuration as
    a difference in behaviour. Observed on this stack as cpp-1 carrying 25
    sources (9 active) against lsp-1's 1 (0 active) and scala-1's 18 (2 active),
    where cpp's active `localai/rag_corrective_cycle` at [52:60] put 0.5 into
    cell 52 and split cpp from its peers on every machine tested.
    """
    failures = []
    for instance in instances:
        sources, err = pe_sources(instance)
        if err:
            failures.append(err)
            continue
        for source in sources:
            sid = source.get("id")
            if not sid:
                continue
            status, _ = TP.delete_json(f"{instance['pe']}/api/sources/{sid}")
            if status != 200:
                failures.append(f"{instance['id']}: DELETE /api/sources/{sid} returned {status}")
    return failures


def set_test_sources_active(instance: dict[str, Any], active: bool) -> tuple[int, int, list[str]]:
    """Force every test source to `active`. Returns (changed, total, failures).

    Loading a machine interns its `inputSequences` as a test source over the
    machine's own region. Iteration n therefore has the sequences of machines
    1..n interned, and activating all of them applies the merged set: one push
    advances every machine's sequence by one step at once. That merged stimulus
    is the thing under test, so it is set explicitly rather than inherited from
    whatever state each runtime's reset happened to leave behind.

    `changed` is the drift each runtime needed corrected — see the reset
    semantics documented below.

    `POST /api/reset` leaves the three runtimes in three different states, so
    the source set cannot be equalised by resetting and must be stated:

        cpp    keeps its sources; reports them inactive (GET /api/sources
               re-syncs them from the RE machine list at activateOnLoad=false,
               masking the `s.active = true` its own reset performs)
        lsp    discards its sources entirely
        scala  keeps its sources and activates every one of them
               (PerceptionEngine.scala reset(): `if (!t.active) … active = true`)

    An active test source replays its machine's input vectors into its region on
    every push, so this difference feeds the engines different inputs and lands
    as a trajectory divergence — machine #2 of the corpus split scala from
    cpp+lsp at ISRE cell 40, which is machine #1's region, not its own.

    The count returned is the drift itself and is reported rather than silently
    corrected: a runtime needing a change here disagreed with its peers about
    what a reset means.
    """
    sources, err = pe_sources(instance)
    if err:
        return 0, 0, [err]
    failures, changed, total = [], 0, 0
    for source in sources:
        if source.get("type") != "test":
            continue
        total += 1
        if bool(source.get("active")) == active:
            continue
        sid = source.get("id")
        if not sid:
            continue
        status, _ = patch_json(f"{instance['pe']}/api/sources/{sid}", {"active": active})
        if status != 200:
            failures.append(f"{instance['id']}: PATCH /api/sources/{sid} returned {status}")
        else:
            changed += 1

    # Verify the write survived a read. cpp answers this PATCH 200 with the new
    # value echoed back and then reports the old one on the next GET: its
    # GET /api/sources runs sync_test_sources_from_reality(), which rebuilds
    # every test source at `sourceActivateOnLoad` and discards the change. A
    # caller has no way to tell from the response that nothing happened, so the
    # discrepancy is checked rather than assumed.
    after, err = pe_sources(instance)
    if not err:
        stuck = sum(1 for s in after
                    if s.get("type") == "test" and bool(s.get("active")) == active)
        if total and stuck != total:
            failures.append(
                f"{instance['id']}: PATCH active={active} did not persist — "
                f"{stuck}/{total} test sources hold the value after a re-read; "
                f"start the PE with PE_SOURCE_ACTIVATE_ON_LOAD={str(active).lower()}")
    return changed, total, failures


def queue_head(history: list[dict[str, Any]], cells: int = 8) -> dict[str, Any] | None:
    """The head of an Input State Event Vector queue, as a comparable summary.

    The full entry carries the whole sparse vector, which is too wide to sit in
    a per-iteration record for 1328 iterations; the head is summarised as its
    step number, width, how many cells are set, and the first few of them in
    index order. Truncation is reported (`nonZeroCount` vs the listed cells) so
    a summary is never mistaken for the whole entry.
    """
    if not history:
        return None
    entry = history[0]
    non_zero = entry.get("nonZero") or []
    ordered = sorted(non_zero, key=lambda c: int(c.get("index", 0)))
    return {
        "stepNumber": entry.get("stepNumber"),
        "length": entry.get("length"),
        "nonZeroCount": len(ordered),
        "cells": [[int(c["index"]), float(c["value"])] for c in ordered[:cells]],
    }


def longest_sequence(instances: list[dict[str, Any]]) -> int:
    """Longest interned test sequence across the runtimes.

    Taken as a max over runtimes rather than from one: if they disagree about
    how many vectors a machine interned, the sweep must still walk the longest
    of them so the disagreement shows up as divergence instead of going
    unexercised.
    """
    longest = 0
    for instance in instances:
        sources, _ = pe_sources(instance)
        for source in sources:
            if source.get("type") != "test":
                continue
            inputs = source.get("inputs")
            if isinstance(inputs, list):
                longest = max(longest, len(inputs))
    return longest


def push(instance: dict[str, Any], steps: int, settle_ms: int) -> list[str]:
    """Advance every active source `steps` times.

    No sensor writes: the interned test sources carry the stimulus and advance
    themselves one vector per push, so a push is the whole step.
    """
    failures = []
    for index in range(steps):
        status, _ = TP.post_json(f"{instance['pe']}/api/push", {"compact": True})
        if status != 200:
            failures.append(f"{instance['id']}: push {index} failed (status {status})")
            break
        if settle_ms:
            time.sleep(settle_ms / 1000.0)
    return failures


def bootstrap_pe_sources(instances: list[dict[str, Any]]) -> list[str]:
    failures = []
    for instance in instances:
        status, _ = TP.post_json(f"{instance['pe']}/api/sources/bootstrap-from-machines", {})
        if status != 200:
            failures.append(
                f"{instance['id']}: POST /api/sources/bootstrap-from-machines returned {status}")
    return failures


# ── one iteration ─────────────────────────────────────────────────────────────

def run_iteration(instances: list[dict[str, Any]], machines_root: Path, rel: str,
                  index: int, args: argparse.Namespace,
                  loaded_regions: dict[str, tuple[Any, Any]] | None = None) -> dict[str, Any]:
    record: dict[str, Any] = {
        "index": index,
        "machineFile": rel,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "loadParity": {"ok": None, "failures": []},
        "guardrail": {"ok": None, "failures": []},
        "nonBinary": None,
        "capacity": {"ok": None, "failures": [], "space": {}},
        "sourceParity": {"ok": None, "failures": [], "counts": {}},
        "trajectoryParity": {"ok": None, "trajectories": {}, "failures": []},
        "health": {"failures": []},
        "status": "pass",
    }

    parsed = read_machine(machines_root, rel)
    if parsed is None:
        record["status"] = "skipped"
        record["skipReason"] = "not a versioned machine document"
        return record
    wrapper, machine = parsed
    record["machineName"] = machine.get("name")

    # Multi-valued machines are set aside, not loaded and not tested. The sweep
    # validates the binary corpus and collects the rest for separate study; the
    # fold, the comparators and the ontology's gate semantics are all stated
    # over Boolean cells, so these engines do not currently claim to agree about
    # a multi-valued machine (#158).
    reason = non_binary_reason(machine)
    if reason is not None:
        record["nonBinary"] = reason
        record["status"] = "non-binary"
        return record

    # Checked before the machine is loaded: a machine that closes a
    # response -> stimulus cycle with something already loaded is a corpus
    # defect, and running it would re-fire every step on every runtime.
    if loaded_regions is not None:
        record["guardrail"]["failures"] = guardrail_violations(machine, loaded_regions)
        record["guardrail"]["ok"] = not record["guardrail"]["failures"]
        loaded_regions[machine.get("name") or rel] = (
            region_span(machine, "input"), region_span(machine, "output"))
        if not record["guardrail"]["ok"]:
            record["status"] = "guardrail"
            return record

    region = input_region(machine)
    if region is None:
        record["status"] = "skipped"
        record["skipReason"] = "machine declares no perceptualMapping.input region"
        return record
    record["seedRegion"] = region

    if args.mode == "isolated":
        record["health"]["failures"].extend(clear_machines(instances))

    # Reset before loading: the comparison that follows reads histories, and
    # they must contain this iteration's steps and nothing else.
    record["health"]["failures"].extend(reset_instances(instances))

    load_failures = load_machine(instances, wrapper)
    record["loadParity"]["failures"].extend(load_failures)

    # Machine-count parity is a contract result, separate from trajectory
    # agreement: runtimes can hold different corpora and still walk identical
    # histories for a machine they all have, and reporting that as one result
    # hides which of the two actually broke.
    counts: dict[str, int] = {}
    present: dict[str, bool] = {}
    for instance in instances:
        names, err = machine_names(instance)
        if err:
            record["loadParity"]["failures"].append(err)
            continue
        counts[instance["id"]] = len(names)
        present[instance["id"]] = machine.get("name") in names
    record["loadParity"]["machineCounts"] = counts
    record["loadParity"]["machinePresent"] = present

    if len(set(counts.values())) > 1:
        shape = " | ".join("+".join(members) for members in TP.cluster(counts))
        record["loadParity"]["failures"].append(f"machine count differs across runtimes: {shape}")
    for name, ok in present.items():
        if not ok:
            record["loadParity"]["failures"].append(
                f"{name}: machine {machine.get('name')!r} absent from /api/machines after load")
    record["loadParity"]["ok"] = not record["loadParity"]["failures"]

    # Does the space this machine was just added to actually hold it?
    region_end = region["offset"] + region["length"]
    for instance in instances:
        width = space_width(instance)
        record["capacity"]["space"][instance["id"]] = width
        if width is not None and region_end > width:
            record["capacity"]["failures"].append(
                f"{instance['id']}: machine maps to [{region['offset']}:{region_end}] but the "
                f"perceptual space is {width} wide — raise VECTOR_DIMENSION; "
                f"this is a capacity limit, not a parity result")
    record["capacity"]["ok"] = not record["capacity"]["failures"]
    if not record["capacity"]["ok"]:
        # Seeding a region outside the space would compare noise. Report the
        # capacity limit and move on rather than manufacture a parity verdict.
        record["status"] = "capacity"
        return record

    # The PE half of loading the machine. Whether it produces the same source
    # set on every runtime is a contract result in its own right.
    record["health"]["failures"].extend(bootstrap_pe_sources(instances))

    # Activate every interned sequence: iteration n applies machines 1..n merged.
    # Set explicitly on all three so the stimulus is stated rather than inherited
    # from whatever each runtime's reset left behind.
    reactivated: dict[str, int] = {}
    interned: dict[str, int] = {}
    for instance in instances:
        changed, total, failures = set_test_sources_active(instance, True)
        reactivated[instance["id"]] = changed
        interned[instance["id"]] = total
        record["health"]["failures"].extend(failures)
    record["sourceParity"]["reactivatedByReset"] = reactivated
    record["sourceParity"]["internedSequences"] = interned
    # A runtime that needs a different number of sources activated than its peers
    # disagreed with them about what loading a machine leaves behind. That is an
    # engine defect and is reported as one.
    #
    # This was previously demoted to a note so the sweep could get past it. That
    # was the wrong call: the normalisation above makes the *comparison* valid,
    # but the disagreement it corrects is exactly what this stage exists to find,
    # so demoting it had the harness quietly absorb an engine defect on every
    # iteration. Equalising state left by a previous run is test hygiene;
    # equalising a difference the engines themselves produce deletes the result.
    if len(set(reactivated.values())) > 1:
        shape = " | ".join("+".join(members) for members in TP.cluster(reactivated))
        record["sourceParity"]["failures"].append(
            f"runtimes disagree on how many sources loading a machine leaves "
            f"active {reactivated}: {shape}")

    signatures: dict[str, list[list[Any]]] = {}
    for instance in instances:
        sources, err = pe_sources(instance)
        if err:
            record["sourceParity"]["failures"].append(err)
            continue
        signatures[instance["id"]] = sorted(
            [list(source_signature(s)) for s in sources], key=repr)
    record["sourceParity"]["counts"] = {k: len(v) for k, v in signatures.items()}
    if len(signatures) >= 2 and len({repr(v) for v in signatures.values()}) > 1:
        shape = " | ".join("+".join(members)
                           for members in TP.cluster({k: v for k, v in signatures.items()}))
        record["sourceParity"]["failures"].append(
            f"PE source sets differ after bootstrap: {shape}")
    record["sourceParity"]["ok"] = not record["sourceParity"]["failures"]

    # Apply the merged stimulus. Enough pushes to walk the longest interned
    # sequence right through, so a machine added late is exercised to the end of
    # its own pattern rather than truncated by a fixed step count.
    steps = args.steps if args.steps > 0 else max(longest_sequence(instances), 1)
    record["steps"] = steps
    for instance in instances:
        record["health"]["failures"].extend(push(instance, steps, args.settle_ms))

    trajectory_failures: list[str] = []
    for kind in TP.TRAJECTORIES:
        histories: dict[str, list[dict[str, Any]]] = {}
        for instance in instances:
            history, err = TP.fetch_history(instance, kind)
            if err:
                trajectory_failures.append(err)
                continue
            histories[instance["id"]] = history

        entry: dict[str, Any] = {
            "lengths": {name: len(h) for name, h in histories.items()},
            # Head of the queue: the oldest entry each runtime still holds.
            # The histories are queues trimmed from the front, so the head is
            # where a runtime that stopped stepping, started late, or trimmed
            # differently shows up — and it is the entry a divergence at step 0
            # is reported against. Carried alongside the current state so a
            # record says both what the queue starts with and how long it is.
            "head": {name: queue_head(h) for name, h in histories.items()},
            "divergence": None,
        }
        if len(histories) < 2:
            trajectory_failures.append(
                f"{kind}-history: fewer than two runtimes answered; parity not demonstrated")
        elif not any(histories.values()):
            trajectory_failures.append(
                f"{kind}-history: empty on every runtime after {steps} pushes")
        else:
            divergence = TP.first_divergence(histories)
            entry["divergence"] = divergence
            if divergence:
                shape = " | ".join("+".join(members) for members in divergence["clusters"])
                where = f"step {divergence['step']}"
                if "cell" in divergence:
                    where += f" cell {divergence['cell']}"
                trajectory_failures.append(
                    f"{kind}-history diverges at {where} ({divergence['kind']}): {shape}")
        record["trajectoryParity"]["trajectories"][kind] = entry

    record["trajectoryParity"]["failures"] = trajectory_failures
    record["trajectoryParity"]["ok"] = not trajectory_failures

    if (not record["loadParity"]["ok"] or not record["trajectoryParity"]["ok"]
            or not record["sourceParity"]["ok"]):
        record["status"] = "fail"
    elif record["health"]["failures"]:
        record["status"] = "error"
    return record


# ── driver ────────────────────────────────────────────────────────────────────

def completed_indices(path: Path) -> set[int]:
    """Indices already recorded, for --resume."""
    done: set[int] = set()
    if not path.exists():
        return done
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            done.add(int(json.loads(line)["index"]))
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            continue
    return done


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", default="http://127.0.0.1:5999/re-registry.json")
    parser.add_argument("--machines-root", type=Path, required=True,
                        help="RealityEngine_Machines/machines directory")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--run-id", default=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    parser.add_argument("--mode", choices=("cumulative", "isolated"), default="cumulative",
                        help="cumulative: corpus grows one machine per iteration (default). "
                             "isolated: every machine is removed before the next is loaded")
    parser.add_argument("--steps", type=int, default=0,
                        help="pushes per iteration; 0 (default) walks the longest interned "
                             "sequence right through")
    parser.add_argument("--settle-ms", type=int, default=250)
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--limit", type=int, default=0, help="0 runs the whole corpus")
    parser.add_argument("--skip", action="append", default=[],
                        help="corpus-relative path to skip; repeatable. Use for the machine the "
                             "universe already booted with")
    parser.add_argument("--resume", action="store_true",
                        help="append to an existing results file, skipping recorded indices")
    parser.add_argument("--stop-on-fail", action="store_true",
                        help="halt at the first machine that breaks parity")
    parser.add_argument("--keep-sources", action="store_true",
                        help="skip the run-start source quarantine. Diagnostic only: sources left "
                             "over from an earlier run are stimulus one runtime has and another "
                             "does not, and read as engine divergence")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    results_path = args.out / "corpus-parity-loop.jsonl"
    summary_path = args.out / "corpus-parity-summary.json"

    instances = TP.load_instances(args.registry)
    if len(instances) < 2:
        print(f"FAIL corpus parity needs at least two runtimes, found {len(instances)}",
              file=sys.stderr)
        return 1

    entries = corpus_entries(args.machines_root)
    skip = set(args.skip)
    already = completed_indices(results_path) if args.resume else set()
    if not args.resume and results_path.exists():
        results_path.unlink()

    selected = [(i, rel) for i, rel in enumerate(entries)
                if i >= args.start_index and rel not in skip and i not in already]
    if args.limit > 0:
        selected = selected[:args.limit]

    print(f"Corpus parity loop — {len(instances)} runtimes: {', '.join(i['id'] for i in instances)}")
    print(f"  corpus     {args.machines_root} ({len(entries)} machines)")
    print(f"  selected   {len(selected)} iteration(s), mode={args.mode}")
    print(f"  results    {results_path}")

    # Once, before anything is measured: bring every PE to the same empty source
    # set. Whatever a previous run, a bootstrap, or a runtime's own start-up
    # left behind is otherwise an input one engine has and another does not.
    if not args.keep_sources:
        before = {}
        for instance in instances:
            sources, _ = pe_sources(instance)
            before[instance["id"]] = len(sources)
        if len(set(before.values())) > 1:
            print(f"  sources    clearing pre-existing PE sources "
                  f"({', '.join(f'{k}={v}' for k, v in sorted(before.items()))}) "
                  f"— unequal source sets would read as engine divergence")
        for failure in clear_sources(instances):
            print(f"             {failure}")
    print()

    tally = {"pass": 0, "fail": 0, "error": 0, "skipped": 0, "capacity": 0,
             "guardrail": 0, "non-binary": 0}
    non_binary: list[dict[str, Any]] = []
    # Regions of every machine loaded so far, so a machine closing a
    # response -> stimulus cycle is caught as it is added.
    loaded_regions: dict[str, tuple] = {}
    reset_drift = {"iterations": 0, "byRuntime": {}}
    first_failure: dict[str, Any] | None = None
    started = time.time()

    with results_path.open("a", encoding="utf-8") as sink:
        for position, (index, rel) in enumerate(selected, start=1):
            record = run_iteration(instances, args.machines_root, rel, index, args,
                                   loaded_regions)
            # Written and flushed per iteration: a 1328-machine run is long
            # enough that partial results must be readable while it is running.
            sink.write(json.dumps(record, sort_keys=True) + "\n")
            sink.flush()

            tally[record["status"]] = tally.get(record["status"], 0) + 1
            if record["status"] == "non-binary":
                non_binary.append({"index": record["index"],
                                   "machineFile": record["machineFile"],
                                   "machineName": record.get("machineName"),
                                   "reason": record["nonBinary"]})
            activated = record["sourceParity"].get("reactivatedByReset") or {}
            if len(set(activated.values())) > 1:
                reset_drift["iterations"] += 1
                for name, count in activated.items():
                    reset_drift["byRuntime"][name] = reset_drift["byRuntime"].get(name, 0) + count
            marker = {"pass": "PASS", "fail": "FAIL", "error": "ERR ",
                      "skipped": "SKIP", "capacity": "CAP ", "guardrail": "LOOP",
                      "non-binary": "MVAL"}[record["status"]]
            print(f"[{position}/{len(selected)}] {marker} {rel}")
            for failures in (record["loadParity"]["failures"],
                             record["guardrail"]["failures"],
                             record["capacity"]["failures"],
                             record["sourceParity"]["failures"],
                             record["trajectoryParity"]["failures"],
                             record["health"]["failures"]):
                for item in failures:
                    print(f"          {item}")

            # On a break, print the head of each ISEV queue next to the current
            # depth. A divergence names one step and cell; the head says what
            # the queue those steps came out of actually starts with, which is
            # what separates "stepped to a different value" from "never
            # started" or "trimmed differently".
            if record["status"] == "fail":
                for kind, data in record["trajectoryParity"]["trajectories"].items():
                    for name in sorted(data.get("head") or {}):
                        head = data["head"][name]
                        depth = data["lengths"].get(name)
                        if head is None:
                            print(f"          {kind} {name}: queue empty (depth {depth})")
                        else:
                            cells = ", ".join(f"{i}={v:g}" for i, v in head["cells"])
                            more = ("+%d more" % (head["nonZeroCount"] - len(head["cells"]))
                                    if head["nonZeroCount"] > len(head["cells"]) else "")
                            print(f"          {kind} {name}: head step={head['stepNumber']} "
                                  f"depth={depth} set={head['nonZeroCount']} [{cells}{more}]")

            if record["status"] == "fail" and first_failure is None:
                first_failure = {"index": index, "machineFile": rel,
                                 "machineName": record.get("machineName"),
                                 "loadParity": record["loadParity"]["failures"],
                                 "trajectoryParity": record["trajectoryParity"]["failures"]}
                if args.stop_on_fail:
                    print("\nHalting at first parity break (--stop-on-fail)")
                    break

    summary = {
        "runId": args.run_id,
        "mode": args.mode,
        "instances": [i["id"] for i in instances],
        "corpusSize": len(entries),
        "iterationsRun": sum(tally.values()),
        "tally": tally,
        "firstFailure": first_failure,
        "resetSemanticsDrift": reset_drift,
        "nonBinaryMachines": non_binary,
        "elapsedSeconds": round(time.time() - started, 1),
        "results": str(results_path),
    }
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")

    print()
    if non_binary:
        listing = args.out / "non-binary-machines.json"
        listing.write_text(json.dumps(non_binary, indent=2, sort_keys=True), encoding="utf-8")
        print(f"\nset aside {len(non_binary)} multi-valued machine(s) -> {listing}")
    print(f"pass {tally['pass']}  fail {tally['fail']}  error {tally['error']}  "
          f"capacity {tally['capacity']}  non-binary {tally['non-binary']}  "
          f"skipped {tally['skipped']}  "
          f"({summary['elapsedSeconds']}s)")
    print(summary_path)

    if reset_drift["iterations"]:
        # Surfaced once, with its scale, rather than once per iteration.
        print(f"\nreset-semantics drift on {reset_drift['iterations']} iteration(s): "
              f"test sources left active after POST /api/reset "
              f"{reset_drift['byRuntime']} — normalised before each comparison, but the "
              f"runtimes disagree on what a reset does", file=sys.stderr)

    if tally["capacity"]:
        # Loud, and deliberately not a parity verdict: these machines were not
        # evaluated, so the run does not speak for them either way.
        print(f"\n{tally['capacity']} machine(s) map outside the perceptual space and were not "
              f"evaluated — re-run with a larger VECTOR_DIMENSION to cover them", file=sys.stderr)

    if first_failure:
        # The corpus is incremental, so everything after the first break is
        # downstream of it. Naming that machine is the finding.
        print(f"\nFAIL parity first breaks at #{first_failure['index']} "
              f"{first_failure['machineFile']}", file=sys.stderr)
        return 1
    if tally["error"]:
        print(f"\nFAIL {tally['error']} iteration(s) hit transport errors; parity not demonstrated",
              file=sys.stderr)
        return 1
    if tally["capacity"]:
        print(f"\nFAIL corpus not fully verified: {tally['pass']} machine(s) passed but "
              f"{tally['capacity']} were never evaluated", file=sys.stderr)
        return 1
    print(f"\nPASS corpus parity: {tally['pass']} machine(s) verified across "
          f"{len(instances)} runtimes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
