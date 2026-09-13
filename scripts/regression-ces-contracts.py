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

# The corpus repo owns what "the corpus changed" means, and this stage records
# an artifact whose whole validity is "recorded against that corpus". Importing
# rather than restating is the point: a fingerprint computed two ways is two
# fingerprints, and the registry that compares them would report drift that is
# not there. This is the same sibling dependency the corpus roots already are.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]
                       / "RealityEngine_Machines" / "scripts"))
try:
    import ces_corpus_fingerprint as fingerprints  # noqa: E402
except ModuleNotFoundError:  # pragma: no cover - sibling repo absent
    fingerprints = None

MAX_CHAIN_DEPTH = 4  # same cap as cesgen-oracles and the tool this replaces
NATIVE_QUORUM = ("cpp", "lsp", "scala")
CONTRACT_VERSION = "2.1.0"


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


def available_domains(files: dict[str, Path]) -> list[str]:
    """Domain directory names present under any corpus root's `machines/domains/`.

    Read off the resolved corpus rather than from a list, so a domain added to
    RealityEngine_Machines is selectable the moment it exists. There is no
    second place recording which domains there are, and therefore no second
    place to forget to update.
    """
    out = set()
    for path in files.values():
        parts = path.resolve().parts
        for i in range(len(parts) - 2):
            if parts[i] == "machines" and parts[i + 1] == "domains":
                out.add(parts[i + 2])
                break
    return sorted(out)


def corpus_selection(name: str, ci_dir: Path, files: dict[str, Path]) -> list[str] | None:
    """Basenames named by a selection, or None for the whole corpus.

    Three selector shapes, and the artifact records which one it was recorded
    from (`machineCorpus`), because a shard that does not say what it covers
    cannot be told from one that covers everything:

    - `full` — every resolved corpus file.
    - `domain:<name>` — the machines under `machines/domains/<name>/`. One
      shard per domain is what makes the contract re-derivable at the
      granularity the corpus actually mutates at: machines arrive a domain at
      a time, and a monolithic artifact makes every arrival a whole-corpus
      re-record and an unreadable diff.
    - anything else — a `config/<name>-corpus.txt` list, the same files
      `startUniverse.sh` boots from, read rather than restated.

    Entries in the `.txt` lists are repo-relative paths; only the basename
    matters here, since corpus filenames are globally unique. Domain selection
    goes by path, since that is what the grouping means.
    """
    if name == "full":
        return None
    if name.startswith("domain:"):
        domain = name[len("domain:"):]
        if not domain:
            raise SystemExit("empty domain in --machine-corpus domain:<name>")
        marker = ("machines", "domains", domain)
        sel = [n for n, p in files.items()
               if any(p.resolve().parts[i:i + 3] == marker
                      for i in range(len(p.resolve().parts) - 2))]
        if not sel:
            raise SystemExit(
                f"unknown domain '{domain}': no machines under machines/domains/{domain}/. "
                f"Available: " + ", ".join(available_domains(files)))
        return sel
    path = ci_dir / "config" / f"{name}-corpus.txt"
    if not path.exists():
        raise SystemExit(
            f"unknown corpus '{name}': no {path}. "
            f"Available: full, domain:<one of {'/'.join(available_domains(files))}>, "
            + ", ".join(
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
            # Ask the engine for this machine's entries only (RealityEngine_CI#367).
            # Before this, every push answered with the whole universe — 1.6 MB at
            # full corpus — and `project_step` discarded almost all of it after
            # transfer. That cost two runtimes' heaps mid-sweep and killed them.
            #
            # `project_step` still runs, and deliberately: it is the definition of
            # what belongs to this machine, and keeping it means the server-side
            # filter is *checked* rather than trusted. If the two ever disagree the
            # recording is wrong in a way no test would otherwise show.
            status, payload = post_json(f"{pe_url}/api/push", {
                "compact": True,
                "includePerceptualSpace": False,
                "includeActiveRegions": False,
                "only": {"sequenceIds": chain["ownSequenceIds"]},
            })
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


# ── Confirming a disagreement ───────────────────────────────────────────────

def cluster_shape(results: dict[str, Any], order: list[str]) -> str:
    """A disagreement's shape as a comparable string: `cpp-1 | lsp-1+scala-1`."""
    return " | ".join("+".join(c) for c in agreement_clusters(results, order))


def confirm_disagreement(chain: dict[str, Any], verdict: dict[str, Any],
                         by_id: dict[str, dict[str, str]], order: list[str],
                         run_id: str, attempts: int) -> dict[str, Any]:
    """Re-drive a disagreeing chain and record whether the disagreement holds.

    **Why this stage exists.** Measured on this corpus: after the universe sits
    idle for about a minute, the first recording emits exactly one cpp
    disagreement — and it is a *different chain* each time, while two recordings
    taken back to back are byte-identical and clean. So a chain can be reported
    as divergent because of when it was driven rather than because the runtimes
    differ, and a sweep of a dozen domains would scatter those across every
    shard with nothing to distinguish them from real divergence.

    **This is not a retry.** A retry would re-drive until the runtimes agree and
    record the agreement, which is the one thing that must never happen here:
    it would convert a real, intermittent divergence into a contract, and the
    contract would then be enforced against the runtime that was right. Nothing
    observed is discarded. Every attempt's cluster shape is carried, and a
    disagreement that does not reproduce is recorded as its own verdict rather
    than being resolved either way.

    A `disagreement` therefore now means "they differ, and it held on re-drive".
    An `intermittent` means "they differed, and the difference did not survive
    being asked again" — a finding about stability, which is not the same
    finding as a behavioural difference, and is not agreement either.
    """
    first = cluster_shape({k: {"stream": c["outputStream"]}
                           for c in verdict["clusters"] for k in c["instances"]}, order)
    observations = [first]
    for _ in range(attempts):
        again = {k: run_chain(by_id[k], chain, run_id) for k in order}
        if any("error" in (again.get(k) or {}) for k in order):
            # A lane that could not be driven proves nothing about stability,
            # and must not be read as the disagreement failing to reproduce.
            observations.append("undriven")
            continue
        observations.append(cluster_shape(again, order))

    # Judged only on re-drives that actually ran. An undriven lane is absence of
    # evidence, and counting it as "the shape changed" would demote a real
    # divergence on the strength of a 500 — the same collapse of "could not be
    # driven" into "did not happen" that `unmeasurable` exists to prevent.
    redrives = [o for o in observations[1:] if o != "undriven"]
    verdict["attempts"] = len(observations)
    verdict["observedShapes"] = observations
    if not redrives:
        verdict["stability"] = "unconfirmed"
        verdict["stabilityNote"] = ("no re-drive completed; the disagreement stands as "
                                    "first observed and was not confirmed either way")
        return verdict
    if all(o == first for o in redrives):
        verdict["stability"] = "reproduced"
        return verdict

    # Demoted out of `disagreement`, because the artifact's disagreement list is
    # read as "here is where the runtimes differ" and this is not that.
    return {
        "verdict": "intermittent",
        "chain": verdict["chain"],
        "machineFile": verdict["machineFile"],
        "sequenceId": verdict["sequenceId"],
        "terminalEventId": verdict["terminalEventId"],
        "quorum": "3-of-3",
        "stability": "not-reproduced",
        "attempts": len(observations),
        "observedShapes": observations,
        "clusters": verdict["clusters"],
    }


# ── Main ────────────────────────────────────────────────────────────────────

def corpus_fingerprint(files: dict[str, Path]) -> dict[str, Any] | None:
    """The corpus this recording was made against, as the corpus repo defines it.

    Written into the artifact rather than into a side table, so a shard carries
    its own answer to "is this still true?". A recording whose corpus
    description lives somewhere else is one the two can be separated from, and
    the separated pair reads as current.
    """
    if fingerprints is None:
        return None
    root = Path(__file__).resolve().parents[2] / "RealityEngine_Machines" / "machines"
    return fingerprints.fingerprint_paths(files.values(), root)


def build_payload(verdicts: list[dict[str, Any]], quorum: dict[str, Any],
                  instances: list[dict[str, str]], machine_count: int,
                  machine_corpus: str = "regression",
                  fingerprint: dict[str, Any] | None = None) -> dict[str, Any]:
    by = lambda v: [x for x in verdicts if x["verdict"] == v]  # noqa: E731
    agreed, disagreed = by("agreed"), by("disagreement")
    silent, unmeasurable = by("no-runtime-emits"), by("unmeasurable")
    intermittent = by("intermittent")
    return {
        "version": CONTRACT_VERSION,
        "generatedBy": "scripts/regression-ces-contracts.py",
        "derivedFrom": "3-of-3 agreement across the cpp, lsp and scala runtimes",
        "contract": "docs/QUORUM_CONTRACT.md",
        "quorum": quorum,
        # Which selection this was recorded from. A contract that does not say
        # what it covers cannot be told from one that covers everything.
        "machineCorpus": machine_corpus,
        # The corpus state this recording is true of. Consumed by
        # RealityEngine_Machines/scripts/build-ces-contract-registry.py to tell
        # a current shard from one the corpus has moved out from under.
        "corpusFingerprint": fingerprint,
        "runtimes": sorted({i["runtime"] for i in instances}),
        "machineCount": machine_count,
        "counts": {
            "agreed": len(agreed),
            "disagreement": len(disagreed),
            "noRuntimeEmits": len(silent),
            "unmeasurable": len(unmeasurable),
            "intermittent": len(intermittent),
        },
        # Enumerated, never counted. An unimplemented shape and one nothing
        # happened to exercise look identical once they are a number (§3).
        "contracts": sorted(agreed, key=lambda c: c["chain"]),
        "disagreements": sorted(disagreed, key=lambda c: c["chain"]),
        "noRuntimeEmits": sorted(silent, key=lambda c: c["chain"]),
        "unmeasurable": sorted(unmeasurable, key=lambda c: c["chain"]),
        # Neither a contract nor a stable divergence. Enumerated separately so
        # a reader is never asked to guess which of the two it was.
        "intermittent": sorted(intermittent, key=lambda c: c["chain"]),
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
                        "arbiter-fixture, standard-deployment-plus-ring, full, or "
                        "domain:<name> for one corpus domain (see --list-scopes).")
    p.add_argument("--out", type=Path, default=Path("config/ces-contracts.json"),
                   help="Authoritative artifact. A git file by QUORUM_CONTRACT §4.")
    p.add_argument("--machine-names", help="Comma-separated basenames (without .json) to restrict to.")
    p.add_argument("--run-id", default=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    # Two by default, and only disagreeing chains pay it: on this corpus that is
    # a handful out of thousands, so the sweep cost is noise. Zero disables
    # confirmation and restores the 2.0.0 behaviour — available for diagnosing
    # the confirmation stage itself, not for routine recording.
    p.add_argument("--confirm-disagreements", type=int, default=2, metavar="N",
                   help="Re-drive each disagreeing chain N times and record whether "
                        "the disagreement reproduced (default 2; 0 disables).")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--record", action="store_true", help="Write the artifact.")
    mode.add_argument("--check", action="store_true", help="Exit 1 if the artifact would change.")
    mode.add_argument("--list-scopes", action="store_true",
                      help="Print every selectable scope and exit. Needs no running universe.")
    args = p.parse_args()

    ci_dir = Path(__file__).resolve().parent.parent
    default_roots = [ci_dir / ".." / "RealityEngine_Machines" / "machines",
                     ci_dir / ".." / "localAIStack" / "data" / "machines"]

    if args.list_scopes:
        # A corpus question, answered without a universe. The command that says
        # what is recordable must not itself require a formed quorum.
        files = corpus_files([Path(r) for r in (args.machines or default_roots)])
        print("full")
        for name in sorted(f.stem[:-7] for f in (ci_dir / "config").glob("*-corpus.txt")):
            print(name)
        for domain in available_domains(files):
            print(f"domain:{domain}")
        return 0

    instances = load_instances(args.registry)
    quorum = quorum_composition(instances)
    if not quorum["formed"]:
        # Refused rather than recorded-with-a-caveat. A caveat in a file is read
        # by whoever opens the file; a missing runtime is read by nobody (§2).
        print(f"quorum not formed: 3-of-3 requires {'+'.join(NATIVE_QUORUM)}, "
              f"missing {'+'.join(quorum['missing'])}", file=sys.stderr)
        print("refusing to derive a contract from an incomplete quorum", file=sys.stderr)
        return 2

    roots = args.machines or default_roots
    files = corpus_files([Path(r) for r in roots])
    if not files:
        print(f"no corpus files under {[str(r) for r in roots]}", file=sys.stderr)
        return 2

    selection = corpus_selection(args.machine_corpus, ci_dir, files)
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
            verdict = classify(chain, results, order)
            if verdict["verdict"] == "disagreement" and args.confirm_disagreements > 0:
                verdict = confirm_disagreement(chain, verdict, by_id, order,
                                               args.run_id, args.confirm_disagreements)
            verdicts.append(verdict)

    # Quorum again, AFTER driving. Checking only before proves the quorum existed
    # when the run started, which is not the claim the artifact makes — it claims
    # every recorded contract was agreed by three runtimes. Measured: lsp and
    # scala died partway through the energy domain and the artifact was still
    # written carrying `formed: true, missing: []`, with 224 contracts asserting
    # agreement by three runtimes and 139 chains that could not be driven at all.
    # Both halves cannot be true of the same run.
    closing = quorum_composition(load_instances(args.registry)) \
        if args.registry.exists() else {"formed": False, "missing": list(NATIVE_QUORUM)}
    if not closing["formed"]:
        print(f"quorum collapsed during the run: {'+'.join(closing['missing'])} "
              f"stopped answering", file=sys.stderr)
        print("refusing to write a contract whose quorum did not hold throughout",
              file=sys.stderr)
        return 2

    # The decisive check, and the only one derived from the drive attempts
    # themselves. The two before it ask the instance registry whether three
    # runtimes are *registered*; this asks the run whether three runtimes were
    # actually *driven*. They are not the same question, and the difference is
    # what let a second invalid energy shard through: scala stayed listed as
    # running while 115 chains recorded it as undriven, so both quorum checks
    # passed and the artifact was written claiming 3-of-3 agreement.
    #
    # A runtime that could not be driven for even one chain did not participate
    # in this recording, and no contract in it is a three-way agreement.
    undriven = sorted({r for v in verdicts if v["verdict"] == "unmeasurable"
                       for r in v.get("undrivenRuntimes", [])})
    if undriven:
        n = sum(1 for v in verdicts if v["verdict"] == "unmeasurable")
        print(f"{'+'.join(undriven)} could not be driven for {n} chain(s)",
              file=sys.stderr)
        print("refusing to write a contract whose quorum did not hold throughout "
              "the run (registered is not the same as driven)", file=sys.stderr)
        return 2

    payload = build_payload(verdicts, quorum, instances, len(files), args.machine_corpus,
                            corpus_fingerprint(files))
    serialized = json.dumps(payload, indent=2, sort_keys=True) + "\n"

    c = payload["counts"]
    summary = (f"{c['agreed']} agreed · {c['disagreement']} disagreement · "
               f"{c['intermittent']} intermittent · "
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
        print(f"  disagreement: {d['chain']} — {shape} (held over {d.get('attempts', 1)} drives)")
    for d in payload["intermittent"]:
        print(f"  intermittent: {d['chain']} — {' then '.join(d['observedShapes'])}")
    for s in payload["noRuntimeEmits"]:
        print(f"  no runtime emits output: {s['chain']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
