#!/usr/bin/env python3
"""Soak a running RealityEngine install (ReleaseRoadmap D1).

For --minutes (default 10), against every instance in the instance registry:
  - step each instance once a second, as normal operation does: its PE pushes
    its sources' perception to its RE (POST {pe}/api/push, compact), the drive
    the trajectory-parity stage uses;
  - follow each RE's event stream (GET /api/engine/stream) and record the
    longest silence between frames;
  - every 5 s, check each RE and PE /api/health and the RE's instance clock
    (GET /api/engine/clock), which must keep its UUID and never go backwards;
  - every 30 s, read Prometheus' engine targets and Docker's memory and
    restart counts for the compose project.

Fails on: a failed step or health check, a stream silent longer than
--max-stream-gap seconds, a clock that changes UUID or goes backwards, an
engine target not up at the end, or a container that restarted. Writes a JSON
report with the measurements, and prints a summary.

    release/soak.py --minutes 10 --report soak.json
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import threading
import time
import urllib.request

REGISTRY = "http://localhost:5999/re-registry.json"
PROMETHEUS = "http://localhost:9090"


def get(url: str, timeout: float = 10):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.status, json.loads(r.read() or b"null")


def post(url: str, timeout: float = 30, body: bytes = b"{}"):
    req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        r.read()
        return r.status


class Stream(threading.Thread):
    """Follows one RE's SSE stream: frame count and the longest gap."""

    def __init__(self, url: str, stop: threading.Event):
        super().__init__(daemon=True)
        self.url, self.stop = url, stop
        self.frames, self.max_gap, self.reconnects = 0, 0.0, 0
        self.last = time.monotonic()

    def run(self) -> None:
        while not self.stop.is_set():
            try:
                with urllib.request.urlopen(self.url, timeout=60) as r:
                    for line in r:
                        now = time.monotonic()
                        if line.startswith(b"data:") or line.startswith(b":"):
                            self.max_gap = max(self.max_gap, now - self.last)
                            self.last = now
                            self.frames += 1
                        if self.stop.is_set():
                            return
            except Exception:  # noqa: BLE001 - a drop is counted, then retried
                if self.stop.is_set():
                    return
                self.reconnects += 1
                time.sleep(1)

    def gap_now(self) -> float:
        return max(self.max_gap, time.monotonic() - self.last)


def docker_state(project: str) -> dict[str, dict]:
    ids = subprocess.run(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={project}"],
                         capture_output=True, text=True).stdout.split()
    out = {}
    if not ids:
        return out
    info = json.loads(subprocess.run(["docker", "inspect", *ids], capture_output=True, text=True).stdout)
    for c in info:
        svc = c["Config"]["Labels"].get("com.docker.compose.service", c["Name"])
        out[svc] = {"restarts": c.get("RestartCount", 0), "running": c["State"]["Running"],
                    "started": c["State"]["StartedAt"]}
    return out


def docker_mem(project: str) -> dict[str, float]:
    rows = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.Name}}|{{.MemUsage}}"],
                          capture_output=True, text=True).stdout.splitlines()
    out = {}
    for row in rows:
        name, _, use = row.partition("|")
        if not name.startswith(project + "-"):
            continue
        v = use.split("/")[0].strip()
        mib = float(v[:-3]) * (1024 if v.endswith("GiB") else 1) if v[-3:] in ("GiB", "MiB") else 0.0
        out[name.removeprefix(project + "-").removesuffix("-1")] = round(mib, 1)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--minutes", type=float, default=10)
    ap.add_argument("--registry", default=REGISTRY)
    ap.add_argument("--project", default="realityengine")
    ap.add_argument("--max-stream-gap", type=float, default=30.0)
    ap.add_argument("--report", default=None)
    args = ap.parse_args()

    _, reg = get(args.registry)
    insts = reg["instances"]
    stop = threading.Event()
    streams = {i["id"]: Stream(f"{i['re_url']}/api/engine/stream", stop) for i in insts}
    for s in streams.values():
        s.start()

    problems: list[str] = []
    step_ms: dict[str, list[float]] = {i["id"]: [] for i in insts}
    clocks: dict[str, tuple[str, int]] = {}
    mem_samples: list[dict] = []
    start_state = docker_state(args.project)
    t0 = time.monotonic()
    end = t0 + args.minutes * 60
    tick = 0
    print(f"soak: {len(insts)} instance(s), {args.minutes} min", flush=True)
    while time.monotonic() < end:
        tick += 1
        for i in insts:
            t = time.monotonic()
            try:
                code = post(f"{i['pe_url']}/api/push", body=b'{"compact": true}')
                step_ms[i["id"]].append((time.monotonic() - t) * 1000)
                if code != 200:
                    problems.append(f"{i['id']}: push answered {code}")
            except Exception as e:  # noqa: BLE001
                problems.append(f"{i['id']}: push failed at {tick}s: {e}")
        if tick % 5 == 0:
            for i in insts:
                for role, url in (("RE", i["re_url"]), ("PE", i["pe_url"])):
                    try:
                        code, _ = get(f"{url}/api/health", timeout=5)
                        if code != 200:
                            problems.append(f"{i['id']} {role} health {code} at {tick}s")
                    except Exception as e:  # noqa: BLE001
                        problems.append(f"{i['id']} {role} health failed at {tick}s: {e}")
                try:
                    _, c = get(f"{i['re_url']}/api/engine/clock", timeout=5)
                    prev = clocks.get(i["id"])
                    if prev and (c["instance"] != prev[0] or c["lamport"] < prev[1]):
                        problems.append(f"{i['id']}: clock {prev} -> ({c['instance']}, {c['lamport']})")
                    clocks[i["id"]] = (c["instance"], c["lamport"])
                except Exception as e:  # noqa: BLE001
                    problems.append(f"{i['id']}: clock read failed: {e}")
        if tick % 30 == 0:
            mem_samples.append({"t": tick, "mib": docker_mem(args.project)})
            print(f"  {tick:4d}s  steps ok, stream gaps max "
                  f"{max(s.gap_now() for s in streams.values()):.1f}s, "
                  f"memory {sum(mem_samples[-1]['mib'].values())/1024:.2f} GiB", flush=True)
        time.sleep(max(0.0, t0 + tick - time.monotonic()))

    stop.set()
    for iid, s in streams.items():
        if s.frames == 0:
            problems.append(f"{iid}: no stream frame in {args.minutes} min")
        if s.gap_now() > args.max_stream_gap:
            problems.append(f"{iid}: stream silent {s.gap_now():.1f}s (> {args.max_stream_gap}s)")
    end_state = docker_state(args.project)
    for svc, st in end_state.items():
        before = start_state.get(svc, {})
        if st["restarts"] > before.get("restarts", 0) or (before and st["started"] != before.get("started")):
            problems.append(f"{svc}: restarted during the soak")
        if not st["running"] and svc not in ("corpus", "prepare", "pim-bootstrap"):
            problems.append(f"{svc}: not running")
    try:
        _, t = get(f"{PROMETHEUS}/api/v1/targets")
        eng = [x for x in t["data"]["activeTargets"] if x["labels"].get("job", "").endswith("-registry")]
        down = [f"{x['labels'].get('instance')}/{x['labels'].get('component')}" for x in eng if x["health"] != "up"]
        if down:
            problems.append(f"Prometheus engine targets not up: {down}")
    except Exception as e:  # noqa: BLE001
        problems.append(f"Prometheus targets unreadable: {e}")

    report = {
        "minutes": args.minutes,
        "instances": [i["id"] for i in insts],
        "steps": {k: {"count": len(v), "p50_ms": round(statistics.median(v), 1) if v else None,
                      "max_ms": round(max(v), 1) if v else None} for k, v in step_ms.items()},
        "streams": {k: {"frames": s.frames, "max_gap_s": round(s.gap_now(), 1), "reconnects": s.reconnects}
                    for k, s in streams.items()},
        "clocks": {k: {"instance": v[0], "lamport": v[1]} for k, v in clocks.items()},
        "memory_mib": mem_samples[-1]["mib"] if mem_samples else {},
        "memory_peak_gib": round(max((sum(m["mib"].values()) for m in mem_samples), default=0) / 1024, 2),
        "problems": problems,
    }
    if args.report:
        with open(args.report, "w") as f:
            json.dump(report, f, indent=2)
    print(json.dumps({k: report[k] for k in ("steps", "streams", "memory_peak_gib")}, indent=1))
    print(f"\n[{'ok' if not problems else 'fail'}] {len(problems)} problem(s)")
    for p in problems[:30]:
        print("  - " + p)
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
