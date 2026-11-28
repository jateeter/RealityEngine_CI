"""The K-line store across a real restart, on a fresh engine (RealityEngine_CI#603).

SURFACE_SPEC "Shutdown and crash": at boot an engine reads its open-table
checkpoint back and closes every K-line in it `interrupted` (`reason:
"shutdown"`), truncates a half-written last record, and resumes the store.

The voter under test is never restarted (owner, 2026-11-27). Instead, per
runtime, a fresh RE of that runtime is spawned on the same corpus with a copy
of the voter's store, the K-line store is applied to it at its boot, and its
response is read:

  resumed     every record the voter stored is there, unchanged but for one
              thing: a completed K-line still sustaining when the voter
              stopped has its sustain ended by the restart (`sustain.ended`);
  shutdown    every K-line the checkpoint held is closed interrupted/shutdown,
              and nothing else is new;
  truncated   a half-written record planted at the end of the last segment is
              cut off, and the store reads cleanly.

The fresh engine is a replica: a `sandbox` lane UUID (never the voter's, refused
by every production registry), its own certificate from the lane PKI, its store
in a scratch directory. It is stopped and the scratch directory removed when the
check ends, pass or fail. TLS only: with the lane off the check is not
evaluable, never run in plaintext.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))
import instance_uuids  # noqa: E402

PARTIAL = '{"format":"re-kline/1","id":"half-written'
BOOT_SECONDS = 600


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def pki(*args: str) -> dict:
    out = subprocess.run([sys.executable, str(LIB / "re_pki.py"), *args], capture_output=True, text=True, check=True)
    return json.loads(out.stdout) if args[0] == "paths" else {}


def launch(runtime: str, repo: Path, port: int, machines: str, dimension: int) -> list[str]:
    """The RE launch of RUNTIME, as its start.sh runs it."""
    if runtime == "cpp":
        return [str(repo / "bin" / "reality_engine_server"), str(port), machines, str(dimension)]
    if runtime == "scala":
        return ["java", "-jar", str(repo / "target" / "scala-2.13" / "reality-engine.jar")]
    if runtime == "lsp":
        binary = repo / "bin" / "reality-engine-lsp"
        if binary.exists():
            return [str(binary), "--dynamic-space-size", "8192", "reality"]
        setup = repo / "quicklisp" / "setup.lisp"
        setup = setup if setup.exists() else Path.home() / "quicklisp" / "setup.lisp"
        return ["sbcl", "--dynamic-space-size", "8192", "--noinform", "--disable-debugger", "--load", str(setup),
                "--eval", f'(pushnew (truename "{repo}/") ql:*local-project-directories*)',
                "--eval", "(ql:quickload :reality-engine-lsp)",
                "--eval", "(reality-engine-lsp:start-reality-from-environment)",
                "--eval", "(loop (sleep 3600))"]
    raise ValueError(f"no launch for {runtime}")


def plant_partial(store: Path) -> str | None:
    """Append a half-written record to the newest segment, as a crash mid-write leaves it."""
    segments = sorted(store.glob("segment-*.jsonl"), key=lambda p: int(p.stem.split("-", 1)[1]))
    if not segments:
        return None
    with open(segments[-1], "a", encoding="utf-8") as f:
        f.write(PARTIAL)
    return segments[-1].name


def check(runtime: str, repo: Path, voter: dict, store_parent: Path, machines: str,
          get: Callable[[str], tuple[int, Any]], log_dir: Path) -> dict:
    """One runtime's restart check. `voter` holds re_url; `get` is the harness's lane-TLS GET."""
    result: dict[str, Any] = {"runtime": runtime, "failures": []}
    fail = result["failures"].append
    if os.environ.get("RE_TLS", "off") != "on":
        return {**result, "notEvaluable": "the restart check runs on the TLS lane only (RE_TLS=on)"}
    re_url = voter["re_url"].rstrip("/")
    status, clock = get(f"{re_url}/api/engine/clock")
    source = str((clock or {}).get("instance", "")).lower() if status == 200 else ""
    if not source or not (store_parent / source).is_dir():
        return {**result, "notEvaluable": f"the voter's store {store_parent / (source or '?')} is not on this host"}
    status, cfg = get(f"{re_url}/api/config")
    dimension = int((cfg or {}).get("eventDimension") or 7680)
    stored = []
    cursor: Any = 0
    while cursor is not None:
        _, page = get(f"{re_url}/api/klines?since={cursor}&limit=1000")
        stored += (page or {}).get("klines", [])
        cursor = (page or {}).get("next")
    _, open_table = get(f"{re_url}/api/klines/open")
    held = {o["id"] for o in (open_table or {}).get("open", [])}

    replica = instance_uuids.allocate("sandbox", f"kline-restart/{runtime}", os.getpid())
    scratch = Path(tempfile.mkdtemp(prefix=f"kline-restart-{runtime}-"))
    proc: subprocess.Popen | None = None
    try:
        store = scratch / "klines" / replica
        shutil.copytree(store_parent / source, store, ignore=shutil.ignore_patterns("archive", "*.tmp"))
        planted = plant_partial(store)
        name = f"kline-restart-{runtime}"
        pki("issue", name, "--kind", "both", "--dns", "localhost", "--ip", "127.0.0.1", "--instance-uuid", replica)
        mine, harness = pki("paths", name), pki("paths", "harness")
        port = free_port()
        env = {**os.environ,
               "INSTANCE_UUID": replica, "INSTANCE_ID": name,
               "INSTANCE_CLOCK_DIR": str(instance_uuids.clock_dir()),
               "INSTANCE_KLINE_DIR": str(scratch / "klines"),
               "INSTANCE_ISRE_DIR": str(scratch / "isre"),
               "MACHINES_DIR": machines, "VECTOR_DIMENSION": str(dimension),
               "REALITY_ENGINE_PORT": str(port), "PORT": str(port),
               "RE_KLINE_CAPTURE": "1",
               "RE_TLS_CERT": mine["chain"], "RE_TLS_KEY": mine["key"],
               "RE_TLS_CA": harness["ca"], "RE_TLS_CRL": harness["crl"]}
        log = open(log_dir / f"kline-restart-{runtime}.log", "w")
        proc = subprocess.Popen(launch(runtime, repo, port, machines, dimension), env=env, cwd=repo,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        url = f"https://127.0.0.1:{port}"
        deadline = time.time() + BOOT_SECONDS
        while time.time() < deadline and proc.poll() is None:
            if get(f"{url}/api/engine/clock")[0] == 200:
                break
            time.sleep(2)
        else:
            fail(f"{runtime}: the fresh engine did not answer within {BOOT_SECONDS}s"
                 f"{'' if proc.poll() is None else f' (exited {proc.returncode})'}; see {log.name}")
            return result
        after: list[dict] = []
        cursor = 0
        while cursor is not None:
            _, page = get(f"{url}/api/klines?since={cursor}&limit=1000")
            after += (page or {}).get("klines", [])
            cursor = (page or {}).get("next")
        by_id = {k.get("id"): k for k in after}
        missing = [k["id"] for k in stored if k.get("id") not in by_id]
        def sustain_ended(before: dict, now: dict) -> bool:
            """The only change a restart may make to a stored K-line: its sustain ends."""
            rest = lambda k: {f: v for f, v in k.items() if f != "sustain"}
            return (rest(before) == rest(now) and (before.get("sustain") or {}).get("ended") is not True
                    and (now.get("sustain") or {}).get("ended") is True)
        ended = [k["id"] for k in stored if k.get("id") in by_id and by_id[k["id"]] != k and sustain_ended(k, by_id[k["id"]])]
        changed = [k["id"] for k in stored if k.get("id") in by_id and by_id[k["id"]] != k and k["id"] not in ended]
        recovered = [k for k in after if k.get("id") in held]
        wrong = [k["id"] for k in recovered if (k.get("outcome"), k.get("reason")) != ("interrupted", "shutdown")]
        stored_ids = {s["id"] for s in stored}
        extra = [k["id"] for k in after if k.get("id") not in held and k.get("id") not in stored_ids]
        if missing: fail(f"{runtime}: {len(missing)} stored K-line(s) did not survive the restart, e.g. {missing[:2]}")
        if changed: fail(f"{runtime}: {len(changed)} stored K-line(s) changed across the restart, e.g. {changed[:2]}")
        if len(recovered) != len(held): fail(f"{runtime}: the checkpoint held {len(held)} open K-line(s); {len(recovered)} were closed")
        if wrong: fail(f"{runtime}: {len(wrong)} checkpointed K-line(s) not closed interrupted/shutdown, e.g. {wrong[:2]}")
        if extra: fail(f"{runtime}: {len(extra)} K-line(s) appeared that were neither stored nor checkpointed")
        if planted:
            text = (store / planted).read_text(encoding="utf-8")
            if PARTIAL in text or not text.endswith("\n"):
                fail(f"{runtime}: the half-written record in {planted} was not truncated")
        result.update({"stored": len(stored), "checkpointed": len(held), "recovered": len(recovered),
                       "sustainEnded": len(ended),
                       "truncated": planted is not None, "replica": replica,
                       "recoveredKeys": sorted(json.dumps([k["focal"]["machine"], k["focal"]["sequence"],
                                                           k["open"]["step"], k["close"]["step"]]) for k in recovered)})
        return result
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        fail(f"{runtime}: {exc}")
        return result
    finally:
        if proc is not None and proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=10)
        shutil.rmtree(scratch, ignore_errors=True)
