#!/usr/bin/env python3
"""Stage `snapshots`: runtime snapshots, 3-of-3 (RealityEngine_CI#287, phase 2).

SURFACE_SPEC "K-lines and runtime snapshots": "The snapshot body", "Routes",
"Acceptance (phase 2)". No runtime is a reference (docs/QUORUM_CONTRACT.md).

Every voter is reset and driven with the same explicit input vectors through
`POST /api/perceive`, each step read at its completion point
(`GET /api/engine/steps/:n/pair`). Then:

  digest      the same state has the same digest on every runtime: one step,
              a span, and a narrowed scope;
  round trip  snapshot, reset, restore: the next steps are identical, step
              numbers and OSRE, to the engine that was never reset;
  cross       a snapshot from any runtime restores into every runtime, which
              then commits the source's next steps exactly (all pairs);
  self        re-establishing activeBefore for a scope (a narrowed snapshot one
              step earlier) and presenting the span's ISREs reproduces its OSREs
              outside sharedCells and ends in its activeAfter, on every runtime;
  refusals    a span beyond the retained steps is 410, a body whose digest does
              not match is 422, and a real corpus mismatch (a machine added, then
              removed again) is 409 naming both fingerprints.

  nearest     (#900) the same stored snapshots answer POST
              /api/runtime/snapshots/nearest alike on every runtime: the same
              ids in the same order and the same scores, the queried state first;
  qdrant      (#900) when the run has an https Qdrant (the instance registry's
              `qdrant` service on the TLS lane, or --qdrant), a fresh RE per
              runtime on RE_SNAPSHOT_STORE=qdrant:<it>, in a collection of the
              run's own: driven as the voters were, its list, get (digest
              re-verified), restore and nearest answer exactly as the memory-store
              voters did, each lists only its own points, and the collection is
              deleted after.

The stage deletes every snapshot it made and resets every voter when it ends.

Not evaluated here: RE_SNAPSHOT_STORE=off (each engine's unit tests cover the
store's modes; a store-off engine is a boot setting, not a stage drive), and
the Qdrant leg without an https Qdrant, the lane TLS, or --repo and --corpus.

Usage:
  regression-snapshots.py --registry FILE --out REPORT [--steps N]
                          [--corpus DIR --repo RUNTIME=DIR ... [--qdrant URL]]
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib import error, request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import re_tls  # noqa: E402
re_tls.install_lane_opener()  # the lane CA and harness certificate when RE_TLS=on (#732)
from followers import voters  # noqa: E402
from reset_contract import reset_pair  # noqa: E402
import instance_uuids  # noqa: E402
import jcs  # noqa: E402
import kline_restart  # noqa: E402

VOTERS = ("cpp", "lsp", "scala")
NOT_EVALUATED = ["store off: RE_SNAPSHOT_STORE=off is a boot setting; each engine's unit tests cover the store's modes"]


def http(method: str, url: str, payload: Any = None, timeout: int = 120) -> tuple[int, Any]:
    data = json.dumps(payload).encode() if payload is not None else None
    req = request.Request(url, data=data, method=method,
                          headers={"content-type": "application/json", "accept": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout) as r:
            raw, status = r.read(), r.status
    except error.HTTPError as exc:
        raw, status = exc.read(), exc.code
    except Exception as exc:  # noqa: BLE001 -- a dead engine is a result, not a crash
        return 0, str(exc)
    try:
        return status, json.loads(raw) if raw else None
    except (json.JSONDecodeError, UnicodeDecodeError):
        return status, raw.decode("utf-8", "replace")


class Voter:
    def __init__(self, instance: dict):
        self.id = instance.get("id", instance["runtime"])
        self.runtime = instance["runtime"]
        self.re = instance["re_url"].rstrip("/")
        self.pe = (instance.get("pe_url") or "").rstrip("/")
        self.failures: list[str] = []
        self.made: list[str] = []

    def check(self, ok: bool, message: str) -> bool:
        if not ok:
            self.failures.append(f"{self.id}: {message}")
        return ok

    def reset(self) -> None:
        for f in reset_pair(lambda url, body: http("POST", url, body), self.re, self.pe or None, self.id):
            self.check(False, f)

    def width(self) -> int:
        return int(http("GET", f"{self.re}/api/config")[1]["eventDimension"])

    def step(self, vector: list[float]) -> tuple[int, Any]:
        """Push one input; its step number and its committed OSRE, read at the completion point."""
        status, body = http("POST", f"{self.re}/api/perceive", {"vector": vector, "compact": True})
        if status != 200 or not isinstance(body, dict):
            raise RuntimeError(f"POST /api/perceive -> {status} {str(body)[:120]}")
        n = body.get("stepNumber", (body.get("step") or {}).get("stepNumber"))
        status, pair = http("GET", f"{self.re}/api/engine/steps/{n}/pair?timeoutMs=5000")
        if status != 200:
            raise RuntimeError(f"GET /api/engine/steps/{n}/pair -> {status}")
        return n, pair["osre"]

    def drive(self, vectors: list[list[float]]) -> list[tuple[int, Any]]:
        return [self.step(v) for v in vectors]

    def snapshot(self, body: dict) -> tuple[int, Any]:
        status, r = http("POST", f"{self.re}/api/runtime/snapshot", body)
        if status != 200:
            return status, r
        self.made.append(r["id"])
        return 200, http("GET", f"{self.re}/api/runtime/snapshot/{r['id']}")[1]

    def restore(self, snap: dict) -> tuple[int, Any]:
        return http("POST", f"{self.re}/api/runtime/restore", {"snapshot": snap})

    def clean(self) -> None:
        for sid in self.made:
            http("DELETE", f"{self.re}/api/runtime/snapshot/{sid}")
        self.reset()


def vectors(width: int, count: int, seed: int) -> list[list[float]]:
    rnd = random.Random(seed)
    return [[1.0 if rnd.random() < 0.3 else 0.0 for _ in range(width)] for _ in range(count)]


def dense(entry: dict) -> list[float]:
    v = [0.0] * int(entry["length"])
    for c in entry["nonZero"]:
        v[int(c["index"])] = c["value"]
    return v


def run(vs: list[Voter], steps: int, report: dict) -> None:
    widths = {v.id: v.width() for v in vs}
    if len(set(widths.values())) != 1:
        vs[0].check(False, f"the voters' widths differ: {widths}")
        return
    w = next(iter(widths.values()))
    pre, post = vectors(w, steps, 7), vectors(w, 10, 8)
    names: list[str] = []

    # Drive, snapshot, and the engine that is never reset: its next steps.
    snaps: dict[str, dict] = {}
    following: dict[str, list] = {}
    for v in vs:
        v.reset()
        v.drive(pre)
        status, s = v.snapshot({})
        if not v.check(status == 200, f"POST /api/runtime/snapshot -> {status} {str(s)[:160]}"):
            return
        snaps[v.id] = s
        following[v.id] = v.drive(post)
        if not names:
            _, ms = http("GET", f"{v.re}/api/machines")
            names = sorted((m["name"] for m in ms.get("machines", [])), key=lambda n: n.encode())

    # The same state, the same digest: one step, a span, a narrowed scope.
    last = steps - 1
    scope = names[:3]
    digests: dict[str, dict[str, str]] = {"one step": {v.id: snaps[v.id]["digest"] for v in vs}}
    for label, body in ((f"span {last - 9}..{last}", {"from": last - 9, "to": last}),
                        (f"scope of {len(scope)}", {"scope": scope, "from": last - 9, "to": last})):
        digests[label] = {}
        for v in vs:
            # Restore the drive's state first: the following steps moved the engine on.
            v.restore(snaps[v.id])
            status, s = v.snapshot(body)
            digests[label][v.id] = s.get("digest") if status == 200 else f"status {status}"
    report["digests"] = digests
    for label, d in digests.items():
        vs[0].check(len(set(d.values())) == 1, f"digest, {label}: not equal 3-of-3 {d}")

    # Round trip and cross-runtime: every source into every target.
    cross: dict[str, dict[str, bool]] = {}
    for src in vs:
        cross[src.id] = {}
        for dst in vs:
            dst.reset()
            status, r = dst.restore(snaps[src.id])
            if not dst.check(status == 200, f"restore from {src.id} -> {status} {str(r)[:160]}"):
                cross[src.id][dst.id] = False
                continue
            dst.check(r.get("digest") == snaps[src.id]["digest"], f"restore from {src.id} answered another digest")
            same = dst.drive(post) == following[src.id]
            cross[src.id][dst.id] = same
            dst.check(same, f"restored from {src.id}, the next {len(post)} steps differ from {src.id}'s")
    report["cross"] = cross

    # Self-verification on every runtime, over the scope.
    selfv: dict[str, dict] = {}
    m, n = last - 6, last
    for v in vs:
        v.reset()
        v.drive(pre)
        _, target = v.snapshot({"scope": scope, "from": m, "to": n})
        _, start = v.snapshot({"scope": scope, "from": m - 1, "to": m - 1})
        _, full = v.snapshot({"from": m, "to": n})
        ok_start = start["kline"]["activeAfter"] == target["kline"]["activeBefore"]
        status, _ = v.restore(start)
        shared = set(target["kline"]["sharedCells"])
        outputs = {c["index"] for p in target["kline"]["pairs"] for c in p["osre"]["nonZero"]}
        reproduced = True
        for pf, pt in zip(full["kline"]["pairs"], target["kline"]["pairs"]):
            _, osre = v.step(dense(pf["isre"]))
            want = {c["index"]: c["value"] for c in pt["osre"]["nonZero"] if c["index"] not in shared}
            got = {c["index"]: c["value"] for c in osre["nonZero"]
                   if c["index"] not in shared and (c["index"] in outputs or c["index"] in want)}
            reproduced &= got == want
        _, end = v.snapshot({"scope": scope})
        ends = end["kline"]["activeAfter"] == target["kline"]["activeAfter"]
        selfv[v.id] = {"restored": status == 200, "startIsActiveBefore": ok_start, "osreReproduced": reproduced,
                       "endsInActiveAfter": ends}
        v.check(status == 200 and ok_start and reproduced and ends, f"self-verification: {selfv[v.id]}")
    report["selfVerification"] = selfv

    # Refusals.
    refusals: dict[str, dict] = {}
    for v in vs:
        r410 = v.snapshot({"from": 0, "to": 10 ** 6})[0]
        bad = json.loads(json.dumps(snaps[v.id]))
        bad["machineOverrides"] = {}
        r422 = v.restore(bad)[0]
        # A real corpus mismatch: a machine added (the engine versions its name), then removed.
        _, listing = http("GET", f"{v.re}/api/machines")
        first = sorted(listing["machines"], key=lambda x: x["name"].encode())[0]
        _, full_m = http("GET", f"{v.re}/api/machines/{first['id']}")
        status, added = http("POST", f"{v.re}/api/machines", full_m["machine"])
        added_id = (added or {}).get("id") or ((added or {}).get("machine") or {}).get("id")
        r409, body409 = v.restore(snaps[v.id])
        if added_id:
            http("DELETE", f"{v.re}/api/machines/{added_id}")
        names_both = isinstance(body409, dict) and bool(body409.get("expected")) and bool(body409.get("actual"))
        refusals[v.id] = {"evicted": r410, "badDigest": r422, "corpusMismatch": r409, "namesBoth": names_both}
        v.check(r410 == 410, f"a span beyond the retained steps answered {r410}")
        v.check(r422 == 422, f"a body whose digest does not match answered {r422}")
        v.check(r409 == 409 and names_both, f"a corpus mismatch answered {r409} {str(body409)[:120]}")
    report["refusals"] = refusals

    # Nearest (#900): the same stored snapshots answer alike, 3-of-3. The third
    # snapshot's state (span.to = last - 7) is the query, so it comes first.
    spans = ({}, {"from": last - 4, "to": last}, {"from": last - 9, "to": last - 7})
    nearest: dict[str, dict] = {}
    for v in vs:
        # Only these three in the store, so every store compared holds the same.
        for sid in v.made:
            http("DELETE", f"{v.re}/api/runtime/snapshot/{sid}")
        v.made = []
        v.reset()
        v.drive(pre)
        bodies = [v.snapshot(b)[1] for b in spans]
        third = bodies[2]
        q = next(p["isre"] for p in third["kline"]["pairs"] if p["stepNumber"] == third["kline"]["span"]["to"])
        query = {"length": q["length"], "nonZero": q["nonZero"]}
        st, n = http("POST", f"{v.re}/api/runtime/snapshots/nearest", {"isre": query, "limit": 5})
        _, listing = http("GET", f"{v.re}/api/runtime/snapshots")
        nearest[v.id] = {"ids": [b["id"] if isinstance(b, dict) and "id" in b else jcs_id(b) for b in bodies],
                         "list": [x["id"] for x in (listing or {}).get("snapshots", [])],
                         "nearest": [[x["id"], x["score"]] for x in (n or {}).get("snapshots", [])] if st == 200 else st,
                         "query": query, "bad": http("POST", f"{v.re}/api/runtime/snapshots/nearest", {"isre": "x"})[0]}
        v.check(st == 200 and bool(n["snapshots"]) and n["snapshots"][0]["id"] == nearest[v.id]["ids"][2],
                f"nearest: the queried state is not first ({st} {str(n)[:160]})")
        v.check(nearest[v.id]["bad"] == 422, f"nearest: a malformed isre answered {nearest[v.id]['bad']}")
    shape = {vid: json.dumps({k: n[k] for k in ("ids", "list")}) for vid, n in nearest.items()}
    vs[0].check(len(set(shape.values())) == 1, f"nearest: the stored snapshots differ across runtimes {shape}")
    vs[0].check(all(same_ranking(nearest[vs[0].id]["nearest"], n["nearest"]) for n in nearest.values()),
                "nearest: the ranking differs across runtimes " + json.dumps({k: n["nearest"] for k, n in nearest.items()})[:400])
    report["nearest"] = {vid: {k: n[k] for k in ("ids", "nearest")} for vid, n in nearest.items()}
    report["_memory"] = nearest  # for the Qdrant leg; removed before the report is written
    report["_pre"] = pre
    report["_spans"] = spans


def jcs_id(body: Any) -> str:
    return body["digest"].removeprefix("sha256:") if isinstance(body, dict) else ""


def same_ranking(a: Any, b: Any) -> bool:
    """The same ids in the same order, the scores equal as numbers."""
    if not isinstance(a, list) or not isinstance(b, list) or len(a) != len(b):
        return False
    return all(x[0] == y[0] and abs(x[1] - y[1]) <= 1e-12 * max(1.0, abs(x[1])) for x, y in zip(a, b))


def qdrant_leg(vs: list[Voter], args: argparse.Namespace, registry: dict, report: dict, failures: list[str]) -> None:
    """A fresh RE per runtime on the run's https Qdrant (#900), against the voters' memory answers."""
    qurl = args.qdrant or ((registry.get("services") or {}).get("qdrant") or {}).get("url", "")
    why = None
    if not qurl.startswith("https://"):
        why = "no https Qdrant in this run (the registry's qdrant service is not on the TLS lane; --qdrant names one)"
    elif os.environ.get("RE_TLS", "off") != "on":
        why = "the Qdrant leg runs on the TLS lane only (RE_TLS=on)"
    elif not args.corpus or len(args.repo) < len(VOTERS):
        why = "the Qdrant leg needs --corpus and --repo for every runtime"
    elif "_memory" not in report:
        why = "the voters' memory answers were not recorded"
    if why:
        report["qdrant"] = {"result": "not-evaluated", "reason": why}
        report["notEvaluated"] = report["notEvaluated"] + [f"qdrant store: {why}"]
        return
    qurl = qurl.rstrip("/")
    repos = dict(r.split("=", 1) for r in args.repo)
    collection = f"re-snapshots-regression-{os.getpid()}-{int(time.time())}"
    scratch = Path(tempfile.mkdtemp(prefix="snapshots-qdrant-"))
    procs: dict[str, subprocess.Popen] = {}
    replicas: dict[str, dict] = {}
    out: dict[str, Any] = {"collection": collection, "runtimes": {}}
    try:
        width = vs[0].width()
        for rt in VOTERS:
            uuid = instance_uuids.allocate("sandbox", f"snapshots-qdrant/{rt}", os.getpid())
            name = f"snapshots-qdrant-{rt}"
            kline_restart.pki("issue", name, "--kind", "both", "--dns", "localhost", "--ip", "127.0.0.1",
                              "--instance-uuid", uuid)
            mine, harness = kline_restart.pki("paths", name), kline_restart.pki("paths", "harness")
            port = kline_restart.free_port()
            env = {**os.environ, "INSTANCE_UUID": uuid, "INSTANCE_ID": name,
                   "INSTANCE_CLOCK_DIR": str(instance_uuids.clock_dir()),
                   "INSTANCE_KLINE_DIR": str(scratch / rt / "klines"), "INSTANCE_ISRE_DIR": str(scratch / rt / "isre"),
                   "MACHINES_DIR": args.corpus, "VECTOR_DIMENSION": str(width),
                   "REALITY_ENGINE_PORT": str(port), "PORT": str(port),
                   "RE_SNAPSHOT_STORE": f"qdrant:{qurl}", "RE_SNAPSHOT_COLLECTION": collection,
                   "RE_TLS_CERT": mine["chain"], "RE_TLS_KEY": mine["key"],
                   "RE_TLS_CA": harness["ca"], "RE_TLS_CRL": harness["crl"]}
            (scratch / rt).mkdir(parents=True, exist_ok=True)
            log = open(scratch / f"{rt}.log", "w")
            procs[rt] = subprocess.Popen(kline_restart.launch(rt, Path(repos[rt]), port, args.corpus, width), env=env,
                                         cwd=repos[rt], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            replicas[rt] = {"url": f"https://127.0.0.1:{port}", "uuid": uuid}
        for rt, r in replicas.items():
            deadline = time.time() + kline_restart.BOOT_SECONDS
            while time.time() < deadline and procs[rt].poll() is None and http("GET", f"{r['url']}/api/engine/clock")[0] != 200:
                time.sleep(2)
            if http("GET", f"{r['url']}/api/engine/clock")[0] != 200:
                failures.append(f"qdrant: the {rt} replica did not come up (log {scratch / (rt + '.log')})")
        memory = report["_memory"]
        for rt, r in replicas.items():
            u, mem = r["url"], memory[next(v.id for v in vs if v.runtime == rt)]
            res: dict[str, Any] = {}
            http("POST", f"{u}/api/engine/reset", {})
            for vec in report["_pre"]:
                http("POST", f"{u}/api/perceive", {"vector": vec, "compact": True})
            ids = []
            for b in report["_spans"]:
                st, x = http("POST", f"{u}/api/runtime/snapshot", b)
                ids.append(x.get("id") if st == 200 and isinstance(x, dict) else f"status {st}: {str(x)[:120]}")
            res["ids"] = ids == mem["ids"]
            _, listing = http("GET", f"{u}/api/runtime/snapshots")
            res["list"] = [x["id"] for x in (listing or {}).get("snapshots", [])] == mem["list"]
            res["get"] = all(isinstance(g := http("GET", f"{u}/api/runtime/snapshot/{i}")[1], dict)
                             and jcs.snapshot_digest(g) == g.get("digest") for i in ids)
            res["restore"] = http("POST", f"{u}/api/runtime/restore", {"id": ids[0]})[0] == 200
            st, n = http("POST", f"{u}/api/runtime/snapshots/nearest", {"isre": mem["query"], "limit": 5})
            res["nearest"] = st == 200 and same_ranking([[x["id"], x["score"]] for x in n["snapshots"]], mem["nearest"])
            out["runtimes"][rt] = res
            for k, ok in res.items():
                if not ok:
                    failures.append(f"qdrant {rt}: {k} differs from the memory-store voter ({ids if k == 'ids' else ''})")
        # One collection, three instances: each sees its own.
        st, cnt = http("POST", f"{qurl}/collections/{collection}/points/count", {"exact": True})
        total = cnt["result"]["count"] if st == 200 else None
        own = {rt: len((http("GET", f"{r['url']}/api/runtime/snapshots")[1] or {}).get("snapshots", []))
               for rt, r in replicas.items()}
        out["isolation"] = {"points": total, "listed": own}
        if total != 3 * len(report["_spans"]) or any(n != len(report["_spans"]) for n in own.values()):
            failures.append(f"qdrant: isolation, {total} points in the collection, each lists {own}")
    finally:
        for p in procs.values():
            try:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(timeout=30)
            except Exception:  # noqa: BLE001 -- already gone, or killed below
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        out["collectionDeleted"] = http("DELETE", f"{qurl}/collections/{collection}")[0] == 200
        shutil.rmtree(scratch, ignore_errors=True)
    out["result"] = "pass" if not [f for f in failures if f.startswith("qdrant")] else "fail"
    report["qdrant"] = out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--registry", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--steps", type=int, default=30)
    ap.add_argument("--corpus", help="the machines/ directory the universe booted from (the Qdrant leg)")
    ap.add_argument("--repo", action="append", default=[], metavar="RUNTIME=DIR", help="engine checkouts (the Qdrant leg)")
    ap.add_argument("--qdrant", default="", help="an https Qdrant; default: the registry's qdrant service")
    args = ap.parse_args()
    doc = json.loads(args.registry.read_text(encoding="utf-8"))
    by_runtime: dict[str, dict] = {}
    for i in voters(doc.get("instances", [])):
        if i.get("runtime") in VOTERS and i["runtime"] not in by_runtime and i.get("re_url"):
            by_runtime[i["runtime"]] = i
    missing = [rt for rt in VOTERS if rt not in by_runtime]
    report: dict[str, Any] = {"stage": "snapshots", "issue": "RealityEngine_CI#287", "notEvaluated": NOT_EVALUATED}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    if missing:
        report.update(result="not-applicable", reason=f"3-of-3 needs cpp, lsp and scala; this deployment lacks {', '.join(missing)}")
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        print(f"snapshots: SKIP {report['reason']}")
        return 0
    vs = [Voter(by_runtime[rt]) for rt in VOTERS]
    try:
        run(vs, max(12, args.steps), report)
    except RuntimeError as exc:
        vs[0].check(False, str(exc))
    finally:
        for v in vs:
            v.clean()
    failures = [f for v in vs for f in v.failures]
    if not failures:
        qdrant_leg(vs, args, doc, report, failures)
    for k in ("_memory", "_pre", "_spans"):
        report.pop(k, None)
    report["failures"] = failures
    report["result"] = "pass" if not failures else "fail"
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    for label, d in report.get("digests", {}).items():
        print(f"  digest, {label}: {'equal 3-of-3' if len(set(d.values())) == 1 else d}")
    for src, row in report.get("cross", {}).items():
        print(f"  restore from {src}: " + ", ".join(f"{dst} {'ok' if ok else 'DIFFERS'}" for dst, ok in row.items()))
    for vid, s in report.get("selfVerification", {}).items():
        print(f"  self-verification {vid}: {s}")
    for vid, r in report.get("refusals", {}).items():
        print(f"  refusals {vid}: {r}")
    for vid, n in report.get("nearest", {}).items():
        print(f"  nearest {vid}: {[(i[:8], round(s, 6)) for i, s in n['nearest']] if isinstance(n['nearest'], list) else n['nearest']}")
    if "qdrant" in report:
        q = report["qdrant"]
        print(f"  qdrant: {q.get('result')} {q.get('reason') or json.dumps({k: q.get(k) for k in ('runtimes', 'isolation', 'collectionDeleted')})}")
    for f in failures:
        print(f"  FAIL {f}")
    for why in report["notEvaluated"]:
        print(f"  not evaluated: {why}")
    print(f"snapshots: {report['result'].upper()}")
    return 0 if report["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
