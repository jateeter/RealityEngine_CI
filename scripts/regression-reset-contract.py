#!/usr/bin/env python3
"""Reset/source contract: do the runtimes agree on what they declare, and does reset leave it alone?

The acceptance stage for RealityEngine_CI#163, with the TTL property from
RealityEngine_CI#166 folded in.

**This stage fails against today's engines. That is the expected and correct
result.** It is written against the settled contract, not against the current
behaviour, so a green run would mean the contract had been implemented — not
that the stage is working. Every failure it reports today is one of the
divergences #163 measured, and the stage exists so those stop being read off a
sweep that has already normalised them away. Do not "fix" it by relaxing an
assertion; the assertions are the contract.

## The contract being asserted

*Sources are declared by integrations. Integrations register. Registration
declares.* (#163, as settled in comments; the issue body now carries it.)

1. Registration happens at boot from declared configuration or dynamically at
   runtime, with one meaning either way.
2. (a) Registration declares the source set immediately and completely.
   (b) Activity is earned by the first value — lazy *by design*, and it stays.
3. Membership and activity change on different events. Membership changes only
   on register and deregister. Reset does not *assign* activity, it *validates*
   it: a sensor holding a value outside its TTL is not active.
4. Reset is membership-neutral. It rewinds run state and manufactures nothing.
5. The store caches run state — values and activity — never membership.
6. The same configuration and the same registration sequence produce the same
   declared set on every runtime. This is the parity-testable form, and it is
   what this stage compares.

## What it does, in order

Phases are ordered so each observation is taken at the point where the property
is supposed to hold, never after something has had a chance to repair it.

1. **availability** — the registry answers, each RE serves `/api/machines`, each
   PE accepts `POST /api/reset`. Availability is deliberately established
   *without* reading `/api/sources`: on C++ that read is what materialises the
   source set (`sync_test_sources_from_reality()`), so an availability probe
   through it would hand the defect a place to hide.
2. **load parity** — optionally load a corpus subset into every RE, then compare
   the machine sets. Matched on corpus `name`, never on id: the corpus declares
   no id and every runtime mints its own (#146), so an id-matched check reports
   divergence unconditionally.
3. **registration** — `POST /api/sources/bootstrap-from-machines`, once per
   runtime. Under the settled contract this is a *registration*, not a
   workaround: the parity harness registering an integration that declares one
   source per machine carrying `inputSequences`. It stays, and it stays
   explicit. The first `/api/sources` read of the run happens here, and what it
   returns is `declaredAtRegistration` — point 2a.
4. **reset** — `POST {pe}/api/reset` followed immediately by
   `GET {pe}/api/sources`, with nothing in between for that runtime. **That read
   must be the first call after the reset** or C++'s lazy sync repairs the set
   before anyone looks at it, which is exactly how this defect stayed invisible.
   The set is compared against `declaredAtRegistration` (points 3 and 4) and
   across runtimes (point 6). One test source is held back unarmed across the
   reset as a control: it was never given a value, so no validation makes it
   active, and a runtime reporting it active assigned activity rather than
   validating it.
5. **trajectory parity** — push and compare ISRE/OREV histories with **no
   bootstrap and no PATCH after the reset**. The comparison itself is
   `regression-trajectory-parity.py`, imported as a module. There is one
   definition of what parity means and this stage is not a second one.
6. **TTL validation** (#166) — register a sensor, feed it a value with a short
   TTL, wait the TTL out, reset, and read. `active` must be `false`. Today all
   four runtimes answer `true`: none of them revalidate, and none of them clear
   `lastValue`/`lastUpdated`, so the information needed to validate is sitting
   right there unused.

## Result classes, kept apart

Per the CI verification posture, and because conflating them here has already
turned one defect into a misdiagnosis of another:

* **availability** — is the runtime up and answering at all?
* **load parity** — does every runtime hold the same corpus?
* **contract parity** — do they declare the same set, and does reset leave it
  alone and validate rather than assign? Phases 3, 4 and 6.
* **trajectory parity** — do the histories agree once they were given the same
  thing? Phase 5.

A contract-parity failure invalidates the trajectory result rather than adding
to it: engines that declared different source sets were pushed with different
stimulus, and comparing what they did with it measures the configuration
difference a second time.

## Two things this cannot read, and what it does instead

* **The playback cursor is not serialised.** No runtime puts it on the
  `/api/sources` payload (`to_json(const SourceConfig&)`, `reality.cpp:2065`, is
  representative). The issue's acceptance asks for cursors to be compared; they
  are observed indirectly instead, by the trajectory leg — a source whose cursor
  was not rewound replays the wrong vector on the first push after the reset and
  the histories split at step 0.
* **Payloads are not byte-compared.** LSP emits `ageMs` and `stale` on sensor
  sources that C++ and Scala do not (#166). That is a real divergence and it has
  its own issue; comparing raw payloads here would report it on every source and
  bury the membership finding. The comparison runs over a named projection
  (`DECLARED_FIELDS`) so it says what it means.

## The fourth runtime

#163 was scoped to C++, LSP and Scala. The TypeScript PE in
RealityEngine_Manager is a fourth implementation of the same surface and has the
same defect (`PerceptionEngine.ts:345`). It is usually absent from the runtime
registry, so pass it explicitly:

    --extra-runtime ts-1=http://localhost:3001,http://localhost:3004

## Usage

    python3 scripts/regression-reset-contract.py \
        --registry http://127.0.0.1:5999/re-registry.json \
        --machines-root ../RealityEngine_Machines/machines \
        --machines 8 \
        --out /tmp/reset-contract

Not wired into `regression-test.sh`. It fails by design, and a harness stage
that always fails is a harness stage everyone learns to ignore. Wire it in when
the contract lands.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path
from typing import Any


def load_stage(module_name: str, filename: str) -> Any:
    """Import a sibling stage as a module.

    The stage filenames are hyphenated, so they cannot be imported by name.
    Reusing them rather than restating what they do keeps one definition of
    what parity means and one definition of how a machine is loaded — a second
    implementation would drift, and the drift would read as an engine defect.
    """
    path = Path(__file__).with_name(filename)
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot import stage from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CL = load_stage("corpus_parity_loop", "regression-corpus-parity-loop.py")
TP = CL.TP  # the corpus loop already imported the trajectory stage; reuse that one


# ── the declared projection ───────────────────────────────────────────────────

# What a source *is*, with the runtime-minted id stripped and serialisation
# extras excluded. Ordered, so a signature is stable across runs.
DECLARED_FIELDS = (
    "name", "type", "offset", "length",
    "machineName", "sequenceName", "inputs", "loop",
    "sensorId", "ttlMs", "pattern",
)

# Membership is the set of these. Activity is not part of membership — that is
# the whole point of contract point 3, and folding `active` into the identity
# would make an activity change look like a membership change.
MEMBERSHIP_FIELDS = ("name", "type", "offset", "length", "machineName")


def declared(source: dict[str, Any]) -> dict[str, Any]:
    """One source, projected onto the fields the contract speaks about.

    `id` is dropped: ids are minted per runtime (#146). `lastValue` and
    `lastUpdated` are dropped: they are cached run state and they move with the
    clock, so including them would make every comparison fail for a reason the
    contract does not care about. `active` is carried separately because it is
    validated, not declared.
    """
    region = source.get("region") or {}
    flat = dict(source)
    flat["offset"] = region.get("offset")
    flat["length"] = region.get("length")
    return {field: flat.get(field) for field in DECLARED_FIELDS if field in flat}


def membership_key(source: dict[str, Any]) -> str:
    """The cross-runtime handle for one source.

    A test source's handle is its machine name; a sensor's is its own name.
    Never the id. This is the "match on machine name, never on id" rule, and it
    is why a runtime numbering its sources differently does not read as a
    divergence.
    """
    region = source.get("region") or {}
    parts = [
        str(source.get("machineName") or source.get("name") or "?"),
        str(source.get("type") or "?"),
        str(region.get("offset")),
        str(region.get("length")),
    ]
    return "::".join(parts)


def source_map(sources: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Declared sources by membership key.

    A duplicate key is itself a finding — two sources a runtime cannot tell
    apart by anything the contract names — so it is recorded rather than
    silently collapsed.
    """
    out: dict[str, dict[str, Any]] = {}
    for source in sources:
        key = membership_key(source)
        if key in out:
            key = f"{key}::dup{sum(1 for k in out if k.startswith(key))}"
        out[key] = {"declared": declared(source), "active": bool(source.get("active"))}
    return out


def compare_declared(sets: dict[str, dict[str, dict[str, Any]]]) -> list[str]:
    """Cross-runtime comparison of declared sets. Contract point 6.

    No baseline runtime. Every key present anywhere is examined on every
    runtime and disagreement is reported as the clusters it forms, so a
    two-to-one split never silently anoints the majority (#138).
    """
    failures: list[str] = []
    if len(sets) < 2:
        return ["fewer than two runtimes answered; declared-set parity not demonstrated"]

    all_keys = sorted({key for entries in sets.values() for key in entries})
    missing = {key: {name: (key in entries) for name, entries in sets.items()}
               for key in all_keys}
    absent = [key for key, presence in missing.items() if not all(presence.values())]
    if absent:
        for key in absent[:10]:
            holders = "+".join(sorted(n for n, present in missing[key].items() if present))
            lacking = "+".join(sorted(n for n, present in missing[key].items() if not present))
            failures.append(f"source {key!r} declared by {holders}, absent from {lacking}")
        if len(absent) > 10:
            failures.append(f"... and {len(absent) - 10} further membership disagreement(s)")

    for key in all_keys:
        if key in absent:
            continue
        values = {name: entries[key]["declared"] for name, entries in sets.items()}
        if len({json.dumps(v, sort_keys=True) for v in values.values()}) > 1:
            shape = " | ".join("+".join(members) for members in TP.cluster(values))
            failures.append(f"source {key!r} declared differently across runtimes: {shape}")
    return failures


# ── phases ────────────────────────────────────────────────────────────────────

def check_availability(instances: list[dict[str, Any]]) -> list[str]:
    """Is every runtime up and answering?

    Deliberately does not read `/api/sources`. That read is what materialises
    the set on C++, so probing availability through it would hand the defect
    somewhere to hide before the measurement starts.
    """
    failures = []
    for instance in instances:
        status, _ = TP.get_json(f"{instance['re']}/api/machines")
        if status != 200:
            failures.append(f"{instance['id']}: RE GET /api/machines returned {status}")
        status, _ = TP.post_json(f"{instance['pe']}/api/reset", {})
        if status != 200:
            failures.append(f"{instance['id']}: PE POST /api/reset returned {status}")
    return failures


def select_corpus(machines_root: Path, wanted: int, width: int | None) -> list[dict[str, Any]]:
    """A known corpus subset: the first `wanted` binary machines that fit.

    Multi-valued machines are excluded on the same grounds the corpus sweep
    excludes them — the fold, the comparators and the gate semantics are stated
    over Boolean cells, so these engines do not currently claim to agree about a
    multi-valued machine (#158). A machine mapping outside the perceptual space
    is a capacity limit and is skipped rather than loaded and failed.
    """
    chosen: list[dict[str, Any]] = []
    for rel in CL.corpus_entries(machines_root):
        if len(chosen) >= wanted:
            break
        parsed = CL.read_machine(machines_root, rel)
        if parsed is None:
            continue
        wrapper, machine = parsed
        if CL.non_binary_reason(machine) is not None:
            continue
        region = CL.input_region(machine)
        if region is None:
            continue
        if width is not None and region["offset"] + region["length"] > width:
            continue
        chosen.append({"rel": rel, "wrapper": wrapper, "name": machine.get("name")})
    return chosen


def load_corpus(instances: list[dict[str, Any]], machines_root: Path,
                wanted: int) -> tuple[dict[str, Any], list[str]]:
    """Clear every RE and load the same subset into all of them."""
    failures: list[str] = []
    width = min((w for w in (CL.space_width(i) for i in instances) if w is not None),
                default=None)
    subset = select_corpus(machines_root, wanted, width)
    if not subset:
        return {"loaded": []}, ["no loadable corpus machine found; nothing to compare"]

    failures.extend(CL.clear_machines(instances))
    for entry in subset:
        failures.extend(CL.load_machine(instances, entry["wrapper"]))
    return {"loaded": [e["name"] for e in subset], "spaceWidth": width}, failures


def compare_machines(instances: list[dict[str, Any]]) -> tuple[dict[str, Any], list[str]]:
    """Load parity: does every runtime hold the same corpus, by name?"""
    failures: list[str] = []
    names: dict[str, list[str]] = {}
    for instance in instances:
        loaded, err = CL.machine_names(instance)
        if err:
            failures.append(err)
            continue
        names[instance["id"]] = sorted(loaded)
    counts = {name: len(v) for name, v in names.items()}
    if len(names) >= 2 and len({json.dumps(v) for v in names.values()}) > 1:
        shape = " | ".join("+".join(members) for members in TP.cluster(counts))
        failures.append(f"runtimes hold different machine sets: {shape}")
    return {"machineCounts": counts}, failures


def register_integration(instances: list[dict[str, Any]]) -> list[str]:
    """`POST /api/sources/bootstrap-from-machines` — a registration, not a repair.

    Contract point 1: registration at runtime and registration at boot are the
    same event with the same result. This is the parity harness's own
    integration declaring one source per machine that carries `inputSequences`.
    """
    return CL.bootstrap_pe_sources(instances)


def read_sources(instance: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], str | None]:
    sources, err = CL.pe_sources(instance)
    if err:
        return {}, err
    return source_map(sources), None


def reset_then_read(instance: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """`POST /api/reset`, then `GET /api/sources` as the very next call.

    Nothing may go between these two for a given runtime. The whole defect is
    read-triggered: C++ rebuilds its test sources inside
    `sync_test_sources_from_reality()` on the first read, so any intervening
    call — a health probe, a state read, another runtime's push routed through a
    shared proxy — repairs the set before it is observed. Resets are issued
    per runtime immediately followed by that runtime's read rather than as two
    passes over the instance list, for the same reason.
    """
    failures: list[str] = []
    status, _ = TP.post_json(f"{instance['pe']}/api/reset", {})
    if status != 200:
        return {}, [f"{instance['id']}: POST /api/reset returned {status}"]
    entries, err = read_sources(instance)
    if err:
        failures.append(err)
    return entries, failures


def arm_fixture(instance: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Arm the harness's own test sources — all but one — once, *before* the reset.

    Legitimate under the settled contract: the harness is choosing to arm its
    own fixture, not compensating for a broken reset. The thing the contract
    must make unnecessary is arming it *again afterwards*, so this runs here and
    never after the reset phase, and whether the reset silently re-armed
    anything is measured rather than corrected.

    **One source is held back, deliberately inactive.** Without it, point 3 is
    untestable on test sources: if the harness arms everything, a reset that
    forces `active = true` is indistinguishable from a reset that validated an
    already-active source and left it alone. The held-back source is the control
    — after the reset it must still be inactive, because nothing gave it a
    value. It is chosen by membership key, which carries no id, so every runtime
    holds back the same machine's source and the stimulus stays equal.

    `CL.set_test_sources_active` is not reused here even though it does most of
    this: it arms every source unconditionally, which is exactly the control
    this phase needs to keep.
    """
    failures: list[str] = []
    sources, err = CL.pe_sources(instance)
    if err:
        return {}, [err]

    tests = sorted((s for s in sources if s.get("type") == "test"), key=membership_key)
    if not tests:
        return {"armed": 0, "total": 0, "heldBack": None}, []

    held, arming = tests[0], tests[1:]
    armed = 0
    for source in arming:
        sid = source.get("id")
        if not sid or bool(source.get("active")):
            continue
        status, _ = CL.patch_json(f"{instance['pe']}/api/sources/{sid}", {"active": True})
        if status != 200:
            failures.append(f"{instance['id']}: PATCH /api/sources/{sid} returned {status}")
        else:
            armed += 1

    # Verify the writes survived a read. C++ answers this PATCH 200 with the new
    # value echoed back and then reports the old one on the next GET, because
    # its GET /api/sources rebuilds every test source at `sourceActivateOnLoad`.
    # A caller cannot tell from the response that nothing happened, so it is
    # checked rather than assumed.
    after, err = read_sources(instance)
    if err:
        failures.append(err)
    else:
        live = sum(1 for entry in after.values()
                   if entry["declared"].get("type") == "test" and entry["active"])
        if live != len(arming):
            failures.append(
                f"{instance['id']}: arming did not persist — {live}/{len(arming)} test "
                f"sources hold active=true after a re-read; start the PE with "
                f"PE_SOURCE_ACTIVATE_ON_LOAD=true if this runtime cannot be armed over the API")
    return {"armed": armed, "total": len(tests), "heldBack": membership_key(held)}, failures


def activity_delta(before: dict[str, dict[str, Any]],
                   after: dict[str, dict[str, Any]]) -> dict[str, int]:
    """How the reset moved each source's `active` flag.

    `assigned` counts sources the reset turned on. Under contract point 3 that
    is zero: reset validates activity, it does not assign it. `dropped` counts
    sources it turned off, which is legitimate only where validation demands it
    — a source whose value fell outside its TTL.
    """
    assigned = sum(1 for key, entry in after.items()
                   if key in before and entry["active"] and not before[key]["active"])
    dropped = sum(1 for key, entry in after.items()
                  if key in before and not entry["active"] and before[key]["active"])
    return {"assigned": assigned, "dropped": dropped}


def membership_delta(before: dict[str, dict[str, Any]],
                     after: dict[str, dict[str, Any]]) -> dict[str, list[str]]:
    """Contract point 4: reset is membership-neutral, so both lists are empty."""
    return {
        "appeared": sorted(set(after) - set(before)),
        "vanished": sorted(set(before) - set(after)),
    }


def run_trajectory(instances: list[dict[str, Any]], steps: int,
                   settle_ms: int) -> tuple[dict[str, Any], list[str]]:
    """Push and compare ISRE/OREV, with no bootstrap and no PATCH in the path.

    The interned test sources carry the stimulus and advance themselves one
    vector per push, so a push is the whole step. The comparison is the
    trajectory stage's, unmodified.
    """
    failures: list[str] = []
    for instance in instances:
        failures.extend(CL.push(instance, steps, settle_ms))

    record: dict[str, Any] = {}
    for kind in TP.TRAJECTORIES:
        histories: dict[str, list[dict[str, Any]]] = {}
        for instance in instances:
            history, err = TP.fetch_history(instance, kind)
            if err:
                failures.append(err)
                continue
            histories[instance["id"]] = history
        entry: dict[str, Any] = {
            "lengths": {name: len(h) for name, h in histories.items()},
            "divergence": None,
        }
        if len(histories) < 2:
            failures.append(f"{kind}-history: fewer than two runtimes answered")
        elif not any(histories.values()):
            failures.append(f"{kind}-history: empty on every runtime after {steps} pushes")
        else:
            divergence = TP.first_divergence(histories)
            entry["divergence"] = divergence
            if divergence:
                shape = " | ".join("+".join(m) for m in divergence["clusters"])
                where = f"step {divergence['step']}"
                if "cell" in divergence:
                    where += f" cell {divergence['cell']}"
                failures.append(f"{kind}-history diverges at {where} "
                                f"({divergence['kind']}): {shape}")
        record[kind] = entry
    return record, failures


def run_ttl_validation(instance: dict[str, Any], region: dict[str, int],
                       ttl_ms: int, run_id: str) -> tuple[dict[str, Any], list[str]]:
    """#166: an expired sensor must not be `active` after a reset.

    Register a sensor, feed it one value, let the TTL lapse, reset, read. Every
    runtime already applies exactly this predicate in its assembly path — an
    expired sensor correctly contributes zeros — so the fix is to apply the
    predicate that is already written to the flag maintained elsewhere. Today
    all four answer `active: true`.

    Registering and deleting a source is a membership change, which contract
    point 3 permits: register and deregister are precisely the two events that
    are allowed to move membership. It runs last so it cannot perturb the
    declared-set comparison.
    """
    pe = instance["pe"]
    sid = f"reset-contract-ttl-{run_id}"
    record: dict[str, Any] = {"sourceId": sid, "ttlMs": ttl_ms}
    failures: list[str] = []

    # Every field sent explicitly. Scala's decoder 400s on a body missing
    # `type`, `active`, `lastValue` or `lastUpdated` where the others fill in
    # defaults; that request-side divergence has its own finding and this stage
    # is not the place to re-measure it.
    status, _ = TP.post_json(f"{pe}/api/sources", {
        "id": sid,
        "type": "sensor",
        "name": "reset-contract ttl probe",
        "region": region,
        "active": False,
        "sensorId": sid,
        "lastValue": [0.0] * region["length"],
        "lastUpdated": None,
        "ttlMs": ttl_ms,
    })
    if status not in (200, 201):
        return record, [f"{instance['id']}: TTL probe registration returned {status}"]

    try:
        status, _ = TP.post_json(f"{pe}/api/sensors/{sid}", {"values": [1.0] * region["length"]})
        if status != 200:
            return record, [f"{instance['id']}: TTL probe sensor write returned {status}"]

        # Contract point 2b: the first value earns activity. Recorded rather
        # than asserted — a runtime that does not do this is a different
        # finding from one that fails to revalidate, and the two must not read
        # the same.
        entries, err = read_sources(instance)
        if err:
            failures.append(err)
        record["activeAfterFirstValue"] = next(
            (e["active"] for k, e in entries.items() if sid in k or "ttl probe" in k.lower()), None)

        time.sleep((ttl_ms + 500) / 1000.0)

        entries, errs = reset_then_read(instance)
        failures.extend(errs)
        probe = next((e for k, e in entries.items() if sid in k or "ttl probe" in k.lower()), None)
        if probe is None:
            # Vanishing is a point-4 violation, not a pass. A reset that drops
            # the source has not validated it, it has deleted the question.
            failures.append(f"{instance['id']}: TTL probe absent from /api/sources after reset "
                            f"— reset dropped a registered source (point 4)")
            record["activeAfterReset"] = None
        else:
            record["activeAfterReset"] = probe["active"]
            if probe["active"]:
                failures.append(
                    f"{instance['id']}: sensor whose value fell outside its {ttl_ms}ms TTL "
                    f"still reports active:true after POST /api/reset — reset assigns "
                    f"activity instead of validating it (#166, point 3)")
    finally:
        TP.delete_json(f"{pe}/api/sources/{sid}")
    return record, failures


# ── driver ────────────────────────────────────────────────────────────────────

def parse_extra_runtime(spec: str) -> dict[str, Any]:
    """`id=re_url,pe_url` — a runtime the registry does not carry.

    The TypeScript PE in RealityEngine_Manager is the fourth implementation of
    this surface and is not usually registered, so it has to be named.
    """
    try:
        ident, urls = spec.split("=", 1)
        re_url, pe_url = urls.split(",", 1)
    except ValueError:
        raise SystemExit(f"--extra-runtime expects id=re_url,pe_url, got {spec!r}")
    return {"id": ident.strip(), "re": re_url.strip().rstrip("/"), "pe": pe_url.strip().rstrip("/")}


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", default="http://127.0.0.1:5999/re-registry.json")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--run-id", default=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    parser.add_argument("--machines-root", type=Path,
                        help="RealityEngine_Machines/machines. Omitted: compare whatever "
                             "corpus the runtimes already hold, and skip the load phase")
    parser.add_argument("--machines", type=int, default=8,
                        help="size of the corpus subset to load (default 8)")
    parser.add_argument("--steps", type=int, default=0,
                        help="pushes for the trajectory leg; 0 (default) walks the longest "
                             "interned sequence right through")
    parser.add_argument("--settle-ms", type=int, default=250)
    parser.add_argument("--probe-offset", type=int, default=12,
                        help="region for the TTL probe. The probe is never pushed, so the "
                             "region only has to exist")
    parser.add_argument("--probe-length", type=int, default=4)
    parser.add_argument("--probe-ttl-ms", type=int, default=1500)
    parser.add_argument("--extra-runtime", action="append", default=[],
                        help="id=re_url,pe_url for a runtime absent from the registry — "
                             "notably the TypeScript PE. Repeatable")
    parser.add_argument("--skip-trajectory", action="store_true",
                        help="stop after the contract phases. Useful while the contract is "
                             "still failing, since a trajectory result taken over unequal "
                             "source sets says nothing")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    summary_path = args.out / "reset-contract-summary.json"

    instances = TP.load_instances(args.registry)
    instances.extend(parse_extra_runtime(spec) for spec in args.extra_runtime)
    if len(instances) < 2:
        print(f"FAIL reset contract needs at least two runtimes, found {len(instances)}",
              file=sys.stderr)
        return 1

    summary: dict[str, Any] = {
        "runId": args.run_id,
        "instances": [i["id"] for i in instances],
        "availability": {"ok": None, "failures": []},
        "loadParity": {"ok": None, "failures": [], "corpus": {}},
        "contractParity": {"ok": None, "failures": [], "declared": {}, "reset": {},
                           "ttlValidation": {}},
        "trajectoryParity": {"ok": None, "skipped": args.skip_trajectory,
                             "trajectories": {}, "failures": []},
    }

    print(f"Reset/source contract — {len(instances)} runtime(s): "
          f"{', '.join(i['id'] for i in instances)}")
    print("  this stage is written against RealityEngine_CI#163's settled contract,")
    print("  not against current behaviour: failures below are the finding.")
    print()

    # ── availability ──────────────────────────────────────────────────────────
    summary["availability"]["failures"] = check_availability(instances)
    summary["availability"]["ok"] = not summary["availability"]["failures"]
    if not summary["availability"]["ok"]:
        # Nothing downstream means anything against a runtime that is not
        # answering, and reporting a contract verdict over a dead engine would
        # be reporting availability twice under a different name.
        for item in summary["availability"]["failures"]:
            print(f"FAIL availability: {item}", file=sys.stderr)
        summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
        print(summary_path)
        return 1

    # ── load parity ───────────────────────────────────────────────────────────
    load_failures: list[str] = []
    if args.machines_root:
        corpus, errs = load_corpus(instances, args.machines_root, args.machines)
        summary["loadParity"]["corpus"] = corpus
        load_failures.extend(errs)
    else:
        summary["loadParity"]["corpus"] = {"loaded": None,
                                           "note": "no --machines-root; using the loaded corpus"}
    counts, errs = compare_machines(instances)
    summary["loadParity"]["corpus"].update(counts)
    load_failures.extend(errs)
    summary["loadParity"]["failures"] = load_failures
    summary["loadParity"]["ok"] = not load_failures

    # ── registration: contract point 2a ───────────────────────────────────────
    contract_failures: list[str] = list(register_integration(instances))

    declared_at_registration: dict[str, dict[str, dict[str, Any]]] = {}
    for instance in instances:
        entries, err = read_sources(instance)
        if err:
            contract_failures.append(err)
            continue
        declared_at_registration[instance["id"]] = entries
    summary["contractParity"]["declared"] = {
        "atRegistration": {name: {"count": len(e),
                                  "active": sum(1 for v in e.values() if v["active"])}
                           for name, e in declared_at_registration.items()},
    }
    for failure in compare_declared(declared_at_registration):
        contract_failures.append(f"at registration: {failure}")

    armed: dict[str, Any] = {}
    held_back: dict[str, str | None] = {}
    for instance in instances:
        record, errs = arm_fixture(instance)
        contract_failures.extend(errs)
        armed[instance["id"]] = record
        held_back[instance["id"]] = record.get("heldBack")
    summary["contractParity"]["armedBeforeReset"] = armed
    if len({json.dumps(v) for v in held_back.values()}) > 1:
        contract_failures.append(
            f"runtimes held back different control sources {held_back} — the declared sets "
            f"already disagree, so the stimulus below is not equal either")

    armed_state: dict[str, dict[str, dict[str, Any]]] = {}
    for instance in instances:
        entries, err = read_sources(instance)
        if err:
            contract_failures.append(err)
            continue
        armed_state[instance["id"]] = entries

    # ── reset: contract points 3, 4 and 6 ─────────────────────────────────────
    after_reset: dict[str, dict[str, dict[str, Any]]] = {}
    reset_record: dict[str, Any] = {}
    for instance in instances:
        entries, errs = reset_then_read(instance)
        contract_failures.extend(errs)
        if errs and not entries:
            continue
        after_reset[instance["id"]] = entries
        before = armed_state.get(instance["id"], {})
        moved = membership_delta(before, entries)
        activity = activity_delta(before, entries)
        reset_record[instance["id"]] = {"membership": moved, "activity": activity,
                                        "count": len(entries)}
        if moved["appeared"] or moved["vanished"]:
            contract_failures.append(
                f"{instance['id']}: reset changed membership — "
                f"{len(moved['appeared'])} appeared, {len(moved['vanished'])} vanished "
                f"(point 4: reset is membership-neutral)")
        if activity["assigned"]:
            contract_failures.append(
                f"{instance['id']}: reset turned on {activity['assigned']} source(s) "
                f"(point 3: reset validates activity, it does not assign it)")

        # The control. It was never armed and never carried a value, so nothing
        # validation could compute makes it active. A runtime reporting it
        # active after the reset assigned activity rather than validating it.
        control = held_back.get(instance["id"])
        if control and control in entries and entries[control]["active"]:
            contract_failures.append(
                f"{instance['id']}: held-back control source {control!r} is active after "
                f"reset, having never been armed or given a value — reset forces test "
                f"sources active (point 3)")
    summary["contractParity"]["reset"] = reset_record
    summary["contractParity"]["declared"]["afterReset"] = {
        name: {"count": len(e), "active": sum(1 for v in e.values() if v["active"])}
        for name, e in after_reset.items()}
    for failure in compare_declared(after_reset):
        contract_failures.append(f"after reset: {failure}")

    # ── trajectory parity ─────────────────────────────────────────────────────
    if args.skip_trajectory:
        summary["trajectoryParity"]["ok"] = None
    else:
        steps = args.steps if args.steps > 0 else max(CL.longest_sequence(instances), 1)
        summary["trajectoryParity"]["steps"] = steps
        record, failures = run_trajectory(instances, steps, args.settle_ms)
        summary["trajectoryParity"]["trajectories"] = record
        summary["trajectoryParity"]["failures"] = failures
        summary["trajectoryParity"]["ok"] = not failures

    # ── TTL validation (#166) ─────────────────────────────────────────────────
    region = {"offset": args.probe_offset, "length": args.probe_length}
    for instance in instances:
        record, failures = run_ttl_validation(instance, region, args.probe_ttl_ms, args.run_id)
        summary["contractParity"]["ttlValidation"][instance["id"]] = record
        contract_failures.extend(failures)

    summary["contractParity"]["failures"] = contract_failures
    summary["contractParity"]["ok"] = not contract_failures

    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")

    for klass in ("availability", "loadParity", "contractParity", "trajectoryParity"):
        record = summary[klass]
        for item in record["failures"]:
            print(f"FAIL {klass}: {item}", file=sys.stderr)
    print()
    for klass in ("availability", "loadParity", "contractParity", "trajectoryParity"):
        state = summary[klass]["ok"]
        mark = {True: "PASS", False: "FAIL", None: "SKIP"}[state]
        print(f"{mark} {klass}")
    print(summary_path)

    failed = [k for k in ("availability", "loadParity", "contractParity", "trajectoryParity")
              if summary[k]["ok"] is False]
    if failed:
        # Said plainly, because a stage that is supposed to fail is a stage
        # someone will otherwise "fix".
        print(f"\nFAIL reset/source contract not met: {', '.join(failed)}. Against today's "
              f"engines this is the expected result — see RealityEngine_CI#163 and #166.",
              file=sys.stderr)
        return 1
    print("\nPASS reset/source contract held on every runtime")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
