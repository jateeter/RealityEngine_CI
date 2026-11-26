#!/usr/bin/env python3
"""Stage `clock-causality`: the full Lamport clock, 3-of-3 (RealityEngine_CI#600).

SURFACE_SPEC.md "The instance clock". Every voter instance is two participants,
its RE (`GET /api/engine/clock`) and its PE (`GET /api/clock`). Those routes
report the clock at the participant's last committed step; its current lamport
is the one each response carries in `RE-Clock`. On each participant:

  monotonic    the committed lamport and commit never decrease, lamport >= commit,
               and each request moves the response's lamport by at least 2
               (a receive, then a send);
  receive      a presented `RE-Clock` 10^6 ahead moves the participant past it on
               the next event, and its persisted mark covers it: the
               `<uuid>.lamport` high-water mark is past the injection, so a
               restart can never reissue a tick at or below it;
  malformed    four malformed headers each get 400
               {"error": "malformed RE-Clock header"}, each still a receive
               that carries `RE-Clock`;

and on each PE:

  causedBy     a completion naming a dispatch record still in the ledger has
               that record's clock as `causedBy`, and a clock of its own, later;
               with no record, a well-formed echo is kept and a malformed one
               becomes null (the completion still commits, 200).

Each runtime's results are reduced to a signature, and the signatures must be
identical across cpp, lsp and scala and every check must hold
(docs/QUORUM_CONTRACT.md: no reference member). A check one runtime cannot
take part in is "not-evaluable" with its reason, never agreement.

and, with --localai-url, on localAI (localAIStack#140):

  localai      one broadcast (`POST /rag/retrieve`, no LLM) is one origin event
               of localAI's clock; its writes reach every voter after the
               origin, and each engine answers past `sent + 1` (its receive,
               then its send), read from localAI's `engine_parity.causal`. A
               localAI that reports no `clock` on `/health` predates #140 and
               is "not-evaluable", as is a run without localAI.

Where the marks are:
  --clock-dir DIR       a native lane's INSTANCE_CLOCK_DIR (default: what
                        scripts/lib/instance_uuids.py clock-dir prints);
  --clock-volume NAME   a containerized lane's clock volume, read with
                        `docker exec` in a running container that mounts it, at
                        --clock-mount (default /var/lib/reality-engine/clock).

Usage:
  regression-clock-causality.py --registry FILE --out REPORT [--clock-dir DIR | --clock-volume NAME]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any
from urllib import error, request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import re_tls  # noqa: E402
re_tls.install_lane_opener()  # the lane CA and harness certificate when RE_TLS=on (#732)
from followers import voters  # noqa: E402

CI_DIR = Path(__file__).resolve().parents[1]
VOTERS = ("cpp", "lsp", "scala")
JUMP = 1_000_000
HEADER = re.compile(r"^instance=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}); lamport=(\d+)$")
MALFORMED = (
    "instance=not-a-uuid; lamport=1",
    "instance={u}",
    "instance={u}; lamport=-1",
    "instance={U}; lamport=1",
)
ERROR_BODY = {"error": "malformed RE-Clock header"}
NOT_EVALUABLE_LOCALAI = "no --localai-url: localAI's fan-out received + 1 was not checked"


class Reply:
    def __init__(self, status: int, body: Any, clock_header: str | None):
        self.status, self.body, self.clock_header = status, body, clock_header

    def lamport(self) -> int | None:
        m = HEADER.match(self.clock_header or "")
        return int(m.group(2)) if m else None

    def instance(self) -> str | None:
        m = HEADER.match(self.clock_header or "")
        return m.group(1) if m else None


def call(method: str, url: str, payload: Any = None, clock: str | None = None, timeout: int = 30) -> Reply:
    headers = {"accept": "application/json"}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["content-type"] = "application/json"
    if clock is not None:
        headers["RE-Clock"] = clock
    req = request.Request(url, data=data, method=method, headers=headers)
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            status, raw, h = resp.status, resp.read(), resp.headers.get("RE-Clock")
    except error.HTTPError as exc:
        status, raw, h = exc.code, exc.read(), exc.headers.get("RE-Clock")
    except Exception as exc:  # noqa: BLE001 -- a dead participant is a result, not a crash
        return Reply(0, str(exc), None)
    try:
        body: Any = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        body = raw.decode("utf-8", "replace")
    return Reply(status, body, h)


def presented(lamport: int) -> str:
    return f"instance={uuid.uuid4()}; lamport={lamport}"


class Marks:
    """Reads a participant's persisted `<uuid>.lamport` high-water mark."""

    def __init__(self, clock_dir: Path | None, volume: str | None, mount: str):
        self.clock_dir, self.volume, self.mount = clock_dir, volume, mount
        self._container: str | None = None

    def where(self) -> str:
        return f"volume {self.volume}" if self.volume else f"{self.clock_dir}"

    def lamport_mark(self, participant: str) -> tuple[int | None, str]:
        name = f"{participant}.lamport"
        if self.volume:
            if self._container is None:
                ps = subprocess.run(["docker", "ps", "--filter", f"volume={self.volume}", "--format", "{{.Names}}"],
                                    capture_output=True, text=True)
                names = ps.stdout.split()
                if not names:
                    return None, f"no running container mounts {self.volume}"
                self._container = names[0]
            r = subprocess.run(["docker", "exec", self._container, "cat", f"{self.mount}/{name}"],
                               capture_output=True, text=True)
            text, why = r.stdout, (r.stderr.strip() or f"exit {r.returncode}")
            if r.returncode != 0:
                return None, f"{self._container}:{self.mount}/{name}: {why}"
        else:
            path = (self.clock_dir or Path()) / name
            try:
                text = path.read_text()
            except OSError as exc:
                return None, f"{path}: {exc.strerror}"
        try:
            return int(text.strip()), ""
        except ValueError:
            return None, f"{name}: not an integer: {text[:40]!r}"


def check_participant(url: str, path: str, marks: Marks) -> dict[str, Any]:
    """The three clock checks on one participant; each is pass/fail with detail."""
    out: dict[str, Any] = {}
    target = f"{url}{path}"

    # monotonic
    a, b = call("GET", target), call("GET", target)
    problems = []
    for label, r in (("first", a), ("second", b)):
        if r.status != 200 or not isinstance(r.body, dict):
            problems.append(f"{label} GET {path}: HTTP {r.status}")
    if not problems:
        ca, cb = a.body, b.body
        if not all(isinstance(c.get(k), int) for c in (ca, cb) for k in ("lamport", "commit", "step")):
            problems.append(f"clock fields not integers: {ca}")
        else:
            if cb["lamport"] < ca["lamport"] or cb["commit"] < ca["commit"]:
                problems.append(f"committed clock went back: {ca} -> {cb}")
            if cb["lamport"] < cb["commit"]:
                problems.append(f"lamport {cb['lamport']} < commit {cb['commit']}")
            if cb["step"] < -1:
                problems.append(f"step {cb['step']} < -1")
        la, lb = a.lamport(), b.lamport()
        if la is None or lb is None:
            problems.append(f"response RE-Clock missing or malformed: {a.clock_header!r}, {b.clock_header!r}")
        elif lb < la + 2:
            problems.append(f"response lamport {la} -> {lb}: a request moves it by at least 2")
        if a.instance() and isinstance(ca, dict) and a.instance() != ca.get("instance"):
            problems.append(f"RE-Clock instance {a.instance()} is not the body's {ca.get('instance')}")
    out["monotonic"] = {"pass": not problems, "detail": problems}

    # receive, and the persisted mark
    problems = []
    instance = b.body.get("instance") if isinstance(b.body, dict) else None
    base = b.lamport() or 0
    injected = base + JUMP
    r = call("GET", target, clock=presented(injected))
    if r.status != 200:
        problems.append(f"GET {path} with RE-Clock lamport={injected}: HTTP {r.status}")
    if (r.lamport() or 0) <= injected:
        problems.append(f"reply lamport {r.lamport()} is not past the injection {injected}")
    nxt = call("GET", target)
    if (nxt.lamport() or 0) <= injected:
        problems.append(f"next event's lamport {nxt.lamport()} is not past the injection {injected}")
    mark_note = ""
    if instance:
        mark, why = marks.lamport_mark(instance)
        if mark is None:
            problems.append(f"persisted mark unreadable ({why})")
        elif mark <= injected:
            problems.append(f"persisted mark {mark} does not cover the injection {injected}")
        else:
            mark_note = f"mark {mark} > injected {injected}"
    else:
        problems.append("no instance in the clock body")
    out["receive"] = {"pass": not problems, "detail": problems or [mark_note]}

    # malformed
    problems = []
    u = str(uuid.uuid4())
    last = nxt.lamport() or 0
    for template in MALFORMED:
        value = template.format(u=u, U=u.upper())
        r = call("GET", target, clock=value)
        if r.status != 400 or r.body != ERROR_BODY:
            problems.append(f"RE-Clock {value!r}: HTTP {r.status} {str(r.body)[:80]}")
        now = r.lamport()
        if now is None:
            problems.append(f"RE-Clock {value!r}: the 400 carries no RE-Clock")
        elif now < last + 2:
            problems.append(f"RE-Clock {value!r}: lamport {last} -> {now}, a refused request is still a receive")
        else:
            last = now
    out["malformed"] = {"pass": not problems, "detail": problems}
    return out


def check_caused_by(pe: str, runtime: str) -> dict[str, Any]:
    """Completion causedBy: the ledger record wins; else the echo; else null."""
    problems: list[str] = []
    notes: list[str] = []
    sensor = f"clock-causality.{runtime}"
    base = {"provider": "clock-causality", "agent": "causedby", "sensorId": sensor,
            "region": {"offset": 4200, "length": 1}, "values": [1], "ttlMs": 60000}

    def complete(extra: dict[str, Any]) -> Reply:
        r = call("POST", f"{pe}/api/integrations/completions", {**base, **extra})
        call("DELETE", f"{pe}/api/sources/{sensor}")
        return r

    ledger = call("GET", f"{pe}/api/dispatch/ledger")
    records = (ledger.body or {}).get("records") if isinstance(ledger.body, dict) else None
    record = next((x for x in (records or []) if isinstance(x, dict) and isinstance(x.get("clock"), dict)), None)
    dispatch_path = "not-evaluable"
    if record:
        r = complete({"dispatchId": record["id"]})
        c = (r.body or {}).get("completion", {}) if isinstance(r.body, dict) else {}
        rc = {"instance": record["clock"].get("instance"), "lamport": record["clock"].get("lamport")}
        if r.status != 200:
            problems.append(f"completion with dispatchId: HTTP {r.status}")
        if c.get("causedBy") != rc:
            problems.append(f"causedBy {c.get('causedBy')} is not the record's clock {rc}")
        own = c.get("clock") or {}
        if own.get("instance") != rc["instance"] or not (own.get("lamport") or 0) > (rc["lamport"] or 0):
            problems.append(f"completion clock {own} is not the PE's, later than {rc}")
        dispatch_path = "evaluated"
    else:
        notes.append("dispatch path not evaluable: the ledger holds no record with a clock")

    echo = {"instance": str(uuid.uuid4()), "lamport": 42}
    r = complete({"causedBy": echo})
    c = (r.body or {}).get("completion", {}) if isinstance(r.body, dict) else {}
    if r.status != 200 or c.get("causedBy") != echo:
        problems.append(f"well-formed echo: HTTP {r.status}, causedBy {c.get('causedBy')} (expected {echo})")
    r = complete({"causedBy": {"instance": "NOT-A-UUID", "lamport": -1}})
    c = (r.body or {}).get("completion", {}) if isinstance(r.body, dict) else {}
    if r.status != 200 or c.get("causedBy") is not None:
        problems.append(f"malformed echo: HTTP {r.status}, causedBy {c.get('causedBy')} (expected null, 200)")
    return {"pass": not problems, "dispatchPath": dispatch_path, "detail": problems or notes}


def check_localai(base: str, voter_ids: dict[str, str]) -> dict[str, Any]:
    """One broadcast from localAI; every voter answers each of its writes past sent + 1."""
    health = call("GET", f"{base}/health", timeout=60)
    if health.status != 200 or not isinstance(health.body, dict):
        return {"verdict": "not-evaluable", "detail": [f"localAI /health: HTTP {health.status}"]}
    if not isinstance(health.body.get("clock"), dict):
        return {"verdict": "not-evaluable", "detail": ["localAI reports no clock: it predates localAIStack#140"]}
    before = len((health.body.get("engine_parity") or {}).get("causal") or [])
    r = call("POST", f"{base}/rag/retrieve", {"question": "clock causality: resting heart rate"}, timeout=120)
    if r.status != 200:
        return {"verdict": "fail", "detail": [f"POST /rag/retrieve: HTTP {r.status} {str(r.body)[:120]}"]}
    after = call("GET", f"{base}/health", timeout=60)
    causal = ((after.body or {}).get("engine_parity") or {}).get("causal") or [] if isinstance(after.body, dict) else []
    if len(causal) <= min(before, 9):
        return {"verdict": "fail", "detail": ["the broadcast recorded no origin in engine_parity.causal"]}
    record = causal[-1]
    origin = (record.get("origin") or {}).get("lamport") or 0
    problems: list[str] = []
    per_engine: dict[str, list[str]] = {}
    for rt, rid in voter_ids.items():
        sends = [x for x in record.get("sends", []) if x.get("engine") == rid]
        if not sends:
            problems.append(f"{rid}: no write in the broadcast")
        for x in sends:
            reply = (x.get("reply") or {}).get("lamport")
            per_engine.setdefault(rt, []).append("ok" if reply is not None and reply >= (x.get("sent") or 0) + 2 else "short")
            if not (x.get("sent") or 0) > origin:
                problems.append(f"{rid}: sent {x.get('sent')} does not follow the origin {origin}")
            if reply is None or reply < (x.get("sent") or 0) + 2:
                problems.append(f"{rid}: reply {reply} is not past sent {x.get('sent')} + 1")
    return {"verdict": "pass" if not problems else "fail", "origin": record.get("origin"),
            "perEngine": per_engine, "detail": problems}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--clock-dir", type=Path)
    parser.add_argument("--clock-volume")
    parser.add_argument("--clock-mount", default="/var/lib/reality-engine/clock")
    parser.add_argument("--localai-url", help="localAI's base URL; omitted, its check is not evaluated")
    args = parser.parse_args()

    clock_dir = args.clock_dir
    if not args.clock_volume and clock_dir is None:
        clock_dir = Path(subprocess.run([sys.executable, str(CI_DIR / "scripts/lib/instance_uuids.py"), "clock-dir"],
                                        capture_output=True, text=True, check=True).stdout.strip())
    marks = Marks(clock_dir, args.clock_volume, args.clock_mount)

    document = json.loads(args.registry.read_text(encoding="utf-8"))
    by_runtime: dict[str, dict[str, str]] = {}
    for i in voters(document.get("instances", [])):
        rt = i.get("runtime")
        if rt in VOTERS and rt not in by_runtime and i.get("re_url") and i.get("pe_url"):
            by_runtime[rt] = {"id": i.get("id", rt), "re": i["re_url"].rstrip("/"), "pe": i["pe_url"].rstrip("/")}
    missing = [rt for rt in VOTERS if rt not in by_runtime]

    report: dict[str, Any] = {"stage": "clock-causality", "issue": "RealityEngine_CI#600",
                              "marks": marks.where(), "runtimes": {},
                              "notEvaluable": [] if args.localai_url else [NOT_EVALUABLE_LOCALAI]}
    if missing:
        report["result"] = "not-applicable"
        report["reason"] = f"3-of-3 needs cpp, lsp and scala; this deployment lacks {', '.join(missing)}"
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        print(f"clock-causality: SKIP {report['reason']}")
        return 0

    signatures: dict[str, str] = {}
    for rt in VOTERS:
        inst = by_runtime[rt]
        result = {
            "re": check_participant(inst["re"], "/api/engine/clock", marks),
            "pe": check_participant(inst["pe"], "/api/clock", marks),
            "causedBy": check_caused_by(inst["pe"], rt),
        }
        report["runtimes"][inst["id"]] = result
        signatures[rt] = json.dumps({
            "re": {k: v["pass"] for k, v in result["re"].items()},
            "pe": {k: v["pass"] for k, v in result["pe"].items()},
            "causedBy": [result["causedBy"]["pass"], result["causedBy"]["dispatchPath"]],
        }, sort_keys=True)

    if args.localai_url:
        localai = check_localai(args.localai_url.rstrip("/"), {rt: by_runtime[rt]["id"] for rt in VOTERS})
        report["localai"] = localai
        if localai["verdict"] == "not-evaluable":
            report["notEvaluable"].append("; ".join(localai["detail"]))

    unanimous = len(set(signatures.values())) == 1
    failures = [f"{rid} {half} {check}: {'; '.join(v['detail'])}"
                for rid, r in report["runtimes"].items()
                for half in ("re", "pe") for check, v in r[half].items() if not v["pass"]]
    failures += [f"{rid} causedBy: {'; '.join(r['causedBy']['detail'])}"
                 for rid, r in report["runtimes"].items() if not r["causedBy"]["pass"]]
    if report.get("localai", {}).get("verdict") == "fail":
        failures.append(f"localai: {'; '.join(report['localai']['detail'])}")
    report["signatures"] = signatures
    report["unanimous"] = unanimous
    report["failures"] = failures
    report["result"] = "pass" if unanimous and not failures else "fail"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")

    for rid, r in report["runtimes"].items():
        cells = [f"{half}.{c}={'ok' if v['pass'] else 'FAIL'}" for half in ("re", "pe") for c, v in r[half].items()]
        cells.append(f"causedBy={'ok' if r['causedBy']['pass'] else 'FAIL'} ({r['causedBy']['dispatchPath']} dispatch)")
        print(f"  {rid:8} " + " ".join(cells))
    if not unanimous:
        print("clock-causality: disagreement (3-of-3, no reference member)")
        for rt, sig in signatures.items():
            print(f"  {rt:5} {sig}")
    for f in failures:
        print(f"  FAIL {f}")
    if "localai" in report:
        print(f"  localai   {report['localai']['verdict']} {report['localai'].get('perEngine', '')}")
    for why in report["notEvaluable"]:
        print(f"  not evaluable: {why}")
    print(f"clock-causality: {report['result'].upper()}")
    return 0 if report["result"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
