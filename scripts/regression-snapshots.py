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

The stage deletes every snapshot it made and resets every voter when it ends.

Not evaluated here: RE_SNAPSHOT_STORE=off (each engine's unit tests cover the
store's modes; a store-off engine is a boot setting, not a stage drive).

Usage:
  regression-snapshots.py --registry FILE --out REPORT [--steps N]
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path
from typing import Any
from urllib import error, request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import re_tls  # noqa: E402
re_tls.install_lane_opener()  # the lane CA and harness certificate when RE_TLS=on (#732)
from followers import voters  # noqa: E402
from reset_contract import reset_pair  # noqa: E402

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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--registry", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--steps", type=int, default=30)
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
    for f in failures:
        print(f"  FAIL {f}")
    for why in NOT_EVALUATED:
        print(f"  not evaluated: {why}")
    print(f"snapshots: {report['result'].upper()}")
    return 0 if report["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
