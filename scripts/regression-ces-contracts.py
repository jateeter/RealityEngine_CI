#!/usr/bin/env python3
"""Record the CES output-stream contract from 3-of-3 runtime agreement.

This replaces the replay-engine recording in `scripts/cesgen-contracts.mjs`.

**Why it exists.** That tool produced the expected stream by replaying the
corpus through a single nominated engine, and the artifact then became the
authority every other runtime was judged against. Three consequences followed,
and none of them is fixable by regenerating more carefully:

- Regenerating made the nominated engine pass **by construction**. It could not
  fail afterwards except by diverging from itself.
- The gate could therefore never find a defect *in* that engine. If it was
  wrong, the wrongness became the contract and the other runtimes were
  "corrected" toward it.
- To regenerate you had to already trust the thing the gate exists to check.

The nominated engine was a compiled build of the deprecated TypeScript
prototype, which is out of the focus set and is not coming back. So the oracle
is not being rebuilt — it is being **removed**, and replaced by the agreement
of the three runtimes that actually ship (RealityEngine_CI#327, direction (2);
`docs/QUORUM_CONTRACT.md`).

**What a contract entry means here.** A recorded stream is one the C++, LSP and
Scala runtimes all produced, byte-identical after identity filtering. Nothing
else is recorded as a contract. Where they disagree, that disagreement *is* the
finding and is written out in full — it is not resolved, not majority-voted,
and not silently dropped (§1, §5).

This does not make the artifact an oracle in the strong sense. Three runtimes
agreeing can still be three runtimes wrong the same way; only deriving the
expected stream from the corpus and the declared fold rule would be that, and
that is option (3) on #327, not this. What it does retire is the *privileged
participant* — no engine is unfalsifiable any more, and a defect in one is now
visible rather than definitional.

Usage:
  scripts/regression-ces-contracts.py --record    # write config/ces-contracts.json
  scripts/regression-ces-contracts.py --check     # exit 1 if the file would change

Requires a live registry with all three native runtimes. It refuses to record
without a formed quorum: a contract recorded from two runtimes is a contract
with an unexamined third (§2).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any
from urllib import error, request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from parity_identity import strip_engine_identity  # noqa: E402
from reset_contract import reset_pair  # noqa: E402

MAX_CHAIN_DEPTH = 4  # same cap as cesgen-oracles and the tool this replaces
NATIVE_QUORUM = ("cpp", "lsp", "scala")
CONTRACT_VERSION = "2.0.0"


# ── HTTP ────────────────────────────────────────────────────────────────────

def request_json(req: request.Request, timeout: int) -> tuple[int, Any]:
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            try:
                return resp.status, json.loads(raw) if raw else None
            except json.JSONDecodeError:
                return resp.status, {"raw": raw}
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return exc.code, {"raw": raw}


def post_json(url: str, payload: Any, timeout: int = 30) -> tuple[int, Any]:
    req = request.Request(
        url, data=json.dumps(payload).encode("utf-8"), method="POST",
        headers={"content-type": "application/json", "accept": "application/json"})
    return request_json(req, timeout)


def delete_json(url: str, timeout: int = 10) -> tuple[int, Any]:
    return request_json(request.Request(url, method="DELETE",
                                        headers={"accept": "application/json"}), timeout)


# ── Registry ────────────────────────────────────────────────────────────────

def load_instances(registry: Path) -> list[dict[str, str]]:
    try:
        data = json.loads(registry.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"could not read registry {registry}: {exc}") from exc
    out = []
    for item in data.get("instances", []):
        runtime, pe_url = item.get("runtime"), item.get("pe_url")
        if runtime and pe_url and item.get("status", "running") == "running":
            out.append({
                "id": item.get("id", runtime),
                "runtime": runtime,
                "pe_url": pe_url.rstrip("/"),
                "re_url": (item.get("re_url") or "").rstrip("/"),
            })
    if not out:
        raise SystemExit(f"no running PE instances found in {registry}")
    return out


def quorum_composition(instances: list[dict[str, str]]) -> dict[str, Any]:
    """Which native runtimes are present, and whether a quorum can be formed.

    Recording is refused without all three. Unlike the comparison stages — where
    a two-runtime agreement is still a true observation worth reporting — an
    artifact written from two runtimes would be *consumed* later as the
    contract, carrying no trace that the third never answered.
    """
    present = {i["runtime"] for i in instances}
    missing = [r for r in NATIVE_QUORUM if r not in present]
    return {"rule": "3-of-3", "required": list(NATIVE_QUORUM),
            "present": sorted(present), "missing": missing, "formed": not missing}


# ── Chain enumeration (corpus-only; no engine involved) ─────────────────────

def corpus_files(roots: list[Path]) -> dict[str, Path]:
    """Basename → path across every corpus root. Filenames are globally unique.

    More than one root because the regression corpus is not all in one repo.
    Three of its twenty entries — `rag_corrective_cycle`, `session_rag_context`
    and `session_agent_context` — live in `localAIStack/data/machines/`, and a
    walk of `RealityEngine_Machines` alone resolves seventeen of twenty and
    says nothing about the rest. Those three are the machines the RAG lane was
    added to cover, so losing them silently loses exactly the coverage the
    selection exists for.
    """
    out: dict[str, Path] = {}
    for root in roots:
        if not root.is_dir():
            continue
        for f in sorted(root.rglob("*.json")):
            out.setdefault(f.name, f)
    return out


def corpus_selection(name: str, ci_dir: Path) -> list[str] | None:
    """Basenames named by a corpus list, or None for the whole corpus.

    The lists are the same `config/*-corpus.txt` files `startUniverse.sh`
    boots from, read rather than restated — one definition of what a corpus
    selection means. Entries are repo-relative paths; only the basename
    matters here, since corpus filenames are globally unique.
    """
    if name == "full":
        return None
    path = ci_dir / "config" / f"{name}-corpus.txt"
    if not path.exists():
        raise SystemExit(
            f"unknown corpus '{name}': no {path}. "
            f"Available: full, " + ", ".join(
                sorted(f.stem[:-7] for f in (ci_dir / "config").glob("*-corpus.txt"))))
    names = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.append(line.split("/")[-1])
    return names


def enumerate_chains(name: str, path: Path) -> list[dict[str, Any]]:
    """Every input chain reachable from an initial event, capped at MAX_CHAIN_DEPTH.

    Ported unchanged in behaviour from `cesgen-contracts.mjs`. It reads only the
    machine JSON, so it is the one part of the old tool that was never entangled
    with the nominated engine and needs no replacement — only a new home.
    """
    raw = json.loads(path.read_text(encoding="utf-8"))
    machine = raw.get("machine", raw)
    mapping = machine.get("perceptualMapping") or {}
    if not mapping.get("input") or not mapping.get("output"):
        return []
    in_region = {"offset": mapping["input"]["offset"], "length": mapping["input"]["length"]}

    chains: list[dict[str, Any]] = []
    for seq in machine.get("sequences") or []:
        events = seq.get("events") or []
        by_id = {e["id"]: e for e in events if "id" in e}

        def walk(trail: list[dict[str, Any]]) -> None:
            tail = trail[-1]
            if tail.get("outputEvents"):
                chains.append({
                    "id": f"{name}::{seq.get('id')}::{tail['id']}",
                    "machineFile": name,
                    "machineName": machine.get("name"),
                    # Resolved the same way `regression-universal-vectors.py`
                    # resolves it — the corpus id if the machine declares one,
                    # else the file stem. Not an engine-minted id: those differ
                    # per runtime for the same logical machine, so using one
                    # would make the three registrations non-comparable.
                    "machineId": machine.get("id") or machine.get("machineId") or name[:-5],
                    # Every sequence id this machine owns. The push advances the
                    # whole resident corpus, so the response carries every
                    # machine that fired; these are what say which entries are
                    # *this* machine's. See project_step.
                    "ownSequenceIds": sorted(
                        {s.get("id") for s in (machine.get("sequences") or []) if s.get("id")}
                    ),
                    "sequenceId": seq.get("id"),
                    "terminalEventId": tail["id"],
                    "inputRegion": in_region,
                    "inputs": [[el.get("value") for el in (e.get("elements") or [])] for e in trail],
                })
            if len(trail) >= MAX_CHAIN_DEPTH:
                return
            seen = {e["id"] for e in trail}
            for nid in tail.get("nextEventIds") or []:
                nxt = by_id.get(nid)
                if nxt and nxt["id"] not in seen:
                    walk([*trail, nxt])

        for e in events:
            if e.get("isInitial"):
                walk([e])
    return chains


# ── Recording one chain at one runtime ──────────────────────────────────────

def project_step(step: Any, own_sequence_ids: list[str]) -> dict[str, Any]:
    """The comparable content of one step, restricted to the machine under test.

    Two things happen here, and the second is the one that makes a live-derived
    contract mean the same thing as the replay-derived one it replaces.

    **Isolation.** The tool this replaces ran each chain in a fresh simulator
    holding exactly one machine, so its recorded stream was that machine's by
    construction. A live universe has the whole corpus resident and one push
    advances all of it: measured on DLX001, step 0 came back with **438**
    mergeBatch entries, none of them in that machine's declared output region.
    Recording that would make the "contract" a whole-universe snapshot taken
    4941 times, and would report every difference in corpus-wide iteration
    order as a disagreement about a machine that never moved.

    Entries are therefore kept only when they carry one of this machine's own
    sequence ids. Attribution is by sequence rather than by region because a
    region can be shared and a sequence id cannot.

    **Governance is dropped**, as it was in the replaced tool: it is derived
    from the machine's JSON metadata rather than produced by the engine, its
    parity is already covered by `cesgen_governance`, and it is the bulk of the
    payload. Keeping it would have this stage re-assert a corpus fact as though
    it were engine behaviour.

    Engine-minted ids go through `strip_engine_identity` rather than a local
    list, so this stage and the parity stages cannot disagree about what
    identity means (`scripts/CLAUDE.md`, "what a comparison may compare").
    """
    if not isinstance(step, dict):
        return {"mergeBatch": [], "eventBus": []}
    own = set(own_sequence_ids)

    def mine(entry: Any) -> bool:
        if not isinstance(entry, dict) or not own:
            return False
        ids = entry.get("sequenceIds")
        if isinstance(ids, list):
            return any(i in own for i in ids)
        for key in ("sequenceId", "producerSequenceId"):
            if entry.get(key) in own:
                return True
        return False

    def clean(entries: Any) -> Any:
        kept = [e for e in (entries or []) if mine(e)]
        return strip_engine_identity(kept, extra_keys=frozenset({"governance"}))

    return {
        "mergeBatch": clean(step.get("mergeBatch")),
        "eventBus": clean(step.get("eventBus")),
    }


def run_chain(instance: dict[str, str], chain: dict[str, Any], run_id: str) -> dict[str, Any]:
    """Drive one chain at one runtime, one step at a time.

    Returns `{"stream": [...]}` or `{"error": "..."}`. An error is never
    flattened into an empty stream: "this runtime could not be driven" and "this
    runtime emitted nothing" are different facts, and collapsing them is how a
    broken lane reads as unanimous silence (§2, §3).
    """
    pe_url = instance["pe_url"]
    source_id = f"ces-contract-{run_id}-{instance['runtime']}"
    region = chain["inputRegion"]
    source = {
        "id": source_id,
        "type": "test",
        "name": f"CES contract {chain['id']}",
        "active": True,
        # Required by the Scala PE, which decodes SourceConfig with machineId
        # as a mandatory field; cpp and lsp default it and accept its absence.
        # Omitting it answered 400 on scala alone and every chain classified
        # `unmeasurable` — correctly, but the harness was the divergent party.
        "machineId": chain["machineId"],
        "machineName": chain.get("machineName"),
        "sequenceName": chain.get("sequenceId"),
        "region": region,
        "inputs": chain["inputs"],
        "loop": False,
    }
    try:
        status, payload = post_json(f"{pe_url}/api/sources", source)
        if not 200 <= status < 300:
            return {"error": f"source register HTTP {status}", "detail": payload}
        stream = []
        for idx in range(len(chain["inputs"])):
            status, payload = post_json(f"{pe_url}/api/push", {"compact": True})
            if not 200 <= status < 300:
                return {"error": f"push step {idx} HTTP {status}", "detail": payload}
            step = payload.get("step") if isinstance(payload, dict) else None
            stream.append({"step": idx, **project_step(step, chain["ownSequenceIds"])})
        return {"stream": stream}
    except Exception as exc:  # noqa: BLE001
        return {"error": f"raised {exc!r}"}
    finally:
        try:
            delete_json(f"{pe_url}/api/sources/{source_id}")
        except Exception:  # noqa: BLE001
            pass


# ── Quorum over the recorded streams ────────────────────────────────────────

def agreement_clusters(streams: dict[str, Any], order: list[str]) -> list[list[str]]:
    """Group runtimes by identical stream, largest cluster first.

    Largest-first is presentation order and carries no authority. Quorum is
    3-of-3: more than one cluster is a disagreement, and the biggest cluster is
    not the answer (`docs/QUORUM_CONTRACT.md` §1). Do not add a reference member
    here or in the caller.
    """
    clusters: dict[str, list[str]] = {}
    for key in order:
        clusters.setdefault(json.dumps(streams.get(key), sort_keys=True), []).append(key)
    return sorted((sorted(m) for m in clusters.values()), key=lambda m: (-len(m), m))


def is_silent(result: Any) -> bool:
    """True when the runtime ran and emitted no output at any step.

    An errored result is not silence — it is a runtime that could not be
    driven, and it is never counted toward a unanimous-silence finding.
    """
    if not isinstance(result, dict) or "stream" not in result:
        return False
    return all(not s["mergeBatch"] and not s["eventBus"] for s in result["stream"])


def classify(chain: dict[str, Any], results: dict[str, Any], order: list[str]) -> dict[str, Any]:
    """One chain's verdict, in the vocabulary the contract records."""
    errored = sorted(k for k in order if "error" in (results.get(k) or {}))
    if errored:
        # Not a disagreement and not a contract. A lane that could not be
        # driven has produced no evidence either way, and saying so is the
        # honest result (§2: absence is a finding, never agreement).
        return {
            "verdict": "unmeasurable",
            "chain": chain["id"],
            "machineFile": chain["machineFile"],
            "undrivenRuntimes": errored,
            "errors": {k: results[k]["error"] for k in errored},
        }

    clusters = agreement_clusters(results, order)
    if len(clusters) == 1:
        if is_silent(results[order[0]]):
            # Unanimous, and what it says is "no runtime emits output for this
            # chain" — a gap in the contract rather than in any engine (§3).
            # Enumerated as its own verdict, never folded into the contract as
            # an empty stream that reads like a recorded behaviour.
            return {
                "verdict": "no-runtime-emits",
                "chain": chain["id"],
                "machineFile": chain["machineFile"],
                "sequenceId": chain["sequenceId"],
                "terminalEventId": chain["terminalEventId"],
                "steps": len(chain["inputs"]),
            }
        return {
            "verdict": "agreed",
            "chain": chain["id"],
            "machineFile": chain["machineFile"],
            "machineName": chain.get("machineName"),
            "sequenceId": chain["sequenceId"],
            "terminalEventId": chain["terminalEventId"],
            "inputRegion": chain["inputRegion"],
            "inputs": chain["inputs"],
            "quorum": "3-of-3",
            "agreedBy": clusters[0],
            "outputStream": results[order[0]]["stream"],
        }

    # More than one cluster. Every party's emission is carried, because a reader
    # needs all of them to act — not one measured against another (§5).
    return {
        "verdict": "disagreement",
        "chain": chain["id"],
        "machineFile": chain["machineFile"],
        "sequenceId": chain["sequenceId"],
        "terminalEventId": chain["terminalEventId"],
        "quorum": "3-of-3",
        "clusters": [
            {"instances": members, "outputStream": results[members[0]]["stream"]}
            for members in clusters
        ],
    }


# ── Main ────────────────────────────────────────────────────────────────────

def build_payload(verdicts: list[dict[str, Any]], quorum: dict[str, Any],
                  instances: list[dict[str, str]], machine_count: int,
                  machine_corpus: str = "regression") -> dict[str, Any]:
    by = lambda v: [x for x in verdicts if x["verdict"] == v]  # noqa: E731
    agreed, disagreed = by("agreed"), by("disagreement")
    silent, unmeasurable = by("no-runtime-emits"), by("unmeasurable")
    return {
        "version": CONTRACT_VERSION,
        "generatedBy": "scripts/regression-ces-contracts.py",
        "derivedFrom": "3-of-3 agreement across the cpp, lsp and scala runtimes",
        "contract": "docs/QUORUM_CONTRACT.md",
        "quorum": quorum,
        # Which selection this was recorded from. A contract that does not say
        # what it covers cannot be told from one that covers everything.
        "machineCorpus": machine_corpus,
        "runtimes": sorted({i["runtime"] for i in instances}),
        "machineCount": machine_count,
        "counts": {
            "agreed": len(agreed),
            "disagreement": len(disagreed),
            "noRuntimeEmits": len(silent),
            "unmeasurable": len(unmeasurable),
        },
        # Enumerated, never counted. An unimplemented shape and one nothing
        # happened to exercise look identical once they are a number (§3).
        "contracts": sorted(agreed, key=lambda c: c["chain"]),
        "disagreements": sorted(disagreed, key=lambda c: c["chain"]),
        "noRuntimeEmits": sorted(silent, key=lambda c: c["chain"]),
        "unmeasurable": sorted(unmeasurable, key=lambda c: c["chain"]),
    }


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--registry", type=Path, default=Path("/tmp/re-registry/re-registry.json"))
    p.add_argument("--machines", type=Path, action="append", dest="machines",
                   help="Corpus root. Repeatable. Defaults to the Machines corpus "
                        "plus localAIStack's, which between them hold the regression selection.")
    # Defaults to `regression`, not `full`. The contract is an authoritative
    # git file reviewed as a diff (QUORUM_CONTRACT §4), and the full corpus
    # yields 4941 chains against the regression selection's 35 — ~8.2h against
    # ~4min to record, and a diff nobody can read. Divergence is a property of
    # machine *shape*, and the corpus is largely template-generated families,
    # so instance count buys repetition rather than coverage. `--machine-corpus
    # full` remains available for a deliberate sweep.
    p.add_argument("--machine-corpus", default="regression",
                   help="Corpus selection: regression (default), standard-deployment, "
                        "arbiter-fixture, standard-deployment-plus-ring, or full.")
    p.add_argument("--out", type=Path, default=Path("config/ces-contracts.json"),
                   help="Authoritative artifact. A git file by QUORUM_CONTRACT §4.")
    p.add_argument("--machine-names", help="Comma-separated basenames (without .json) to restrict to.")
    p.add_argument("--run-id", default=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--record", action="store_true", help="Write the artifact.")
    mode.add_argument("--check", action="store_true", help="Exit 1 if the artifact would change.")
    args = p.parse_args()

    instances = load_instances(args.registry)
    quorum = quorum_composition(instances)
    if not quorum["formed"]:
        # Refused rather than recorded-with-a-caveat. A caveat in a file is read
        # by whoever opens the file; a missing runtime is read by nobody (§2).
        print(f"quorum not formed: 3-of-3 requires {'+'.join(NATIVE_QUORUM)}, "
              f"missing {'+'.join(quorum['missing'])}", file=sys.stderr)
        print("refusing to derive a contract from an incomplete quorum", file=sys.stderr)
        return 2

    ci_dir = Path(__file__).resolve().parent.parent
    roots = args.machines or [ci_dir / ".." / "RealityEngine_Machines" / "machines",
                              ci_dir / ".." / "localAIStack" / "data" / "machines"]
    files = corpus_files([Path(r) for r in roots])
    if not files:
        print(f"no corpus files under {[str(r) for r in roots]}", file=sys.stderr)
        return 2

    selection = corpus_selection(args.machine_corpus, ci_dir)
    if selection is not None:
        # Unresolved entries are named, never dropped. A selection that
        # silently covers 17 of its 20 machines is a narrower gate wearing the
        # name of a wider one.
        missing = [n for n in selection if n not in files]
        if missing:
            print(f"corpus '{args.machine_corpus}' names {len(missing)} file(s) "
                  f"not found under any root: {', '.join(sorted(missing))}", file=sys.stderr)
            return 2
        files = {n: p for n, p in files.items() if n in set(selection)}
    if args.machine_names:
        want = {n.strip() for n in args.machine_names.split(",") if n.strip()}
        files = {n: p for n, p in files.items() if n[:-5] in want}
    if not files:
        print("selection resolved to no machines", file=sys.stderr)
        return 2

    order = [i["id"] for i in instances if i["runtime"] in NATIVE_QUORUM]
    by_id = {i["id"]: i for i in instances}

    # Reset before driving anything, both halves, through the one definition.
    # A failed reset is fatal *here*, unlike in the comparison stages: they can
    # still report honestly against unknown prior state, but this writes an
    # artifact that is consumed later as the contract, and a contract recorded
    # from state nobody established is not one.
    reset_failures: list[str] = []
    for inst in instances:
        reset_failures.extend(reset_pair(post_json, inst["re_url"], inst["pe_url"], inst["id"]))
    if reset_failures:
        for line in reset_failures:
            print(f"reset failed: {line}", file=sys.stderr)
        print("refusing to derive a contract from unknown prior state", file=sys.stderr)
        return 2

    verdicts: list[dict[str, Any]] = []
    for name, path in files.items():
        for chain in enumerate_chains(name, path):
            results = {k: run_chain(by_id[k], chain, args.run_id) for k in order}
            verdicts.append(classify(chain, results, order))

    payload = build_payload(verdicts, quorum, instances, len(files), args.machine_corpus)
    serialized = json.dumps(payload, indent=2, sort_keys=True) + "\n"

    c = payload["counts"]
    summary = (f"{c['agreed']} agreed · {c['disagreement']} disagreement · "
               f"{c['noRuntimeEmits']} no-runtime-emits · {c['unmeasurable']} unmeasurable")

    if args.check:
        existing = args.out.read_text(encoding="utf-8") if args.out.exists() else None
        if existing != serialized:
            print(f"[drift] {args.out} would change", file=sys.stderr)
            print("Re-derive with: scripts/regression-ces-contracts.py --record", file=sys.stderr)
            return 1
        print(f"ces-contracts: verified — {summary}")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(serialized, encoding="utf-8")
    print(f"ces-contracts: {summary} → {args.out}")
    for d in payload["disagreements"]:
        shape = " | ".join("+".join(cl["instances"]) for cl in d["clusters"])
        print(f"  disagreement: {d['chain']} — {shape}")
    for s in payload["noRuntimeEmits"]:
        print(f"  no runtime emits output: {s['chain']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
