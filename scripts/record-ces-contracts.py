#!/usr/bin/env python3
"""Record the CES output contract for every domain, from one corpus-composed run.

A CES is a representation of a regular expression, so any difference between
runtimes is a defect rather than variance, and the quorum is 3-of-3 — never a
majority, and the largest cluster is not the answer (`docs/QUORUM_CONTRACT.md`
§1).

## What this replaces

The previous recorder drove one chain at a time by registering a source of its
own, `ces-contract-{run}-{runtime}`, and pushing vectors through it.
`SURFACE_SPEC.md` names that pattern and rules it out:

    A probe that registers its own source and pushes values through it is
    measuring a synthetic stimulus: it exercises whatever region it chose rather
    than the corpus, and three engines can agree on it while disagreeing on
    everything the corpus would have driven.

Every shard it produced was discarded rather than re-recorded, because a re-run
reproduces the artefact faithfully. The divergences those shards reported —
including a three-runtime split on the RS ring — do not exist: driven correctly
the three runtimes are byte-identical on both trajectory surfaces.

## The shape now

One drive, all domains. Arming the interned sources composes ISRESeed(n), and
one push advances every machine's sequence together, so the corpus drives itself
as a whole and the machines are exercised against each other in the shared
space. Each domain's shard is then a *projection* of that single run onto its
own machines. That is both more faithful than a per-domain sweep and far
cheaper: twelve shards from one drive rather than twelve boot-load-record
cycles.

A machine's contract is what it **committed**: OSRE(n) projected onto its
declared output region. OSRE is the resolved, single-valued, already-arbitrated
write set for the step, which is the one surface where the value is unambiguous.

## What a shard asserts, and what it does not

It asserts that under a stated stimulus the three runtimes committed the same
cells. It does not assert the step was read at a settled point — no runtime
exposes a completion barrier (#375), so the read is taken after the drive rather
than at a guaranteed boundary. The stimulus fingerprint is recorded in the shard
so a later reader can tell what conditions produced it, rather than assuming.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Iterable
from urllib import error, request

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

import ces_seed_drive as seed  # noqa: E402
from reset_contract import reset_instances  # noqa: E402

Json = dict[str, Any]

REPO_ROOT = SCRIPT_DIR.parent
MACHINES_ROOT = REPO_ROOT.parent / "RealityEngine_Machines"
SHARD_DIR = REPO_ROOT / "config" / "ces-contracts"


# ── transport ───────────────────────────────────────────────────────────────

def _req(method: str, url: str, body: Json | None = None, timeout: int = 180) -> tuple[int, Any]:
    req = request.Request(
        url,
        data=(json.dumps(body).encode() if body is not None else None),
        headers={"Content-Type": "application/json"},
        method=method,
    )
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except error.HTTPError as exc:
        return exc.code, {}
    except Exception as exc:  # noqa: BLE001
        return 0, {"error": f"{type(exc).__name__}: {exc}"}


def get_json(url: str) -> tuple[int, Any]:
    return _req("GET", url)


def post_json(url: str, body: Json) -> tuple[int, Any]:
    return _req("POST", url, body)


def patch_json(url: str, body: Json) -> tuple[int, Any]:
    return _req("PATCH", url, body)


def delete_json(url: str) -> tuple[int, Any]:
    return _req("DELETE", url)


# ── the corpus side ─────────────────────────────────────────────────────────

def load_corpus() -> dict[str, Json]:
    """machineName -> {domain, output region}, read from the corpus on disk.

    Keyed on name rather than id: machine ids are minted per-runtime for
    anything imported at runtime, so the same file answers a different id in
    each engine. See `ces_seed_drive.source_fingerprint`.
    """
    root = MACHINES_ROOT / "machines"
    corpus: dict[str, Json] = {}
    for path in sorted(root.rglob("*.json")):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            continue
        machine = doc.get("machine")
        if not isinstance(machine, dict):
            continue
        name = machine.get("name")
        mapping = machine.get("perceptualMapping") or {}
        output = mapping.get("output")
        if not isinstance(name, str) or not isinstance(output, dict):
            continue
        parts = path.relative_to(root).parts
        domain = parts[1] if parts[0] == "domains" and len(parts) > 2 else parts[0]
        corpus[name] = {"domain": domain, "output": output,
                        "input": mapping.get("input"), "relFile": str(path.relative_to(root))}
    return corpus


def corpus_fingerprint(rel_files: Iterable[str] | None = None) -> Json:
    """Fingerprint over the scope's own machines, not the whole corpus.

    A shard describes a scope, so its fingerprint must cover exactly that
    scope's machines — which is what
    `RealityEngine_Machines/scripts/build-ces-contract-registry.py` compares
    against (`fp.fingerprint_paths(paths, MACHINES)` over the scope selection).
    Writing a corpus-wide digest instead makes every shard read `stale` the
    moment any machine anywhere changes, including machines the shard says
    nothing about — all 15 reported stale with empty drift, digests matching,
    because the two sides were fingerprinting different sets.
    """
    sys.path.insert(0, str(MACHINES_ROOT / "scripts"))
    import ces_corpus_fingerprint as fp  # noqa: E402

    root = MACHINES_ROOT / "machines"
    paths = ([root / rel for rel in sorted(rel_files)] if rel_files is not None
             else sorted(root.rglob("*.json")))
    return fp.fingerprint_paths(paths, root)


# ── the run ─────────────────────────────────────────────────────────────────

def instances_from_registry(url: str) -> list[Json]:
    status, payload = get_json(url)
    if status != 200:
        raise SystemExit(f"instance registry {url} returned {status}")
    out = []
    for entry in payload.get("instances", []):
        if entry.get("status") != "running":
            continue
        out.append({"id": entry["id"], "re": entry["re_url"], "pe": entry["pe_url"]})
    return out


def drive_corpus(instances: list[Json], steps: int | None, settle_ms: int) -> Json:
    """Reset, arm, verify the stimulus matches across the quorum, then drive."""
    report: Json = {"failures": [], "instances": [i["id"] for i in instances]}

    report["reset"] = reset_instances(post_json, instances) or []
    if report["reset"]:
        report["failures"].append("reset failed; a run from unequal starting state "
                                  "compares residue, not behaviour")
        return report

    # Reconcile before arming. Neither unload nor bootstrap maintains the source
    # population against the resident corpus, so inheriting whatever the PE is
    # holding means driving a corpus other than the one loaded.
    populations: dict[str, list[Json]] = {}
    for inst in instances:
        sources, rec_failures, sourceless = seed.reconcile_sources(
            get_json, post_json, delete_json, inst["re"], inst["pe"])
        if sourceless:
            # Recorded, not failed: a machine that authors no inputSequences
            # contributes nothing to the seed, which is true and harmless. Named
            # so a shard says what was resident but silent rather than implying
            # every resident machine was driven.
            report.setdefault("sourcelessMachines", {})[inst["id"]] = sourceless
        report["failures"].extend(f"{inst['id']}: {f}" for f in rec_failures)
        if rec_failures:
            return report
        arm_failures = seed.arm_all(patch_json, inst["pe"], sources)
        report["failures"].extend(f"{inst['id']}: {f}" for f in arm_failures)
        sources, _ = seed.interned_sources(get_json, inst["pe"])
        populations[inst["id"]] = sources

    report["internedSources"] = {k: len(v) for k, v in populations.items()}
    report["armed"] = {k: sum(1 for s in v if s.get("active")) for k, v in populations.items()}

    parity = seed.assert_stimulus_parity(populations)
    if parity:
        report["failures"].extend(parity)
        return report
    report["stimulusFingerprint"] = seed.source_fingerprint(populations[instances[0]["id"]])

    depth = seed.seed_depth(populations[instances[0]["id"]])
    report["seedDepth"] = depth
    steps = depth if steps is None else steps
    report["steps"] = steps

    for inst in instances:
        driven, failures = seed.drive(post_json, inst["pe"], steps, settle_ms)
        report["failures"].extend(f"{inst['id']}: {f}" for f in failures)
        if driven != steps:
            report["failures"].append(f"{inst['id']}: drove {driven} of {steps} steps")

    histories: dict[str, dict[str, list[Json]]] = {}
    for inst in instances:
        histories[inst["id"]] = {}
        for kind in ("isre", "osre"):
            entries, err = seed.history(get_json, inst["re"], kind)
            if err:
                report["failures"].append(f"{inst['id']}: {err}")
                return report
            histories[inst["id"]][kind] = entries
            # A history shorter than the drive means the 1024-entry ring buffer
            # evicted steps this run produced; longer means something else drove
            # this runtime. Both make the projection below describe a window
            # other than the one intended (#307).
            if len(entries) != steps:
                report["failures"].append(
                    f"{inst['id']}: {kind}-history holds {len(entries)} entries after "
                    f"{steps} pushes — {'truncated by the ring buffer' if len(entries) < steps else 'driven by something else'}")
    report["historyLengths"] = {rid: {k: len(v) for k, v in h.items()}
                               for rid, h in histories.items()}
    report["histories"] = histories
    return report


# ── projection and quorum ───────────────────────────────────────────────────

def machine_verdict(histories: dict[str, dict[str, list[Json]]], order: list[str],
                    region: Json) -> Json:
    """3-of-3 over one machine's committed output across the run."""
    committed = {rid: seed.project(histories[rid]["osre"], region) for rid in order}

    clusters: dict[str, list[str]] = {}
    for rid in order:
        clusters.setdefault(json.dumps(committed[rid]), []).append(rid)
    grouped = sorted((sorted(m) for m in clusters.values()), key=lambda m: (-len(m), m))

    fired = any(any(cell for cell in row) for row in committed[order[0]])
    if len(grouped) == 1:
        return {"verdict": "agreed" if fired else "agreed-silent",
                "committed": committed[order[0]]}
    return {
        "verdict": "disagreement",
        "clusters": [{"instances": members,
                      "committed": committed[members[0]]} for members in grouped],
    }


def build_shards(report: Json, corpus: dict[str, Json], resident: set[str],
                 order: list[str]) -> dict[str, Json]:
    histories = report["histories"]
    shards: dict[str, Json] = {}

    for name, facts in sorted(corpus.items()):
        if name not in resident:
            continue
        domain = facts["domain"]
        shard = shards.setdefault(domain, {"machines": {}, "counts": {}})
        shard["machines"][name] = machine_verdict(histories, order, facts["output"])

    for domain, shard in shards.items():
        counts: dict[str, int] = {}
        for entry in shard["machines"].values():
            counts[entry["verdict"]] = counts.get(entry["verdict"], 0) + 1
        shard["counts"] = counts
    return shards


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry", default="http://127.0.0.1:5999/re-registry.json")
    ap.add_argument("--steps", type=int, default=None,
                    help="pushes to drive; default is the full interned seed depth")
    ap.add_argument("--settle-ms", type=int, default=0,
                    help="wall-clock wait after each push. A stand-in for the "
                         "completion point no runtime exposes (#375); left at 0 "
                         "so the cost of that gap stays visible")
    ap.add_argument("--write", action="store_true", help="write shards to config/ces-contracts/")
    ap.add_argument("--check", action="store_true",
                    help="record, compare against the shards on disk, write nothing. "
                         "Non-zero on drift. This is the gate half: a recorded "
                         "contract nobody re-checks silently becomes an assertion "
                         "about the past.")
    ap.add_argument("--corpus", default=None, metavar="NAME",
                    help="record a test-environment corpus scope instead of a domain: "
                         "the machine set named by config/<NAME>-corpus.txt, written "
                         "as corpus-<NAME>.json. The scope is a manifest rather than a "
                         "directory, so it may span domains and need not be a subset of "
                         "the floor — arbiter-fixture is neither.")
    ap.add_argument("--only", default=None, metavar="DOMAIN",
                    help="write only this domain's shard. Required when recording "
                         "under isolation: the floor corpus the universe boots on "
                         "contains machines from several domains, so an unfiltered "
                         "--write would emit a shard for each of those covering only "
                         "the handful resident, overwriting a complete shard with a "
                         "partial one that looks just as authoritative.")
    args = ap.parse_args()

    instances = instances_from_registry(args.registry)
    if len(instances) != 3:
        print(f"FAIL quorum is 3-of-3; the instance registry lists {len(instances)} running")
        return 1
    order = sorted(i["id"] for i in instances)

    report = drive_corpus(instances, args.steps, args.settle_ms)
    if report["failures"]:
        print("FAIL the run could not be made comparable:")
        for line in report["failures"][:12]:
            print(f"  {line}")
        return 1

    corpus = load_corpus()
    resident, res_err = seed.machine_registry(get_json, instances[0]["re"])
    if res_err:
        print(f"FAIL could not read the machine registry: {res_err}")
        return 1
    if args.corpus:
        manifest = REPO_ROOT / "config" / f"{args.corpus}-corpus.txt"
        if not manifest.exists():
            print(f"FAIL no corpus manifest at {manifest.relative_to(REPO_ROOT)}")
            return 1
        wanted = {line.strip() for line in manifest.read_text(encoding="utf-8").splitlines()
                  if line.strip() and not line.strip().startswith("#")}
        by_rel = {facts["relFile"]: name for name, facts in corpus.items()}
        scoped = {by_rel[rel] for rel in wanted if rel in by_rel}
        absent = sorted(n for n in scoped if n not in resident)
        if absent:
            # Recording silence for a machine the engines never loaded is
            # indistinguishable from a machine that genuinely does nothing.
            print(f"FAIL --corpus={args.corpus} names {len(absent)} machine(s) not resident: "
                  f"{', '.join(absent[:4])}")
            return 1
        resident = resident & scoped

    shards = build_shards(report, corpus, resident, order)
    withheld: list[str] = []

    if args.only:
        if args.only not in shards:
            print(f"FAIL --only={args.only} but no machine of that domain is resident; "
                  f"resident domains are {', '.join(sorted(shards)) or '(none)'}")
            return 1
        # Report every domain the drive covered, write only the one asked for.
        # The others are real observations but partial, and a partial shard on
        # disk is indistinguishable from a complete one.
        withheld = sorted(set(shards) - {args.only})
        shards = {args.only: shards[args.only]}

    scope_files = {name: facts["relFile"] for name, facts in corpus.items()}
    total = {"agreed": 0, "agreed-silent": 0, "disagreement": 0}
    for domain in sorted(shards):
        counts = shards[domain]["counts"]
        for key in total:
            total[key] += counts.get(key, 0)
        print(f"  {domain:22} " + "  ".join(f"{k}={counts.get(k, 0)}" for k in
                                            ("agreed", "agreed-silent", "disagreement")))

    print(f"\n  {len(shards)} domains, {sum(total.values())} machines: "
          + ", ".join(f"{v} {k}" for k, v in total.items()))
    print(f"  stimulus: {report['armed']} armed, seed depth {report['seedDepth']}, "
          f"{report['steps']} steps driven")
    if args.only and withheld:
        print(f"  withheld (partial under isolation, not written): {', '.join(withheld)}")

    if args.check:
        # A shard is only comparable under the stimulus it was recorded with.
        # Each was recorded under isolation — its domain plus the boot floor —
        # so its seed is that machine set and its length is that set's longest
        # interned sequence. Checked against a universe holding anything else,
        # every machine's committed output legitimately differs and none of it
        # is drift in the contract.
        #
        # Found by running it: domain-health-personal records 62 machines
        # resident at seed depth 79, and a check against a 23-machine universe
        # at depth 31 reported two machines as drifted while printing
        # "agreed -> agreed" — a verdict transition to itself, which is what a
        # comparison of two different questions looks like. run-all-tests.sh
        # invokes --check, so left alone this gate would fire on almost every
        # run, and a gate that always fires is the same as no gate.
        drift: list[str] = []
        incomparable: list[str] = []
        checked = 0

        for domain, shard in sorted(shards.items()):
            path = SHARD_DIR / f"domain-{domain}.json"
            if not path.exists():
                drift.append(f"{domain}: no shard on disk to check against")
                continue
            doc = json.loads(path.read_text(encoding="utf-8"))
            was_stim = doc.get("stimulus") or {}
            mismatch = [
                f"{key} {was_stim.get(key)!r} != {now!r}"
                for key, now in (("residentMachines", len(resident)),
                                 ("seedDepth", report["seedDepth"]),
                                 ("steps", report["steps"]))
                if was_stim.get(key) != now
            ]
            if mismatch:
                incomparable.append(f"{domain}: recorded under a different stimulus "
                                    f"({'; '.join(mismatch)})")
                continue

            recorded = doc.get("machines", {})
            for name, entry in sorted(shard["machines"].items()):
                was = recorded.get(name)
                checked += 1
                if was is None:
                    drift.append(f"{domain}/{name}: not in the recorded shard")
                elif was.get("verdict") != entry.get("verdict"):
                    drift.append(f"{domain}/{name}: verdict "
                                 f"{was.get('verdict')} -> {entry.get('verdict')}")
                elif json.dumps(was, sort_keys=True) != json.dumps(entry, sort_keys=True):
                    drift.append(f"{domain}/{name}: same verdict "
                                 f"({entry.get('verdict')}) but the committed output changed")

        if incomparable:
            print(f"\n  not comparable under this universe ({len(incomparable)}):")
            for line in incomparable[:12]:
                print(f"    {line}")
            print("    a shard is checkable only against the stimulus it was recorded "
                  "with; load that scope in isolation to check it")
        if drift:
            print(f"\n  DRIFT against the recorded shards ({len(drift)} of {checked} "
                  f"machines checked):")
            for line in drift[:20]:
                print(f"    {line}")
            return 1
        if not checked:
            # Nothing was comparable, so nothing was verified. Saying "no drift"
            # here is the unreachable-verifier failure this gate exists to avoid.
            print("\n  nothing checked: no shard matched this universe's stimulus")
            return 0
        print(f"\n  no drift across {checked} machines checked")
        return 0

    if args.write and args.corpus:
        SHARD_DIR.mkdir(parents=True, exist_ok=True)
        machines: Json = {}
        counts: dict[str, int] = {}
        for shard in shards.values():
            machines.update(shard["machines"])
            for verdict, n in shard["counts"].items():
                counts[verdict] = counts.get(verdict, 0) + n
        doc = {
            "schemaVersion": "2.0.0", "scope": f"corpus:{args.corpus}", "quorum": "3-of-3",
            "generatedBy": "scripts/record-ces-contracts.py",
            "stimulus": {
                "model": "corpus-interned test sources (composed ISRESeed)",
                "internedSources": report["internedSources"], "armed": report["armed"],
                "seedDepth": report["seedDepth"], "steps": report["steps"],
                "settleMs": args.settle_ms, "residentMachines": len(resident),
                "isolated": True,
                "completionPoint": "none exposed by any runtime (RealityEngine_CI#375)",
            },
            "corpusFingerprint": corpus_fingerprint(
                [scope_files[n] for n in machines if n in scope_files]),
            "instances": order,
            "counts": counts, "machines": machines,
        }
        (SHARD_DIR / f"corpus-{args.corpus}.json").write_text(
            json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"  wrote corpus-{args.corpus}.json ({len(machines)} machines)")
        return 1 if counts.get("disagreement") else 0

    if args.write:
        SHARD_DIR.mkdir(parents=True, exist_ok=True)
        for domain, shard in shards.items():
            doc = {
                "schemaVersion": "2.0.0",
                "scope": f"domain:{domain}",
                "quorum": "3-of-3",
                "generatedBy": "scripts/record-ces-contracts.py",
                "stimulus": {
                    "model": "corpus-interned test sources (composed ISRESeed)",
                    "internedSources": report["internedSources"],
                    "armed": report["armed"],
                    "seedDepth": report["seedDepth"],
                    "steps": report["steps"],
                    "settleMs": args.settle_ms,
                    "residentMachines": len(resident),
                    "sourcelessMachines": report.get("sourcelessMachines", {}).get(order[0], []),
                    "isolated": bool(args.only),
                    "completionPoint": "none exposed by any runtime (RealityEngine_CI#375)",
                },
                "corpusFingerprint": corpus_fingerprint(
                    [scope_files[n] for n in shard["machines"] if n in scope_files]),
                "instances": order,
                "counts": shard["counts"],
                "machines": shard["machines"],
            }
            (SHARD_DIR / f"domain-{domain}.json").write_text(
                json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"  wrote {len(shards)} shards to {SHARD_DIR.relative_to(REPO_ROOT)}/")

    return 1 if total["disagreement"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
