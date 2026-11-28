#!/usr/bin/env python3
"""Sandboxed learning deployment: a replica seeded from near-miss K-lines (RealityEngine_CI#605, #603).

Owner decision (2026-10-24): keep abandoned K-lines (near-misses) and prepare them
as context for a sandboxed replica of an instance, used for experimentation.

  export   the source's near-misses: `POST /api/klines/export` of its abandoned
           K-lines and the completed ones of the same focal machines, as one
           re-kline-bundle/1 file
  up       boot a replica of the source's runtime: a new instance (a `sandbox`
           lane UUID, never the source's) with its own state directory, store,
           instance registry and port; the same corpus, refused on a fingerprint
           mismatch; the bundle's controls; the bundle imported read-only under
           klines/<replica uuid>/imported/<source uuid>/
  replay   re-establish near-misses on the replica: restore each K-line's
           activeBefore for its scope (a narrowed snapshot built from the
           record), present its ISRE pairs, check the OSREs reproduce, then
           present them again with the failing cell varied. The replica records
           the K-lines that result in its own store, and each experiment is
           appended to experiments.jsonl beside it, linking the imported K-line
           to the replica's
  down     stop the replica; its state directory and results stay

Isolation: the replica is an RE only, so no PE, no MQTT bridge, no HealthKit, ACP,
MCP or localAI path reaches it, and none of their variables are passed to it. It
never writes to the source: the source is read only through its own export, and
the replica's registry is a sandbox registry (RE_REGISTRY_SANDBOX=1), refused by
every production one. TLS lane only (RE_TLS=on): a replica is never plaintext.

State: $RE_INSTANCE_STATE_DIR/sandbox/<name>/ (default ~/.reality-engine/sandbox/<name>/):
replica.json, registry.json, klines/, isre/, replica.log, experiments.jsonl.

Usage:
  sandbox.py export --registry FILE|URL --from ID --out BUNDLE
  sandbox.py up     --registry FILE|URL --from ID --bundle BUNDLE --corpus DIR [--repo DIR] [--name NAME]
  sandbox.py replay --name NAME [--kline ID ...] [--sample N] [--vary CELL=VALUE]
  sandbox.py down   --name NAME
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib import error, parse, request

LIB = Path(__file__).resolve().parent / "lib"
sys.path.insert(0, str(LIB))
import instance_uuids  # noqa: E402
import jcs  # noqa: E402
import kline_archive  # noqa: E402
import kline_restart  # noqa: E402

CI = Path(__file__).resolve().parents[1]
# A replica is wired to nothing live: none of these reach it.
PROVIDER_ENV = ("MQTT_", "ACP_", "OPENCLAW_", "LOCAL_AI", "LOCALAI", "HEALTHKIT", "CAREKIT", "INTEGRATIONS_CONFIG",
                "OLLAMA", "OPENAI", "MCP_", "RE_REGISTRY_URL")


def http(method: str, url: str, payload: Any = None, timeout: int = 120) -> tuple[int, Any]:
    data = json.dumps(payload).encode() if payload is not None else None
    req = request.Request(url, data=data, method=method, headers={"content-type": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout) as r:
            raw, status = r.read(), r.status
    except error.HTTPError as exc:
        raw, status = exc.read(), exc.code
    except Exception as exc:  # noqa: BLE001 -- an unreachable engine is a result
        return 0, str(exc)
    try:
        return status, json.loads(raw) if raw else None
    except (json.JSONDecodeError, UnicodeDecodeError):
        return status, raw.decode("utf-8", "replace")


def state_root() -> Path:
    return Path(os.environ.get("RE_INSTANCE_STATE_DIR") or Path.home() / ".reality-engine") / "sandbox"


def state_of(name: str) -> Path:
    return state_root() / name


def load_registry(source: str) -> dict:
    if parse.urlsplit(source).scheme in ("https", "http"):
        return http("GET", source)[1]
    return json.loads(Path(source).read_text(encoding="utf-8"))


def instance_of(registry: dict, iid: str) -> dict:
    for i in registry.get("instances", []):
        if i.get("id") == iid:
            return i
    raise SystemExit(f"no instance {iid} in the instance registry")


def read_bundle(path: Path) -> tuple[dict, list[dict]]:
    header, body = kline_archive.verified(path.read_text(encoding="utf-8"), "re-kline-bundle/1")
    return header, [json.loads(line) for line in body.split("\n") if line]


# ── export ───────────────────────────────────────────────────────────────────

def cmd_export(args: argparse.Namespace) -> int:
    import re_tls  # noqa: E402 -- the lane CA and harness certificate when RE_TLS=on
    re_tls.install_lane_opener()
    inst = instance_of(load_registry(args.registry), args.source)
    re_url = inst["re_url"].rstrip("/")
    # The focal machines that came close and failed, then their abandoned and completed K-lines in one bundle.
    machines: set[str] = set()
    cursor: Any = 0
    while cursor is not None:
        status, page = http("GET", f"{re_url}/api/klines?outcome=abandoned&since={cursor}&limit=1000")
        if status != 200:
            raise SystemExit(f"GET /api/klines -> {status}")
        machines |= {k["focal"]["machine"] for k in page.get("klines", [])}
        cursor = page.get("next")
    if not machines:
        raise SystemExit(f"{args.source} holds no abandoned K-line to export")
    req = request.Request(f"{re_url}/api/klines/export", method="POST",
                          data=json.dumps({"outcome": ["abandoned", "completed"], "machines": sorted(machines)}).encode(),
                          headers={"content-type": "application/json"})
    with request.urlopen(req, timeout=300) as r:
        text = r.read().decode("utf-8")
    header, _ = kline_archive.verified(text, "re-kline-bundle/1")
    Path(args.out).write_text(text, encoding="utf-8")
    print(json.dumps({"bundle": args.out, "source": header["source"], "count": header["count"],
                      "machines": len(machines), "sha256": header["sha256"]}))
    return 0


# ── up ───────────────────────────────────────────────────────────────────────

def cmd_up(args: argparse.Namespace) -> int:
    if os.environ.get("RE_TLS", "off") != "on":
        raise SystemExit("a replica runs on the TLS lane only (RE_TLS=on); it is never plaintext")
    import re_tls  # noqa: E402
    re_tls.install_lane_opener()
    source = instance_of(load_registry(args.registry), args.source)
    header, records = read_bundle(Path(args.bundle))
    src_uuid = str(header["source"]["instance"]).lower()
    if src_uuid != str(source.get("instance_uuid", "")).lower():
        raise SystemExit(f"the bundle came from {src_uuid}, not {args.source} ({source.get('instance_uuid')})")
    runtime = source["runtime"]
    name = args.name or f"{args.source}-{header['sha256'][:8]}"
    state = state_of(name)
    if (state / "replica.json").exists():
        raise SystemExit(f"replica {name} exists ({state}); `sandbox.py down --name {name}` first, or name another")
    state.mkdir(parents=True, exist_ok=True)
    repo = Path(args.repo) if args.repo else CI.parent / {"cpp": "RealityEngine_CPP", "lsp": "RealityEngine_LSP",
                                                          "scala": "RealityEngine_Scala"}[runtime]
    # No replica of a stale artifact (scripts/verify-build-provenance.py, as startUniverse.sh
    # checks before a spawn). An explicit --repo is the caller's to vouch for: the
    # regression harness checks its own worktrees. Override: RE_SKIP_PROVENANCE=1.
    if not args.repo and os.environ.get("RE_SKIP_PROVENANCE") != "1":
        gate = subprocess.run([sys.executable, str(CI / "scripts" / "verify-build-provenance.py"), "--repos", runtime,
                               "--lane", os.environ.get("RE_PROVENANCE_LANE", "local")])
        if gate.returncode != 0:
            shutil.rmtree(state, ignore_errors=True)
            raise SystemExit(f"engine build provenance failed for {repo}: rebuild it, pass --repo, "
                             "or set RE_SKIP_PROVENANCE=1 to override deliberately")
    replica = instance_uuids.allocate("sandbox", f"{name}/{args.source}", os.getpid())
    _, cfg = http("GET", f"{source['re_url'].rstrip('/')}/api/config")
    dimension = int((cfg or {}).get("eventDimension") or 7680)

    cert_name = f"sandbox-{name}"
    kline_restart.pki("issue", cert_name, "--kind", "both", "--dns", "localhost", "--ip", "127.0.0.1",
                      "--instance-uuid", replica)
    mine, harness = kline_restart.pki("paths", cert_name), kline_restart.pki("paths", "harness")
    port = kline_restart.free_port()
    env = {k: v for k, v in os.environ.items() if not k.startswith(PROVIDER_ENV)}
    env.update({"INSTANCE_UUID": replica, "INSTANCE_ID": f"sandbox-{name}",
                "INSTANCE_CLOCK_DIR": str(instance_uuids.clock_dir()),
                "INSTANCE_KLINE_DIR": str(state / "klines"), "INSTANCE_ISRE_DIR": str(state / "isre"),
                "MACHINES_DIR": args.corpus, "VECTOR_DIMENSION": str(dimension),
                "REALITY_ENGINE_PORT": str(port), "PORT": str(port), "RE_KLINE_CAPTURE": "1",
                "RE_SNAPSHOT_STORE": "memory",
                "RE_TLS_CERT": mine["chain"], "RE_TLS_KEY": mine["key"],
                "RE_TLS_CA": harness["ca"], "RE_TLS_CRL": harness["crl"]})
    log = open(state / "replica.log", "w")
    proc = subprocess.Popen(kline_restart.launch(runtime, repo, port, args.corpus, dimension), env=env, cwd=repo,
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    url = f"https://127.0.0.1:{port}"
    deadline = time.time() + kline_restart.BOOT_SECONDS
    while time.time() < deadline and proc.poll() is None and http("GET", f"{url}/api/engine/clock")[0] != 200:
        time.sleep(2)
    if proc.poll() is not None or http("GET", f"{url}/api/engine/clock")[0] != 200:
        stop(proc.pid)
        raise SystemExit(f"the replica did not come up; see {state / 'replica.log'}")

    def refuse(message: str) -> int:
        stop(proc.pid)
        shutil.rmtree(state / "klines", ignore_errors=True)
        raise SystemExit(message)

    # The same corpus, or nothing: the replica's own fingerprint, from an empty export. An
    # engine computes it with its first step, so the replica commits one empty input first;
    # every replay restores the state it needs, so that step leaves nothing behind.
    width = int(http("GET", f"{url}/api/config")[1]["eventDimension"])
    http("POST", f"{url}/api/perceive", {"vector": [0.0] * width, "compact": True})
    probe = request.Request(f"{url}/api/klines/export", method="POST", data=json.dumps({"since": 10 ** 15}).encode(),
                            headers={"content-type": "application/json"})
    with request.urlopen(probe, timeout=60) as r:
        mine_fp = json.loads(r.read().decode("utf-8").split("\n", 1)[0])["corpus"]["fingerprint"]
    if mine_fp != header["corpus"]["fingerprint"]:
        refuse(f"corpus mismatch: the bundle was captured on {header['corpus']['fingerprint']}, "
               f"the replica holds {mine_fp}")
    # The bundle's controls; capture stays on, so the replica records what it does.
    for control, value in (header.get("controls") or {}).items():
        if control != "klineCapture":
            http("PUT", f"{url}/api/engine/config/{control}", {"value": value})
    # The bundle, read-only context beside the replica's own store.
    imported = state / "klines" / replica / "imported" / src_uuid
    imported.mkdir(parents=True, exist_ok=True)
    target = imported / f"bundle-{header['sha256'][:8]}.jsonl"
    shutil.copyfile(args.bundle, target)
    os.chmod(target, 0o444)
    # Its own instance registry, a sandbox one.
    registry = {"host": "127.0.0.1", "services": {}, "instances": [{
        "id": f"sandbox-{name}", "runtime": runtime, "re_url": url, "pe_url": None, "status": "running",
        "instance_uuid": replica, "lane": "sandbox", "replicaOf": {"id": args.source, "instance_uuid": src_uuid}}]}
    (state / "registry.json").write_text(json.dumps(registry, indent=2) + "\n")
    check = subprocess.run([sys.executable, str(LIB / "instance_uuids.py"), "check-registry",
                            str(state / "registry.json"), "--sandbox"], capture_output=True, text=True)
    if check.returncode != 0:
        refuse(f"the replica's registry failed check-registry --sandbox: {check.stderr.strip()}")
    meta = {"name": name, "runtime": runtime, "url": url, "pid": proc.pid, "replica": replica,
            "source": {"id": args.source, "instance_uuid": src_uuid}, "bundle": str(target),
            "bundleSha256": header["sha256"], "corpus": args.corpus, "certificate": cert_name,
            "fingerprint": mine_fp, "records": len(records)}
    (state / "replica.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps({k: meta[k] for k in ("name", "runtime", "url", "replica", "source", "records")}))
    return 0


def stop(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGTERM)
        for _ in range(30):
            os.kill(pid, 0)
            time.sleep(1)
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def cmd_down(args: argparse.Namespace) -> int:
    state = state_of(args.name)
    meta_file = state / "replica.json"
    if not meta_file.exists():
        raise SystemExit(f"no replica {args.name}")
    meta = json.loads(meta_file.read_text())
    stop(meta["pid"])
    registry = state / "registry.json"
    if registry.exists():
        doc = json.loads(registry.read_text())
        for i in doc.get("instances", []):
            i["status"] = "stopped"
        registry.write_text(json.dumps(doc, indent=2) + "\n")
    meta_file.rename(state / "replica.stopped.json")
    print(json.dumps({"stopped": args.name, "results": str(state)}))
    return 0


# ── replay ───────────────────────────────────────────────────────────────────

def dense(entry: dict) -> list[float]:
    v = [0.0] * int(entry["length"])
    for c in entry["nonZero"]:
        v[int(c["index"])] = c["value"]
    return v


def restore_body(k: dict, fingerprint: str, machines: int) -> dict:
    """A narrowed snapshot whose activeAfter is the K-line's activeBefore, for its scope."""
    start = max(0, int(k["open"]["step"]) - 1)
    clock = {"instance": k["open"]["instance"], "lamport": k["open"]["lamport"], "step": start}
    body = {"format": "re-snapshot/1",
            "corpus": {"algorithm": "sha256/resident-declared-v1", "fingerprint": fingerprint, "machines": machines},
            "controls": {}, "machineControls": {}, "machineOverrides": {},
            "kline": {"scope": sorted(k["scope"], key=lambda n: n.encode()),
                      "span": {"from": start, "to": start}, "clocks": {"from": clock, "to": clock},
                      "activeBefore": [], "pairs": [], "activeAfter": k["activeBefore"], "sharedCells": []},
            "arbitration": None}
    body["digest"] = jcs.snapshot_digest(body)
    return body


def replay_once(url: str, k: dict, fingerprint: str, machines: int, outputs: list[tuple[int, int]],
                vary: dict[int, float] | None) -> dict:
    status, r = http("POST", f"{url}/api/runtime/restore", {"snapshot": restore_body(k, fingerprint, machines)})
    if status != 200:
        return {"restored": False, "error": f"restore -> {status} {str(r)[:160]}"}
    _, clock = http("GET", f"{url}/api/engine/clock")
    since = int(clock["commit"]) + 1
    shared = set(k.get("sharedCells") or [])
    reproduced = True
    pairs = k.get("pairs") or []
    for i, pair in enumerate(pairs):
        vec = dense(pair["isre"])
        if vary and i == len(pairs) - 1:  # the failing step: where the K-line was abandoned
            for cell, value in vary.items():
                vec[cell] = value
        status, step = http("POST", f"{url}/api/perceive", {"vector": vec, "compact": True})
        if status != 200:
            return {"restored": True, "error": f"perceive -> {status}"}
        n = step.get("stepNumber", (step.get("step") or {}).get("stepNumber"))
        _, got = http("GET", f"{url}/api/engine/steps/{n}/pair?timeoutMs=5000")
        want = {c["index"]: c["value"] for c in pair["osre"]["nonZero"] if c["index"] not in shared}
        mine = {c["index"]: c["value"] for c in got["osre"]["nonZero"]
                if c["index"] not in shared and any(o <= c["index"] < o + n_ for o, n_ in outputs)}
        reproduced &= mine == want
    klines: list[dict] = []
    cursor: Any = since
    while cursor is not None:
        _, page = http("GET", f"{url}/api/klines?since={cursor}&limit=1000")
        klines += page.get("klines", [])
        cursor = page.get("next")
    focal = [x for x in klines if x["focal"] == k["focal"] and x.get("outcome") != "interrupted"]
    return {"restored": True, "reproduced": reproduced,
            "klines": [{"id": x["id"], "outcome": x["outcome"], "focal": x["focal"]} for x in focal],
            "completed": any(x["outcome"] == "completed" for x in focal),
            "abandoned": any(x["outcome"] == "abandoned" for x in focal)}


def default_vary(k: dict) -> dict[int, float]:
    """Flip the failing cell across its threshold: the smallest change that can
    tell whether that element was all that stood between the path and the next event."""
    d = k.get("difference") or {}
    if not isinstance(d.get("cell"), int) or not isinstance(d.get("value"), (int, float)):
        return {}
    t = d["threshold"] if isinstance(d.get("threshold"), (int, float)) else 0.5
    return {d["cell"]: 0.0 if d["value"] >= t else 1.0}


def cmd_replay(args: argparse.Namespace) -> int:
    import re_tls  # noqa: E402
    re_tls.install_lane_opener()
    state = state_of(args.name)
    meta = json.loads((state / "replica.json").read_text())
    url = meta["url"]
    header, records = read_bundle(Path(meta["bundle"]))
    near = [r for r in records if r.get("format") == "re-kline/1" and r.get("outcome") == "abandoned"
            and r.get("difference")]
    if args.kline:
        near = [r for r in near if r["id"] in set(args.kline)]
    else:
        # A spread, not the first few: the earliest near-miss of each focal sequence, taken a
        # machine at a time, so N near-misses cover as many machines as they can. The order is
        # the bytes of the names, the same on every runtime.
        first: dict[tuple[str, str], dict] = {}
        for r in sorted(near, key=lambda r: (r["open"]["step"], r["id"])):
            first.setdefault((r["focal"]["machine"], r["focal"]["sequence"]), r)
        by_machine: dict[str, list[dict]] = {}
        for (machine, sequence), r in sorted(first.items(), key=lambda kv: (kv[0][0].encode(), kv[0][1].encode())):
            by_machine.setdefault(machine, []).append(r)
        spread: list[dict] = []
        while len(spread) < args.sample and any(by_machine.values()):
            for machine in sorted(by_machine, key=str.encode):
                if by_machine[machine] and len(spread) < args.sample:
                    spread.append(by_machine[machine].pop(0))
        near = spread
    _, listing = http("GET", f"{url}/api/machines")
    regions = {m["name"]: m.get("perceptualMapping") for m in (listing or {}).get("machines", [])}
    vary_arg = {int(c): float(v) for c, v in (x.split("=", 1) for x in args.vary)} if args.vary else None
    results = []
    with open(state / "experiments.jsonl", "a", encoding="utf-8") as ledger:
        for k in near:
            outputs = [(regions[n]["output"]["offset"], regions[n]["output"]["length"])
                       for n in k["scope"] if regions.get(n) and regions[n].get("output")]
            faithful = replay_once(url, k, header["corpus"]["fingerprint"], len(regions), outputs, None)
            vary = vary_arg if vary_arg is not None else default_vary(k)
            varied = replay_once(url, k, header["corpus"]["fingerprint"], len(regions), outputs, vary) if vary else None
            entry = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "replica": meta["replica"],
                     "causedBy": {"kline": k["id"], "source": meta["source"]["instance_uuid"],
                                  "bundleSha256": meta["bundleSha256"]},
                     "focal": k["focal"], "difference": k.get("difference"), "faithful": faithful,
                     "vary": {str(c): v for c, v in (vary or {}).items()}, "varied": varied}
            ledger.write(json.dumps(entry, sort_keys=True) + "\n")
            results.append(entry)
            print(f"  {k['focal']['machine']}/{k['focal']['sequence']} open {k['open']['step']}: "
                  f"reproduced {faithful.get('reproduced')} ({'abandoned again' if faithful.get('abandoned') else 'not abandoned'})"
                  + (f"; varied {entry['vary']}: {'completes' if varied.get('completed') else 'still does not complete'}"
                     if varied else ""))
    reproduced = sum(1 for e in results if e["faithful"].get("reproduced"))
    print(json.dumps({"replica": meta["name"], "replayed": len(results), "reproduced": reproduced,
                      "ledger": str(state / "experiments.jsonl")}))
    return 0 if results and reproduced == len(results) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export"); e.add_argument("--registry", required=True)
    e.add_argument("--from", dest="source", required=True); e.add_argument("--out", required=True)
    e.set_defaults(func=cmd_export)
    u = sub.add_parser("up"); u.add_argument("--registry", required=True)
    u.add_argument("--from", dest="source", required=True); u.add_argument("--bundle", required=True)
    u.add_argument("--corpus", required=True, help="the machines/ directory the source booted from")
    u.add_argument("--repo"); u.add_argument("--name"); u.set_defaults(func=cmd_up)
    r = sub.add_parser("replay"); r.add_argument("--name", required=True)
    r.add_argument("--kline", action="append"); r.add_argument("--sample", type=int, default=8)
    r.add_argument("--vary", action="append", help="CELL=VALUE at the failing step (default: flip the failing cell)")
    r.set_defaults(func=cmd_replay)
    d = sub.add_parser("down"); d.add_argument("--name", required=True); d.set_defaults(func=cmd_down)
    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
