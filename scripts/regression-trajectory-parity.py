#!/usr/bin/env python3
"""Cross-engine trajectory parity: do the engines evolve identically?

The claim the multi-engine deployment rests on is that from a `--fresh`
deployment, every engine given the same corpus evolves the same way.
Nothing proved it. `regression-universal-vectors.py` compares single-step
responses and re-synchronises the engines between events — it registers a
source, pushes, deletes the source, repeats. Two engines can agree at every
step examined in isolation and still be on different trajectories, and a loop
that diverges the moment it is left alone passes that stage (RealityEngine_CI#148).

The seed is **composed, not supplied**. Ingesting a machine interns its
`inputSequences` as a test source over that machine's own input region, so
arming every interned source and pushing applies the merged set: one push
advances every machine's sequence a step at once, each writing into its own
region. That is ISRESeed(n) — the stimulus the application actually runs on,
and a harder test than a synthetic seed because it exercises the machines
against each other in the shared space.

An earlier revision registered its own sensor over a region it chose and wrote
values through it. That measured a synthetic stimulus: it exercised one region
rather than the corpus, three engines could agree on it while disagreeing on
everything the corpus would have driven, and it reported a divergence at a cell
no loaded machine owned — not a finding about the engines at all.

This stage arms the interned sources once and lets each engine run its own
closed loop, then compares the two histories the engines record at their own
observation points:

    ISRE-History = {ISRE(1) … ISRE(n)}   what each corpus was presented with
    OSRE-History = {OSRE(1) … OSRE(n-1)} what each corpus produced

Both are read from `GET {re}/api/{isre,osre}-history`, which every runtime
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
  space Reality Event. It is the Reality Event that must be equivalent; region
  equivalence follows from it.
* **No sorting, no identity filtering.** These histories carry Reality Events,
  not names — there is no engine-minted id to strip and no ordering to normalise.
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

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from reset_contract import reset_instances  # noqa: E402

TRAJECTORIES = ("isre", "osre")


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


def patch_json(url: str, payload: Any, timeout: int = 20) -> tuple[int, Any]:
    req = request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="PATCH",
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



def interned_test_sources(instance: dict[str, Any]) -> tuple[list[dict[str, Any]], str | None]:
    """The corpus test sources this engine interned when it ingested its machines."""
    status, payload = get_json(f"{instance['pe']}/api/sources")
    if status != 200:
        return [], f"{instance['id']}: GET /api/sources returned {status}"
    sources = payload.get("sources")
    if not isinstance(sources, list):
        return [], f"{instance['id']}: /api/sources payload has no sources array"
    return [s for s in sources if s.get("type") == "test"], None


def arm_interned_sources(instance: dict[str, Any]) -> tuple[int, list[str]]:
    """Activate every interned test source. Returns (count, failures).

    Interning declares a source inactive — activity is earned, and a test source
    earns it by being armed for a run. Arming is stated explicitly rather than
    inherited, because the runtimes have historically disagreed about what a
    reset leaves behind and an active source one PE has and another does not is
    *stimulus*, which this stage would faithfully report as engine divergence.
    """
    sources, err = interned_test_sources(instance)
    if err:
        return 0, [err]
    failures: list[str] = []
    for src in sources:
        sid = src.get("id")
        if not sid or src.get("active"):
            continue
        status, _ = patch_json(f"{instance['pe']}/api/sources/{sid}", {"active": True})
        if status != 200:
            failures.append(f"{instance['id']}: PATCH /api/sources/{sid} returned {status}")
    return len(sources), failures


def longest_interned_sequence(instance: dict[str, Any]) -> int:
    sources, _ = interned_test_sources(instance)
    longest = 0
    for src in sources:
        inputs = src.get("inputs")
        if isinstance(inputs, list):
            longest = max(longest, len(inputs))
    return longest


def run_seed_sequence(instance: dict[str, Any], steps: int, settle_ms: int) -> list[str]:
    """Drive one engine with the corpus's own stimulus, letting its loop run.

    The seed is **composed, not supplied**. Ingesting a machine interns its
    `inputSequences` as a test source over that machine's own input region, so
    arming every interned source and pushing applies the merged set: one push
    advances every machine's sequence a step at once, each writing into its own
    region. That is ISRESeed(n), and it is the stimulus the application actually
    runs on (SURFACE_SPEC.md, "Machine ingestion" and "Trajectory histories").

    An earlier revision of this function registered its own sensor source over a
    region it chose and wrote values through it. That measured a synthetic
    stimulus: it exercised one region rather than the corpus, and three engines
    can agree on it while disagreeing on everything the corpus would have
    driven. It also meant the gate reported a divergence at a cell no loaded
    machine owned, which is not a finding about the engines at all.

    No source is created and none is deleted. The set under test is the one
    ingestion produced, which is the set the engines run with.
    """
    failures: list[str] = []
    pe = instance["pe"]

    count, arm_failures = arm_interned_sources(instance)
    failures.extend(arm_failures)
    if count == 0:
        return failures + [
            f"{instance['id']}: no interned test sources — nothing to be presented with. "
            f"The corpus test sources are interned at ingestion unless "
            f"PE_SOURCE_BOOTSTRAP=off; check the engine booted with a corpus."
        ]

    for index in range(steps):
        status, _ = post_json(f"{pe}/api/push", {"compact": True})
        if status != 200:
            failures.append(f"{instance['id']}: push {index} failed (status {status})")
            break
        if settle_ms:
            time.sleep(settle_ms / 1000.0)
    return failures


# The arbiter rules every runtime implements. Kept here rather than derived from
# a runtime, because the point of the sweep is to catch a runtime that is
# missing one: asking the engines what they support would let a gap define
# itself away. C++ src/arbiter.cpp resolve_cell, Scala engine/Arbiter.scala,
# LSP src/arbiter.lisp all switch on exactly these.
ARBITER_RULES = ("PRECEDENCE", "OR", "MAX", "AND", "MIN", "SEVERITY", "MEAN")


def fetch_arbiter_config(instance: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
    """The arbitration configuration a runtime actually booted with.

    Comparing trajectories only means something if the three runtimes resolved
    contention under the same rules. Nothing asserted that. Every engine
    resolves `ARBITRATION_REGISTRY`, then a path relative to its own machines
    directory, and falls back with a stderr line and an empty registry:

        [arbiter] no arbitration registry found; contended cells fall back to
        PRECEDENCE

    A runtime that took that fallback while its peers loaded 2837 entries is
    running a different arbiter, and the histories it produces are not
    comparable. Whether that shows up as a divergence or as an accidental pass
    is luck. Read it and assert it instead.
    """
    status, payload = get_json(f"{instance['re']}/api/arbitration")
    if status != 200 or not isinstance(payload, dict):
        return {}, f"{instance['id']}: GET /api/arbitration -> {status}"
    return {
        "registryEntries": payload.get("registryEntries"),
        "registrySource": payload.get("registrySource"),
        "shards": payload.get("shards"),
    }, None


def arbiter_config_failures(configs: dict[str, dict[str, Any]]) -> list[str]:
    """Every runtime must have loaded the same number of contended cells.

    Entry count is the strongest fingerprint available: no engine exposes a
    digest of the registry it parsed, so identical content cannot be proven from
    outside. It is enough to catch the failure that matters — a runtime that
    found no registry, or a different one — because that shows up as a different
    count rather than a subtly different rule.

    `registrySource` is recorded but deliberately not compared: each engine
    resolves the path relative to its own repository, so three different strings
    can name one file. Comparing them would fail correct runs.

    `shards` is recorded and not compared either, and that is a real assertion
    rather than a gap. ARBITER_SHARDS tunes throughput and correctness does not
    depend on it — every runtime says so in its own comments. Three runtimes
    agreeing under different shard counts is therefore a *stronger* result than
    three agreeing under the same one, so the value is reported to make it
    visible which was demonstrated.
    """
    failures: list[str] = []
    counts = {name: cfg.get("registryEntries") for name, cfg in configs.items()}
    if len(set(counts.values())) > 1:
        shape = " | ".join(f"{name}={count}" for name, count in sorted(counts.items()))
        failures.append(
            f"arbitration registry differs across runtimes ({shape}) — trajectories "
            f"resolved under different arbiters are not comparable")
    if any(count in (0, None) for count in counts.values()):
        empty = sorted(name for name, count in counts.items() if count in (0, None))
        failures.append(
            f"arbitration registry empty on {'+'.join(empty)} — contended cells fall "
            f"back to PRECEDENCE, so no declared rule is under test")
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
    parser.add_argument("--steps", type=int, default=0,
                        help="push count; 0 (default) walks the longest interned sequence")
    parser.add_argument("--settle-ms", type=int, default=250)
    parser.add_argument("--arbiter-rule", default=None,
                        help="label recorded in the summary when the harness has "
                             "forced a rule via ARBITRATION_REGISTRY; reporting only, "
                             "the engines are configured before they boot")
    # On by default. This stage compared ISRE/OSRE histories without resetting
    # anything, so it inherited whatever the preceding stage left — and
    # regression-test.sh runs pe-step-contract immediately before it, which
    # pushes through every PE. Two runs of the same suite could differ by what
    # ran before them, and the difference reads as engine divergence (#211).
    parser.add_argument("--no-reset", dest="reset", action="store_false",
                        help="Do not reset the engines first; compare accumulated state deliberately.")
    parser.set_defaults(reset=True)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    instances = load_instances(args.registry)
    if len(instances) < 2:
        print(f"FAIL trajectory parity needs at least two runtimes, found {len(instances)}", file=sys.stderr)
        return 1

    # Step count comes from the corpus, not from a flag: walk the longest
    # interned sequence right through, so a machine with a longer sequence is
    # not truncated mid-pattern. Taken as a max across runtimes rather than from
    # one, so a runtime that interned fewer vectors than its peers shows up as
    # divergence instead of going unexercised. --steps overrides for a short
    # smoke run.
    corpus_steps = max((longest_interned_sequence(i) for i in instances), default=0)
    steps = args.steps if args.steps else corpus_steps

    interned = {i["id"]: len(interned_test_sources(i)[0]) for i in instances}

    failures: list[str] = []

    # Before any trajectory is compared: the runtimes must be resolving
    # contention under the same rules. This is asserted rather than assumed
    # because nothing in the harness ever set ARBITRATION_REGISTRY — every
    # engine found its own copy by relative path, and a runtime that found none
    # would have been compared anyway.
    arbiter_configs: dict[str, dict[str, Any]] = {}
    for instance in instances:
        config, err = fetch_arbiter_config(instance)
        if err:
            failures.append(err)
            continue
        arbiter_configs[instance["id"]] = config
    if len(arbiter_configs) == len(instances):
        failures.extend(arbiter_config_failures(arbiter_configs))
    if steps == 0:
        failures.append(
            "no interned test sequences on any runtime — the corpus test sources are "
            "interned at ingestion unless PE_SOURCE_BOOTSTRAP=off; check the engines "
            "booted with a corpus")
    # A defined starting point, before any stimulus is applied. Both halves:
    # CES activation and the histories live in the RE, while globalStep, the
    # persistent vector and the test cursors live in the PE, and resetting
    # either alone leaves the other holding earlier traffic (#211).
    #
    # Before arming, not after: reset *validates* activity rather than assigning
    # it (#163), so arming first and resetting second would discard the arming
    # this stage depends on.
    reset_failures: list[str] = []
    if args.reset:
        reset_failures = reset_instances(post_json, instances)
        # Recorded as failures, not fatal: refusing to run would make a reset
        # regression read as a parity regression, and the comparison below is
        # still informative as long as the reader knows the start was undefined.
        failures.extend(
            f"{item} — trajectories below were measured against unknown prior state"
            for item in reset_failures
        )

    for instance in instances:
        failures.extend(run_seed_sequence(instance, steps, args.settle_ms))

    summary: dict[str, Any] = {
        "runId": args.run_id,
        "instances": [i["id"] for i in instances],
        "seedSteps": steps,
        "seedSource": "corpus-interned test sources (composed ISRESeed)",
        "internedTestSources": interned,
        "reset": {
            "requested": args.reset,
            "scope": "re+pe" if args.reset else "disabled",
            "failures": reset_failures,
        },
        "arbiterRule": args.arbiter_rule or "corpus-declared",
        "arbiterConfig": arbiter_configs,
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
    rule = args.arbiter_rule or "corpus-declared"
    cells = next(iter(arbiter_configs.values()), {}).get("registryEntries", 0)
    print(f"PASS trajectory parity: ISRE/OSRE histories identical across "
          f"{len(instances)} runtimes ({min(lengths.values())} steps, "
          f"arbiter {rule} over {cells} contended cells)")
    print(args.out / "trajectory-summary.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
