#!/usr/bin/env python3
"""Drive the corpus with its own composed seed, and read what it committed.

This is the stimulus half of the CES contract recorder, separated out because
getting it wrong is not a detail — it decides whether the recording is about the
engines at all.

**The seed is composed, not supplied.** Ingesting a machine interns its
`inputSequences` as a test source over that machine's own input region. Those
sources are visible in the Manager Perception tab, each carries an `active`
flag, and they are the declared input to the ISRE combination workflow:

    ISRE(1) = ISRESeed(1)
    ISRE(n) = mergeBatch( ISRESeed(n), arbiter(OSRE(n-1)) )

`ISRESeed(n)` is the merge of the n-th vector of every *active* interned source.
So one push advances every machine's sequence together, each writing into its
own region, and the machines are exercised against each other in the shared
space. Arming the interned sources and pushing is the whole stimulus.

**What this replaces, and why.** The previous recorder registered a source of
its own — `ces-contract-{run}-{runtime}` — and pushed values through it.
`SURFACE_SPEC.md` names that exact pattern:

    A probe that registers its own source and pushes values through it is
    measuring a synthetic stimulus: it exercises whatever region it chose rather
    than the corpus, and three engines can agree on it while disagreeing on
    everything the corpus would have driven.

Every shard recorded that way was discarded rather than re-recorded, because the
defect is in the stimulus and a re-run reproduces it faithfully.

**Attribution is by OSRE region, not by mergeBatch.** A machine's contract is
what it *committed*, and OSRE(n) is the resolved single-valued write set for the
step — already arbitrated. Projecting it onto each machine's declared output
region gives that machine's committed contribution, on the one surface where the
value is unambiguous. Two consequences worth stating:

  * `mergeBatch` is deliberately not the contract. It is a private algorithm
    expected to change under training, and its *effect* is already fully
    captured as the gap between `ISRESeed(n)` and `ISRE(n)`. A shard keyed on it
    would churn on every arbiter change while claiming to describe the corpus.
  * It avoids re-introducing the payload problem of RealityEngine_CI#367. Asking
    each push for every machine's results returned 1.6 MB at full corpus and
    killed two runtimes' heaps mid-sweep. The histories carry the same
    information, sparsely, and are read once at the end.

**Open dependency.** Nothing here can establish that a step is fully realized
before it is read. The runtimes join their own futures internally (#254) but
expose no completion point, so `settle_ms` remains a wall-clock guess — the same
one `regression-trajectory-parity.py` makes. See RealityEngine_CI#375.
"""

from __future__ import annotations

import json
import time
from typing import Any, Callable, Iterable

Json = dict[str, Any]


# ── the interned sources ────────────────────────────────────────────────────

def interned_sources(get: Callable[[str], tuple[int, Any]], pe_url: str) -> tuple[list[Json], str | None]:
    """Every interned corpus test source this PE holds."""
    status, payload = get(f"{pe_url}/api/sources")
    if status != 200:
        return [], f"GET /api/sources returned {status}"
    sources = payload.get("sources") if isinstance(payload, dict) else None
    if not isinstance(sources, list):
        return [], "/api/sources payload has no sources array"
    return [s for s in sources if s.get("type") == "test"], None


def source_fingerprint(sources: Iterable[Json]) -> str:
    """Identity of a source population, for comparing one PE against another.

    Keyed on `machineName`, never on the source id or `machineId`. **Machine ids
    are per-runtime for anything imported at runtime**: the same corpus file
    loaded into all three answers `1789424657677-898041159` on cpp,
    `1U4JVKH-29JB9GBEDK9K` on lsp and `1789424657682-51184be4` on scala, each
    runtime minting its own. The interned source id is `test-<machineId>`, so it
    inherits that. Fingerprinting on it reports three disjoint populations for a
    corpus every runtime holds identically — measured here on 110 of 131
    sources, the 21 exceptions being the machines loaded from disk at boot with
    stable ids.

    `machineName` is unique corpus-wide (enforced by the filename-uniqueness
    contract) and identical across runtimes, so it is the stable key.

    Covers what decides the stimulus — which machines have a source, over which
    regions, carrying which vectors, and whether each is armed. Excludes display
    fields (`name`, `sequenceName`, `metadata`), which differ in wording across
    runtimes without changing what is presented.
    """
    rows = sorted(
        (
            str(s.get("machineName")),
            json.dumps(s.get("region"), sort_keys=True),
            json.dumps(s.get("inputs")),
            bool(s.get("active")),
            bool(s.get("loop")),
        )
        for s in sources
    )
    return json.dumps(rows, sort_keys=True)


def assert_stimulus_parity(populations: dict[str, list[Json]]) -> list[str]:
    """The invariant that replaces "assert I am the only writer".

    Competing writers on a region are valid and, for a feedback construct,
    unavoidable: when ISRE(n) is composed by transforming OSRE(n-1), the
    transformation writes the same lanes an active test sequence writes, and
    both writers are legitimate. The RS ring is exactly this — demanding sole
    ownership would declare it unmeasurable precisely because it works.

    What must hold instead is that the *contention set is identical across the
    quorum*. `regression-trajectory-parity.py` states the consequence of it not
    holding: "an active source one PE has and another does not is *stimulus*,
    which this stage would faithfully report as engine divergence."
    """
    prints = {rid: source_fingerprint(srcs) for rid, srcs in populations.items()}
    if len(set(prints.values())) <= 1:
        return []

    counts = {rid: len(srcs) for rid, srcs in populations.items()}
    armed = {rid: sum(1 for s in srcs if s.get("active")) for rid, srcs in populations.items()}
    ids = {rid: {str(s.get("id")) for s in srcs} for rid, srcs in populations.items()}
    shared = set.intersection(*ids.values()) if ids else set()

    failures = [
        "stimulus differs across the quorum, so any comparison downstream would "
        "report the harness as an engine divergence:",
        f"    sources: {counts}",
        f"    armed:   {armed}",
    ]
    for rid, own in sorted(ids.items()):
        extra = sorted(own - shared)
        if extra:
            failures.append(f"    only on {rid}: {', '.join(extra[:6])}"
                            + (f" (+{len(extra) - 6} more)" if len(extra) > 6 else ""))
    return failures


def machine_registry(get: Callable[[str], tuple[int, Any]], re_url: str) -> tuple[set[str], str | None]:
    """Machine names the runtime currently holds, from the machine registry.

    `GET /api/machines` — the machines resident in memory — and deliberately not
    `GET /api/machines/json/list`, which is the on-disk corpus catalog and
    answers a completely different question. Reading the catalog and calling it
    residency reports 21 while the runtime holds 163.
    """
    status, payload = get(f"{re_url}/api/machines")
    if status != 200:
        return set(), f"GET /api/machines returned {status}"
    machines = payload.get("machines") if isinstance(payload, dict) else payload
    if not isinstance(machines, list):
        return set(), "/api/machines payload has no machines array"
    return {str(m.get("name")) for m in machines if m.get("name")}, None


def reconcile_sources(get: Callable[[str], tuple[int, Any]],
                      post: Callable[[str, Json], tuple[int, Any]],
                      delete: Callable[[str], tuple[int, Any]],
                      re_url: str, pe_url: str) -> tuple[list[Json], list[str]]:
    """Make the interned source population equal the resident corpus, exactly.

    Neither direction maintains itself, and the drift is silent both ways:

      * **Unloading a machine does not remove its source.** The machine leaves
        the machine registry and its interned source stays behind, still armed,
        still writing its region on every push. Measured here: 163 machines
        resident against 273 sources, 110 of them orphans from a domain that had
        been unloaded — the whole of `life-balance`, still driving the space it
        no longer belonged to.
      * **Bootstrap only ever adds.** It creates a source for any machine that
        lacks one and prunes nothing, so calling it against a drifted population
        makes it worse. Worse still, machine ids are minted per-runtime on each
        import, so a machine unloaded and reloaded gets a *new* id, and
        `test-<machineId>` keys a second source rather than replacing the first.

    So a recorder that inherits whatever the PE happens to be holding is not
    driving the corpus it thinks it is. Reconciling costs one bootstrap and a
    handful of deletes, and it is what lets the seed be stated rather than
    assumed.
    """
    failures: list[str] = []

    resident, err = machine_registry(get, re_url)
    if err:
        return [], [err]

    status, _ = post(f"{pe_url}/api/sources/bootstrap-from-machines", {})
    if status != 200:
        failures.append(f"POST /api/sources/bootstrap-from-machines returned {status}")

    sources, err = interned_sources(get, pe_url)
    if err:
        return [], failures + [err]

    for src in sources:
        if str(src.get("machineName")) in resident:
            continue
        sid = src.get("id")
        if not sid:
            continue
        status, _ = delete(f"{pe_url}/api/sources/{sid}")
        if status not in (200, 204):
            failures.append(f"DELETE orphaned source {sid} returned {status}")

    sources, err = interned_sources(get, pe_url)
    if err:
        return [], failures + [err]

    names = {str(s.get("machineName")) for s in sources}
    if names != resident:
        missing = sorted(resident - names)
        extra = sorted(names - resident)
        failures.append(
            f"source population still does not match the resident corpus: "
            f"{len(resident)} machines, {len(sources)} sources"
            + (f"; no source for {len(missing)} machine(s) e.g. {missing[:3]}" if missing else "")
            + (f"; {len(extra)} orphan(s) remain e.g. {extra[:3]}" if extra else ""))
    return sources, failures


def arm_all(patch: Callable[[str, Json], tuple[int, Any]], pe_url: str,
            sources: Iterable[Json]) -> list[str]:
    """Arm every interned source, explicitly and in both directions.

    Interning declares a source inactive — activity is earned by being armed for
    a run. Both directions are set rather than only the ones that need changing,
    because the runtimes have historically disagreed about what a reset leaves
    behind, and inheriting that disagreement is how it becomes a finding about
    an engine.
    """
    failures: list[str] = []
    for src in sources:
        sid = src.get("id")
        if not sid:
            continue
        if src.get("active"):
            continue
        status, _ = patch(f"{pe_url}/api/sources/{sid}", {"active": True})
        if status != 200:
            failures.append(f"PATCH /api/sources/{sid} returned {status}")
    return failures


def seed_depth(sources: Iterable[Json]) -> int:
    """Pushes needed for every interned sequence to play through once."""
    longest = 0
    for src in sources:
        inputs = src.get("inputs")
        if isinstance(inputs, list):
            longest = max(longest, len(inputs))
    return longest


# ── driving ─────────────────────────────────────────────────────────────────

def drive(post: Callable[[str, Json], tuple[int, Any]], pe_url: str, steps: int,
          settle_ms: int = 0) -> tuple[int, list[str]]:
    """Push `steps` times, advancing every armed source's cursor together.

    `settle_ms` is a wall-clock stand-in for the completion point the runtimes
    do not expose (#375). It is not an approximation of a barrier — it is a
    guess that is silently wrong under load, and when it is wrong the caller
    reads a half-written step. Kept at 0 by default so the cost of not having
    the barrier stays visible rather than being tuned away.
    """
    failures: list[str] = []
    driven = 0
    for index in range(steps):
        status, _ = post(f"{pe_url}/api/push", {"compact": True,
                                                "includePerceptualSpace": False,
                                                "includeActiveRegions": False})
        if status != 200:
            failures.append(f"push {index} returned {status}")
            break
        driven += 1
        if settle_ms:
            time.sleep(settle_ms / 1000.0)
    return driven, failures


# ── reading what was committed ──────────────────────────────────────────────

def history(get: Callable[[str], tuple[int, Any]], re_url: str, kind: str) -> tuple[list[Json], str | None]:
    """ISRE or OSRE history. Entries carry `length` and `nonZero` at top level."""
    status, payload = get(f"{re_url}/api/engine/{kind}-history")
    if status != 200:
        return [], f"GET /api/engine/{kind}-history returned {status}"
    entries = payload.get("history") if isinstance(payload, dict) else payload
    if not isinstance(entries, list):
        return [], f"{kind}-history payload has no history array"
    return entries, None


def dense(entry: Json, offset: int, length: int) -> list[float]:
    """The `[offset, offset+length)` slice of a sparse history entry.

    Ranges are half-open here because that is what `{offset, length}` means on
    the wire. Rendered in prose they are closed — `[16920:16921]` is the
    two-cell region — per SURFACE_SPEC "Lane range notation".
    """
    cells = [0.0] * length
    for cell in entry.get("nonZero") or []:
        index = cell.get("index")
        if isinstance(index, int) and offset <= index < offset + length:
            cells[index - offset] = cell.get("value")
    return cells


def project(entries: list[Json], region: Json) -> list[list[float]]:
    """A machine's committed output across the drive, one row per step."""
    offset = region.get("offset")
    length = region.get("length")
    if not isinstance(offset, int) or not isinstance(length, int):
        return []
    return [dense(entry, offset, length) for entry in entries]
