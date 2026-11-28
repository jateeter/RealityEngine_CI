#!/usr/bin/env python3
"""Stage `sandbox`: a replica seeded from near-miss K-lines, 3-of-3 (RealityEngine_CI#605, #603).

Done when (#605): a replica booted from a bundle of the regression universe
re-establishes a sampled set of near-misses on each of the three engines, the
source stores are unchanged, and the replica's own K-lines are in its own store.

Per voter, after `kline-boundaries` has left abandoned K-lines in its store:
  export     its near-misses and the completed K-lines of the same focal machines
             as one re-kline-bundle/1 (scripts/sandbox.py export);
  up         a replica of its runtime: a sandbox lane UUID, its own state,
             store, registry and port, the same corpus (refused on a fingerprint
             mismatch), the bundle imported read-only;
  replay     a sample of near-misses, each restored from its activeBefore and
             replayed faithfully (its OSREs must reproduce and it must be
             abandoned again), then with the failing cell flipped;
  down       and the source's store is byte-identical to before the replica ran.

Across voters the replays agree: the same near-misses, reproduced alike, and the
same outcome when varied (docs/QUORUM_CONTRACT.md, no reference member).

TLS lane only: with RE_TLS off the stage is not evaluable, never plaintext.

Usage:
  regression-sandbox.py --registry FILE --corpus DIR --out REPORT [--repo RUNTIME=DIR ...] [--sample N]
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import re_tls  # noqa: E402
re_tls.install_lane_opener()
import instance_uuids  # noqa: E402
from followers import voters  # noqa: E402

spec = importlib.util.spec_from_file_location("sandbox", HERE / "sandbox.py")
sandbox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sandbox)

VOTERS = ("cpp", "lsp", "scala")


def tree_digest(root: Path) -> str:
    """One sha256 over every file under ROOT: names and bytes, in path order."""
    h = hashlib.sha256()
    for f in sorted(p for p in root.rglob("*") if p.is_file()):
        h.update(str(f.relative_to(root)).encode() + b"\0" + f.read_bytes() + b"\0")
    return h.hexdigest()


def ns(**kw: Any) -> argparse.Namespace:
    return argparse.Namespace(**kw)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--registry", required=True)
    ap.add_argument("--corpus", required=True, help="the machines/ directory the universe booted from")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--repo", action="append", default=[], metavar="RUNTIME=DIR")
    ap.add_argument("--kline-store", type=Path, help="the voters' K-line store parent")
    ap.add_argument("--sample", type=int, default=8)
    args = ap.parse_args()
    report: dict[str, Any] = {"stage": "sandbox", "issue": "RealityEngine_CI#605", "runtimes": {}}
    args.out.parent.mkdir(parents=True, exist_ok=True)

    def finish(result: str, failures: list[str], reason: str | None = None) -> int:
        report.update(result=result, failures=failures)
        if reason:
            report["reason"] = reason
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        for vid, r in report["runtimes"].items():
            print(f"  {vid}: {json.dumps({k: r.get(k) for k in ('replayed', 'reproduced', 'completedWhenVaried', 'replicaKlines', 'sourceUnchanged')})}")
        for f in failures:
            print(f"  FAIL {f}")
        print(f"sandbox: {result.upper()}" + (f" ({reason})" if reason else ""))
        return 0 if result in ("pass", "not-evaluable", "not-applicable") else 1

    if os.environ.get("RE_TLS", "off") != "on":
        return finish("not-evaluable", [], "a replica runs on the TLS lane only (RE_TLS=on)")
    doc = sandbox.load_registry(args.registry)
    by_runtime = {i["runtime"]: i for i in voters(doc.get("instances", [])) if i.get("runtime") in VOTERS}
    missing = [rt for rt in VOTERS if rt not in by_runtime]
    if missing:
        return finish("not-applicable", [], f"3-of-3 needs cpp, lsp and scala; this deployment lacks {', '.join(missing)}")
    repos = dict(r.split("=", 1) for r in args.repo)
    store_parent = args.kline_store or Path(instance_uuids.clock_dir()).parent / "klines"
    failures: list[str] = []
    outcomes: dict[str, dict[str, Any]] = {}
    scratch = Path(tempfile.mkdtemp(prefix="sandbox-stage-"))
    # The replica never writes the source's instance registry (#605, isolation).
    registry_file = Path(args.registry) if Path(args.registry).is_file() else None
    registry_before = hashlib.sha256(registry_file.read_bytes()).hexdigest() if registry_file else None
    try:
        for rt in VOTERS:
            inst = by_runtime[rt]
            iid = inst["id"]
            r: dict[str, Any] = {}
            report["runtimes"][iid] = r
            bundle = scratch / f"{iid}.jsonl"
            try:
                sandbox.cmd_export(ns(registry=args.registry, source=iid, out=str(bundle)))
            except (SystemExit, ValueError, OSError) as exc:
                failures.append(f"{iid}: export: {exc}")
                continue
            source_store = store_parent / str(inst.get("instance_uuid", "")).lower()
            before = tree_digest(source_store) if source_store.is_dir() else None
            name = f"regression-{iid}"
            if (sandbox.state_of(name) / "replica.json").exists():
                sandbox.cmd_down(ns(name=name))
            shutil.rmtree(sandbox.state_of(name), ignore_errors=True)
            try:
                sandbox.cmd_up(ns(registry=args.registry, source=iid, bundle=str(bundle), corpus=args.corpus,
                                  repo=repos.get(rt), name=name))
            except (SystemExit, ValueError, OSError) as exc:
                failures.append(f"{iid}: up: {exc}")
                continue
            try:
                sandbox.cmd_replay(ns(name=name, kline=None, sample=args.sample, vary=None))
            except (SystemExit, ValueError, OSError) as exc:
                failures.append(f"{iid}: replay: {exc}")
            finally:
                state = sandbox.state_of(name)
                meta = json.loads((state / "replica.json").read_text())
                sandbox.cmd_down(ns(name=name))
            ledger = [json.loads(l) for l in (state / "experiments.jsonl").read_text().splitlines() if l.strip()] \
                if (state / "experiments.jsonl").exists() else []
            shutil.copyfile(state / "experiments.jsonl", args.out.parent / f"sandbox-{iid}-experiments.jsonl") \
                if ledger else None
            replica_store = state / "klines" / meta["replica"]
            own = sum(1 for f in replica_store.glob("segment-*.jsonl") for line in f.read_text().splitlines() if line)
            imported = list((replica_store / "imported").rglob("*.jsonl"))
            after = tree_digest(source_store) if source_store.is_dir() else None
            r.update(replica=meta["replica"], replayed=len(ledger),
                     reproduced=sum(1 for e in ledger if e["faithful"].get("reproduced")),
                     abandonedAgain=sum(1 for e in ledger if e["faithful"].get("abandoned")),
                     completedWhenVaried=sum(1 for e in ledger if (e.get("varied") or {}).get("completed")),
                     replicaKlines=own, imported=len(imported), sourceUnchanged=before is not None and before == after)
            if not ledger:
                failures.append(f"{iid}: no near-miss was replayed")
            if r["reproduced"] != len(ledger):
                failures.append(f"{iid}: {len(ledger) - r['reproduced']} of {len(ledger)} near-misses did not reproduce")
            if own == 0:
                failures.append(f"{iid}: the replica recorded no K-line of its own")
            if not imported or any(os.access(f, os.W_OK) for f in imported):
                failures.append(f"{iid}: the bundle is not imported read-only under the replica's store")
            if not r["sourceUnchanged"]:
                failures.append(f"{iid}: the source store changed while the replica ran ({source_store})")
            if meta["replica"] == str(inst.get("instance_uuid", "")).lower():
                failures.append(f"{iid}: the replica took its source's UUID")
            outcomes[rt] = {f"{e['focal']['machine']}/{e['focal']['sequence']}@{e['difference'].get('cell')}":
                            [e["faithful"].get("reproduced"), e["faithful"].get("abandoned"),
                             (e.get("varied") or {}).get("completed")] for e in ledger}
            shutil.rmtree(state, ignore_errors=True)
        if len(outcomes) == len(VOTERS) and len({json.dumps(o, sort_keys=True) for o in outcomes.values()}) != 1:
            failures.append("the voters' replays differ: " + json.dumps(
                {rt: sorted(o.items()) for rt, o in outcomes.items()})[:600])
        report["agreement"] = len({json.dumps(o, sort_keys=True) for o in outcomes.values()}) == 1
        if registry_file:
            report["sourceRegistryUnchanged"] = hashlib.sha256(registry_file.read_bytes()).hexdigest() == registry_before
            if not report["sourceRegistryUnchanged"]:
                failures.append(f"the source's instance registry changed while the replicas ran ({registry_file})")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return finish("pass" if not failures else "fail", failures)


if __name__ == "__main__":
    sys.exit(main())
