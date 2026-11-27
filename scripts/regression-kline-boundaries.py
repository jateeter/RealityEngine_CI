#!/usr/bin/env python3
"""Stage `kline-boundaries`: both halves of a K-line, 3-of-3 (RealityEngine_CI#603).

SURFACE_SPEC.md "K-lines and runtime snapshots". The boundaries are set by the
corpus, so every voter must open and close the same K-lines, and every PE must
record the same ISRE composition for the same drive. No runtime is a reference
(docs/QUORUM_CONTRACT.md).

On each voter, from its own reset, with `klineCapture` (RE, /api/engine/config)
and `isreCapture` (PE, /api/config) turned on for the stage and restored after:

  stimulus   after the reset, no PE holds a sensor value inside its TTL: a value
             an earlier stage wrote (localAI's broadcast, a HealthKit sample)
             lapses at a different step on each engine, because the voters are
             driven one after another, so the stage waits until every such
             value has expired (at most --sensor-quiesce-s) before it drives;
  drive      --steps pushes through the PE (`POST /api/push`), each observed at
             its completion point (lib/step_observer.py);
  reset      the K-lines open after the drive close `interrupted`
             (`reason: "reset"`) when the pair is reset, every one of them;
  recovery   after a second, shorter drive, capture turned off and on again
             closes what the checkpoint holds `interrupted` (`reason:
             "shutdown"`), as a boot does (SURFACE_SPEC "Controls"); an off
             capture leaves the store untouched;
  schema     every record validates against re-kline/1 and
             re-isre-composition/1 (RealityEngine_Machines schemas/, with its
             ajv), when --machines names a checkout that has them installed;
  corpus     every record agrees with the corpus the universe booted from
             (--corpus, repeatable: its declared files, and localAIStack's
             data/machines for the localai/* machines; a machine no file
             declares, such as localAI's runtime topology machines, against
             its registration, GET /api/machines/:id): the focal sequence is the machine's,
             every path event is one of its events, the path starts at an
             initial event, its steps never decrease, a completed path ends at
             an event with no successors, and `open.step`/`close.step` bound it;
  taxonomy   every composition record names re-source-kinds/2.

Across voters:

  klines       the same K-lines by the parity key (focal, sequence, open.step,
               close.step, outcome, path), and the same records once id,
               instance, lamport, commit, kline and subsumedBy are removed;
  composition  the same records by re.step, on sources (cells, kind, provider,
               class) and folds (source id removed).

Not covered here, and reported as not evaluated: the self-verification replay
(restore `activeBefore`, replay the pairs; no route restores an active list
yet), and a process restart (the toggle above takes the same recovery path).

Usage:
  regression-kline-boundaries.py --registry FILE --out REPORT [--steps N] [--machines DIR] [--corpus DIR]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib import error, parse, request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import re_tls  # noqa: E402
re_tls.install_lane_opener()  # the lane CA and harness certificate when RE_TLS=on (#732)
from followers import voters  # noqa: E402
from reset_contract import reset_pair  # noqa: E402
from step_observer import DEFAULT_WINDOW_MS, StepNotResolved, StepNotRetained, StepObserver  # noqa: E402

VOTERS = ("cpp", "lsp", "scala")
TAXONOMY = "re-source-kinds/2"
STRIPPED = ("id", "instance", "lamport", "commit", "kline", "subsumedBy")
NOT_EVALUATED = [
    "self-verification replay: no route restores a K-line's activeBefore yet (RealityEngine_Machines#222)",
    "process restart: recovery is checked through the capture toggle, which takes the boot's path",
]
VALIDATOR = r"""
import { readFileSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
const [machines, file] = process.argv.slice(2);
const require = createRequire(machines + "/package.json");
const Ajv2020 = require("ajv/dist/2020.js").default ?? require("ajv/dist/2020.js");
const ajv = new Ajv2020({ strict: false, allErrors: true });
for (const f of readdirSync(machines + "/schemas").filter((f) => f.endsWith(".schema.json")))
  ajv.addSchema(JSON.parse(readFileSync(`${machines}/schemas/${f}`, "utf8")));
const base = "https://realityengine.example.org/schemas/";
const out = {};
for (const [kind, records] of Object.entries(JSON.parse(readFileSync(file, "utf8")))) {
  const v = ajv.getSchema(base + kind + ".schema.json");
  if (!v) { out[kind] = { error: "no schema " + kind }; continue; }
  const bad = [];
  for (const r of records) if (!v(r)) bad.push(JSON.stringify(v.errors.slice(0, 2)));
  out[kind] = { valid: records.length - bad.length, invalid: bad.length, first: bad.slice(0, 3) };
}
console.log(JSON.stringify(out));
"""


def http(method: str, url: str, payload: Any = None, timeout: int = 120) -> tuple[int, Any]:
    data = json.dumps(payload).encode() if payload is not None else None
    req = request.Request(url, data=data, method=method,
                          headers={"content-type": "application/json", "accept": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
            status = response.status
    except error.HTTPError as exc:
        raw, status = exc.read(), exc.code
    except Exception as exc:  # noqa: BLE001 -- a dead engine is a result, not a crash
        return 0, str(exc)
    try:
        return status, json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return status, raw.decode("utf-8", "replace")


def strip(x: Any) -> Any:
    if isinstance(x, dict):
        return {k: strip(v) for k, v in x.items() if k not in STRIPPED}
    if isinstance(x, list):
        return [strip(v) for v in x]
    return x


def parity_key(k: dict) -> str:
    return json.dumps([k["focal"]["machine"], k["focal"]["sequence"], k["open"]["step"], k["close"]["step"],
                       k["outcome"], [[p.get("event"), p.get("step")] for p in k.get("path", [])]])


def record_order(k: dict) -> tuple:
    return (k["close"]["step"], k["focal"]["machine"], k["focal"]["sequence"], k["open"]["step"], parity_key(k))


def composition_view(r: dict) -> dict:
    sources = [{k: s.get(k) for k in ("cells", "kind", "provider", "class")} for s in r.get("sources", [])]
    folds = []
    for f in r.get("folds", []):
        f = dict(f)
        f["source"] = {k: v for k, v in (f.get("source") or {}).items() if k != "id"}
        folds.append(f)
    return {"step": r["re"]["step"], "taxonomy": r.get("taxonomy"), "sources": sources, "folds": folds,
            "delta": r.get("delta")}


class Voter:
    def __init__(self, instance: dict, window_ms: int):
        self.id = instance.get("id", instance["runtime"])
        self.runtime = instance["runtime"]
        self.re = instance["re_url"].rstrip("/")
        self.pe = instance["pe_url"].rstrip("/")
        self.failures: list[str] = []
        self.observer = StepObserver(lambda url: http("GET", url), self.re, window_ms)

    def check(self, condition: bool, message: str) -> bool:
        if not condition:
            self.failures.append(f"{self.id}: {message}")
        return condition

    def reset(self) -> None:
        for failure in reset_pair(lambda url, body: http("POST", url, body), self.re, self.pe, self.id):
            self.check(False, failure)
        self.observer.last_step = None

    def capture(self, on: bool) -> None:
        status, body = http("PUT", f"{self.re}/api/engine/config/klineCapture", {"value": on})
        self.check(status == 200, f"PUT klineCapture {on} -> {status} {str(body)[:120]}")
        status, body = http("PATCH", f"{self.pe}/api/config", {"isreCapture": on})
        self.check(status == 200 and isinstance(body, dict) and body.get("isreCapture") is on,
                   f"PATCH /api/config isreCapture {on} -> {status} {str(body)[:120]}")

    def restore(self) -> None:
        http("DELETE", f"{self.re}/api/engine/config/klineCapture")
        http("PATCH", f"{self.pe}/api/config", {"isreCapture": False})

    def commit(self) -> int:
        status, body = http("GET", f"{self.re}/api/engine/clock")
        if status != 200 or not isinstance(body, dict) or not isinstance(body.get("commit"), int):
            raise RuntimeError(f"GET /api/engine/clock -> {status}")
        return body["commit"]

    def drive(self, steps: int) -> int:
        for index in range(steps):
            status, payload = http("POST", f"{self.pe}/api/push", {"compact": True})
            if not self.check(status == 200, f"push {index} -> {status}"):
                return index
            try:
                self.observer.observe_push(payload)
            except (StepNotResolved, StepNotRetained, RuntimeError) as exc:
                self.check(False, f"push {index}: {exc}")
                return index
        for v in self.observer.violations:
            self.check(False, f"exclusivity: {v}")
        return steps

    def registered(self, name: str) -> dict | None:
        """A machine no corpus file declares (localAI's topology machines are built
        at runtime), as this RE registered it: GET /api/machines/:id, in full."""
        if not hasattr(self, "_registered"):
            self._registered: dict[str, dict] = {}
            status, body = http("GET", f"{self.re}/api/machines")
            self._ids = {m.get("name"): m.get("id") for m in (body.get("machines", []) if isinstance(body, dict) else [])}
        if name not in self._registered and self._ids.get(name):
            status, body = http("GET", f"{self.re}/api/machines/{parse.quote(self._ids[name])}")
            if status == 200 and isinstance(body, dict) and isinstance(body.get("machine"), dict):
                self._registered[name] = body["machine"]
        return self._registered.get(name)

    def live_sensor_expiry(self) -> tuple[float, list[str]]:
        """The latest wall-clock ms at which a sensor value this PE holds lapses, and the sensors."""
        status, body = http("GET", f"{self.pe}/api/sources")
        sources = body.get("sources", body) if isinstance(body, dict) else body
        latest, names = 0.0, []
        for src in sources if isinstance(sources, list) else []:
            updated, ttl = src.get("lastUpdated"), src.get("ttlMs")
            if src.get("type") == "sensor" and isinstance(updated, (int, float)) and isinstance(ttl, (int, float)):
                if updated + ttl > time.time() * 1000:
                    latest = max(latest, float(updated + ttl))
                    names.append(src.get("sensorId") or src.get("id") or "?")
        return latest, names

    def open_table(self) -> list[dict]:
        status, body = http("GET", f"{self.re}/api/klines/open")
        self.check(status == 200 and isinstance(body, dict), f"GET /api/klines/open -> {status}")
        return body.get("open", []) if isinstance(body, dict) else []

    def klines(self, since: int) -> list[dict]:
        out, cursor = [], since
        while True:
            status, body = http("GET", f"{self.re}/api/klines?since={cursor}&limit=1000")
            if not self.check(status == 200 and isinstance(body, dict), f"GET /api/klines -> {status}"):
                return out
            out += body.get("klines", [])
            if body.get("next") is None:
                return out
            cursor = body["next"]

    def compositions(self, since: int) -> list[dict]:
        out, cursor = [], since
        while True:
            status, body = http("GET", f"{self.pe}/api/isre-composition?from={cursor}&limit=1000")
            if not self.check(status == 200 and isinstance(body, dict), f"GET /api/isre-composition -> {status}"):
                return out
            out += body.get("records", [])
            if body.get("next") is None:
                return out
            cursor = body["next"]


def load_corpus(roots: list[Path] | None) -> dict[str, dict] | None:
    """The booted corpus by machine name, read from its files: the declared form,
    the same for every voter (machine-set-parity), never an engine's served copy."""
    roots = [r for r in roots or [] if r.is_dir()]
    if not roots:
        return None
    out: dict[str, dict] = {}
    for f in sorted(p for r in roots for p in r.rglob("*.json")):
        try:
            doc = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        m = doc.get("machine") if isinstance(doc, dict) else None
        if isinstance(m, dict) and m.get("name") and isinstance(m.get("sequences"), list):
            out[m["name"]] = m
    return out


def differing_paths(a: Any, b: Any, pre: str = ""):
    """The paths at which A and B differ; list indexes collapsed to []."""
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if a.get(k) != b.get(k):
                yield from differing_paths(a.get(k), b.get(k), f"{pre}.{k}")
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for x, y in zip(a, b):
            if x != y:
                yield from differing_paths(x, y, f"{pre}[]")
    else:
        yield pre or "."


def corpus_check(corpus: dict[str, dict], k: dict, registered=None) -> str | None:
    """Why K-line K disagrees with the corpus, or None. A machine no corpus file
    declares is checked against REGISTERED(name), the engine's registration."""
    m = corpus.get(k["focal"]["machine"])
    if m is None and registered is not None:
        m = registered(k["focal"]["machine"])
    if m is None:
        return f"focal machine {k['focal']['machine']!r} is neither in the corpus nor registered"
    seq = next((s for s in m.get("sequences", []) if s.get("id") == k["focal"]["sequence"]), None)
    if seq is None:
        return f"{k['focal']['machine']!r} has no sequence {k['focal']['sequence']!r}"
    events = {e.get("id"): e for e in seq.get("events", [])}
    path = k.get("path", [])
    if not path:
        return "empty path"
    for p in path:
        if p.get("event") not in events:
            return f"path event {p.get('event')!r} is not in {k['focal']['sequence']!r}"
    if not events[path[0]["event"]].get("isInitial"):
        return f"path starts at {path[0]['event']!r}, not an initial event"
    steps = [p.get("step") for p in path]
    if any(b < a for a, b in zip(steps, steps[1:])):
        return f"path steps decrease: {steps}"
    if steps[0] < k["open"]["step"] or steps[-1] > k["close"]["step"]:
        return f"path steps {steps[0]}..{steps[-1]} outside open {k['open']['step']} .. close {k['close']['step']}"
    if k["outcome"] == "completed" and events[path[-1]["event"]].get("nextEventIds"):
        return f"completed at {path[-1]['event']!r}, which has successors"
    return None


def validate(machines: Path | None, kl: list[dict], comp: list[dict]) -> dict:
    if machines is None or not (machines / "node_modules" / "ajv").is_dir():
        return {"notEvaluated": "no RealityEngine_Machines checkout with ajv installed (--machines)"}
    with tempfile.TemporaryDirectory() as tmp:
        records = Path(tmp) / "records.json"
        records.write_text(json.dumps({"re-kline": kl, "re-isre-composition": comp}))
        script = Path(tmp) / "validate.mjs"
        script.write_text(VALIDATOR)
        done = subprocess.run(["node", str(script), str(machines), str(records)],
                              capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        return {"error": done.stderr.strip()[-400:]}
    return json.loads(done.stdout)


def quiesce(voters_: list[Voter], limit_s: float) -> dict:
    """Wait until no PE holds a live sensor value, so every voter is driven alike."""
    deadline = time.time() + limit_s
    waited: dict[str, list[str]] = {}
    while True:
        live = {v.id: v.live_sensor_expiry() for v in voters_}
        for vid, (_, names) in live.items():
            if names:
                waited.setdefault(vid, sorted(set(names)))
        latest = max(t for t, _ in live.values())
        if latest == 0.0:
            return {"waitedFor": waited, "quiet": True}
        if latest / 1000 > deadline:
            for v in voters_:
                v.check(not live[v.id][1], f"stimulus: sensor value(s) {live[v.id][1]} stay live past "
                                           f"--sensor-quiesce-s {limit_s:g}; the voters would be driven unequally")
            return {"waitedFor": waited, "quiet": False}
        time.sleep(min(5.0, max(0.25, latest / 1000 - time.time() + 0.25)))


def run(voters_: list[Voter], steps: int, machines: Path | None, corpus: dict[str, dict] | None,
        quiesce_s: float = 120.0) -> dict:
    report: dict[str, Any] = {"runtimes": {}, "corpusMachines": len(corpus) if corpus is not None else None}
    for v in voters_:
        v.capture(True)
        v.reset()
    report["stimulus"] = quiesce(voters_, quiesce_s)
    since = {v.id: v.commit() + 1 for v in voters_}

    # The drive, then a reset with K-lines open.
    for v in voters_:
        v.drive(steps)
    open_at_reset = {v.id: v.open_table() for v in voters_}
    for v in voters_:
        v.reset()

    # A shorter drive, then the checkpoint closed by the capture toggle.
    for v in voters_:
        v.drive(max(4, steps // 4))
    open_at_toggle = {v.id: v.open_table() for v in voters_}
    for v in voters_:
        status, _ = http("PUT", f"{v.re}/api/engine/config/klineCapture", {"value": False})
        v.check(status == 200, f"PUT klineCapture false -> {status}")
    stored_off = {v.id: len(v.klines(since[v.id])) for v in voters_}
    for v in voters_:
        http("POST", f"{v.pe}/api/push", {"compact": True})  # one step with capture off
        v.observer.last_step = None
    for v in voters_:
        v.check(len(v.klines(since[v.id])) == stored_off[v.id], "capture off still wrote K-lines")
        status, _ = http("PUT", f"{v.re}/api/engine/config/klineCapture", {"value": True})
        v.check(status == 200, f"PUT klineCapture true -> {status}")

    views: dict[str, list] = {}
    comps: dict[str, list] = {}
    keys: dict[str, list] = {}
    for v in voters_:
        kl = sorted(v.klines(since[v.id]), key=record_order)
        comp = sorted(v.compositions(since[v.id]), key=lambda r: (r["re"]["commit"]))
        by_reason = {}
        for k in kl:
            if k["outcome"] == "interrupted":
                by_reason.setdefault(k.get("reason"), []).append(k)
        # Reset: every K-line open after the drive closed interrupted/reset.
        opened = sorted((o["focal"]["machine"], o["focal"]["sequence"], o["open"]["step"]) for o in open_at_reset[v.id])
        reset_closed = sorted((k["focal"]["machine"], k["focal"]["sequence"], k["open"]["step"])
                              for k in by_reason.get("reset", []))
        v.check(opened == reset_closed,
                f"reset closed {len(reset_closed)} K-lines interrupted/reset; {len(opened)} were open")
        toggled = sorted((o["focal"]["machine"], o["focal"]["sequence"], o["open"]["step"]) for o in open_at_toggle[v.id])
        shut = sorted((k["focal"]["machine"], k["focal"]["sequence"], k["open"]["step"])
                      for k in by_reason.get("shutdown", []))
        v.check(toggled == shut,
                f"capture on closed {len(shut)} K-lines interrupted/shutdown; the checkpoint held {len(toggled)}")
        bad = [(k["focal"], why) for k in kl for why in [corpus_check(corpus, k, v.registered)] if why] \
            if corpus is not None else []
        by_registration = sum(1 for k in kl if corpus is not None and k["focal"]["machine"] not in corpus)
        for focal, why in bad[:5]:
            v.check(False, f"corpus: {focal['machine']}/{focal['sequence']}: {why}")
        v.check(not bad, f"corpus: {len(bad)} K-line(s) disagree with the booted corpus")
        wrong = [r for r in comp if r.get("taxonomy") != TAXONOMY]
        v.check(not wrong, f"{len(wrong)} composition record(s) do not name {TAXONOMY}")
        v.check(len(comp) > 0, "no composition records")
        v.check(len(kl) > 0, "no K-lines")
        schema = validate(machines, kl, comp)
        for kind, res in schema.items():
            if isinstance(res, dict) and res.get("invalid"):
                v.check(False, f"schema {kind}: {res['invalid']} invalid, first {res['first'][:1]}")
            if isinstance(res, dict) and res.get("error"):
                v.check(False, f"schema {kind}: {res['error']}")
        views[v.runtime] = [strip(k) for k in kl]
        keys[v.runtime] = [parity_key(k) for k in kl]
        comps[v.runtime] = [composition_view(r) for r in comp]
        outcomes: dict[str, int] = {}
        for k in kl:
            label = k["outcome"] + (f"/{k['reason']}" if k.get("reason") else "")
            outcomes[label] = outcomes.get(label, 0) + 1
        report["runtimes"][v.id] = {"klines": len(kl), "outcomes": outcomes, "compositions": len(comp),
                                    "checkedAgainstRegistration": by_registration,
                                    "openAtReset": len(opened), "openAtToggle": len(toggled),
                                    "schema": schema, "failures": v.failures}

    base = VOTERS[0]
    agreement: dict[str, Any] = {}
    for rt in VOTERS[1:]:
        key_diff = sorted(set(keys[base]) ^ set(keys[rt]))
        rec_diff = sum(1 for a, b in zip(views[base], views[rt]) if a != b) + abs(len(views[base]) - len(views[rt]))
        comp_diff = sum(1 for a, b in zip(comps[base], comps[rt]) if a != b) + abs(len(comps[base]) - len(comps[rt]))
        first_records = [{"focal": a.get("focal"), "open": (a.get("open") or {}).get("step"),
                          "paths": sorted(set(differing_paths(a, b)))[:4]}
                         for a, b in zip(views[base], views[rt]) if a != b][:3]
        first_comps = [{"step": a["step"], "paths": sorted(set(differing_paths(a, b)))[:4]}
                       for a, b in zip(comps[base], comps[rt]) if a != b][:3]
        agreement[f"{base}-{rt}"] = {"parityKeyDiffer": len(key_diff), "recordsDiffer": rec_diff,
                                     "compositionsDiffer": comp_diff, "firstKeys": key_diff[:3],
                                     "firstRecords": first_records, "firstCompositions": first_comps}
    report["agreement"] = agreement
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--steps", type=int, default=120)
    parser.add_argument("--machines", type=Path, help="a RealityEngine_Machines checkout with node_modules (schemas)")
    parser.add_argument("--corpus", type=Path, action="append",
                        help="a machines/ directory the universe loaded from; repeat for each root")
    parser.add_argument("--sensor-quiesce-s", type=float, default=120.0,
                        help="how long to wait for live sensor values to lapse before the drive")
    parser.add_argument("--step-window-ms", type=int, default=DEFAULT_WINDOW_MS)
    args = parser.parse_args()

    document = json.loads(args.registry.read_text(encoding="utf-8"))
    by_runtime: dict[str, dict] = {}
    for i in voters(document.get("instances", [])):
        rt = i.get("runtime")
        if rt in VOTERS and rt not in by_runtime and i.get("re_url") and i.get("pe_url"):
            by_runtime[rt] = i
    missing = [rt for rt in VOTERS if rt not in by_runtime]
    report: dict[str, Any] = {"stage": "kline-boundaries", "issue": "RealityEngine_CI#603", "steps": args.steps,
                              "notEvaluated": NOT_EVALUATED}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    if missing:
        report["result"] = "not-applicable"
        report["reason"] = f"3-of-3 needs cpp, lsp and scala; this deployment lacks {', '.join(missing)}"
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        print(f"kline-boundaries: SKIP {report['reason']}")
        return 0

    vs = [Voter(by_runtime[rt], args.step_window_ms) for rt in VOTERS]
    try:
        corpus = load_corpus(args.corpus)
        if corpus is None:
            report["notEvaluated"] = NOT_EVALUATED + ["corpus: no --corpus directory"]
        report.update(run(vs, args.steps, args.machines, corpus, args.sensor_quiesce_s))
    finally:
        for v in vs:
            v.restore()
    failures = [f for v in vs for f in v.failures]
    for pair, a in report.get("agreement", {}).items():
        if a["parityKeyDiffer"] or a["recordsDiffer"] or a["compositionsDiffer"]:
            failures.append(f"{pair}: {a['parityKeyDiffer']} parity keys, {a['recordsDiffer']} K-line records, "
                            f"{a['compositionsDiffer']} composition records differ")
    report["failures"] = failures
    report["result"] = "pass" if not failures else "fail"
    args.out.write_text(json.dumps(report, indent=2) + "\n")

    for rid, r in report.get("runtimes", {}).items():
        print(f"  {rid:8} klines={r['klines']} {r['outcomes']} compositions={r['compositions']} "
              f"openAtReset={r['openAtReset']} openAtToggle={r['openAtToggle']}")
    if report.get("stimulus", {}).get("waitedFor"):
        print(f"  stimulus: waited for live sensor values to lapse: {report['stimulus']['waitedFor']}")
    for pair, a in report.get("agreement", {}).items():
        print(f"  {pair}: parity keys {a['parityKeyDiffer']}, records {a['recordsDiffer']}, "
              f"compositions {a['compositionsDiffer']} differ")
        for d in a.get("firstRecords", []) + a.get("firstCompositions", []):
            print(f"    e.g. {d}")
    for f in failures:
        print(f"  FAIL {f}")
    for why in report["notEvaluated"]:
        print(f"  not evaluated: {why}")
    print(f"kline-boundaries: {report['result'].upper()}")
    return 0 if report["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
