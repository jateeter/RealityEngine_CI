#!/usr/bin/env python3
"""Acceptance stage for RealityEngine_CI#296: arbitration retention keyed by step.

SURFACE_SPEC.md, "Arbitration retention and the instance clock". No runtime is a
reference: every runtime is held to the specification, and the retained bodies
are held to 3-of-3 byte equivalence.

Per runtime:

  controls   arbitrationRetention (false) and arbitrationWindow (1) are on
             /api/engine/config with their declared defaults.
  legacy     with retention off, GET /api/arbitration is byte-identical to the
             committed baseline (config/arbitration-legacy-baseline.json) for
             the 9a fixture step and for an empty step, registrySource and
             shards masked; a reset leaves the empty object (finding B); ?step
             is refused 409; the window is ignored.
  windows    n = 0 answers [], n = 1 [current], n = 2 [previous, current]
             oldest first, and a window wider than what was retained answers
             what was retained -- no padding.
  ?step=N    200 for a retained step, 404 not resolved, 410 evicted, 400
             malformed.
  toggle     both directions with no restart; off answers the legacy object on
             the very next read, on starts empty.
  clock      {instance, lamport, step}: lamport ticks once per committed step
             and never resets; step resets; retained steps carry consecutive
             ticks.

Across runtimes: the retained window and the ?step body for the same drive are
byte-identical once the instance facts (clock.instance, clock.lamport) and the
deployment facts (shards, registrySource) are removed. A runtime that does not
answer is not agreement (docs/QUORUM_CONTRACT.md).

Every step is read at its completion point (lib/step_observer.py), never after a
sleep, and the steps this stage drives are checked for contiguity: a step it did
not cause is reported as an exclusivity violation by number, not as an engine
divergence (docs/OBSERVATION_EXCLUSIVITY.md).

  --record-legacy-baseline   write the legacy bodies observed now as the baseline
                             (each runtime must already agree with the spec).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any
from urllib import error, request

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from reset_contract import reset_pair  # noqa: E402
from step_observer import DEFAULT_WINDOW_MS, StepObserver  # noqa: E402

CI_DIR = Path(__file__).resolve().parents[1]
BASELINE = CI_DIR / "config" / "arbitration-legacy-baseline.json"

# The 9a fixture (regression-arbiter.py): ArbitrationWriterA and B contend for
# cells 16930-16931, so this step emits two records; the zero vector emits none.
VECTOR_LENGTH = 16960
FIXTURE = [0.0] * VECTOR_LENGTH
for _cell in (16924, 16926, 16936):
    FIXTURE[_cell] = 1.0
QUIET = [0.0] * VECTOR_LENGTH
FIXTURE_RECORDS = 2

DECLARED = {"arbitrationRetention": False, "arbitrationWindow": 1}
WINDOW_MAX = 1024


def http_raw(method: str, url: str, payload: Any = None, timeout: int = 60) -> tuple[int, bytes]:
    data = json.dumps(payload).encode() if payload is not None else None
    req = request.Request(url, data=data, method=method,
                          headers={"content-type": "application/json", "accept": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout) as response:
            return response.status, response.read()
    except error.HTTPError as exc:
        return exc.code, exc.read()
    except Exception as exc:  # noqa: BLE001 -- a dead engine is a result, not a crash
        return 0, str(exc).encode()


def http(method: str, url: str, payload: Any = None) -> tuple[int, Any]:
    status, body = http_raw(method, url, payload)
    try:
        return status, json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return status, body.decode("utf-8", "replace")


def mask_deployment(raw: bytes) -> str:
    """registrySource and shards masked in the raw bytes, layout kept."""
    raw = re.sub(rb'"registrySource":(null|"[^"]*")', b'"registrySource":"<deployment>"', raw)
    return re.sub(rb'"shards":\d+', b'"shards":"<deployment>"', raw).decode()


def comparable(body: Any) -> str:
    """A retained body with instance and deployment facts removed, serialised."""
    def strip(element: dict) -> dict:
        element = dict(element)
        clock = dict(element.get("clock") or {})
        clock.pop("instance", None)
        clock.pop("lamport", None)
        element["clock"] = clock
        element.pop("shards", None)
        element.pop("registrySource", None)
        return element
    if isinstance(body, list):
        body = [strip(e) for e in body]
    elif isinstance(body, dict):
        body = strip(body)
    return json.dumps(body, sort_keys=True, separators=(",", ":"))


def steps_of(body: Any) -> Any:
    """The step numbers of a retained list; a short description of anything else."""
    if isinstance(body, list):
        return [e.get("clock", {}).get("step") if isinstance(e, dict) else e for e in body]
    return f"<not a list: {str(body)[:80]}>"


def load_instances(registry_path: Path) -> list[dict[str, str]]:
    document = json.loads(registry_path.read_text(encoding="utf-8"))
    out = []
    for instance in document.get("instances", []):
        re_url = instance.get("re_url") or instance.get("reUrl") or ""
        if not re_url:
            continue
        out.append({"id": instance.get("id", "?"), "runtime": instance.get("runtime", "?"),
                    "re": re_url.rstrip("/"),
                    "pe": (instance.get("pe_url") or instance.get("peUrl") or "").rstrip("/")})
    return out


class Runtime:
    """One instance under test: drives steps and keeps the checks it failed."""

    def __init__(self, instance: dict, window_ms: int):
        self.instance = instance
        self.name = f"{instance['runtime']}:{instance['id']}"
        self.re = instance["re"]
        self.failures: list[str] = []
        self.observer = StepObserver(lambda url: http("GET", url), self.re, window_ms)

    def check(self, condition: bool, message: str) -> bool:
        if not condition:
            self.failures.append(f"{self.name}: {message}")
            print(f"  FAIL {self.name}: {message}")
        return condition

    def reset(self) -> None:
        for failure in reset_pair(lambda url, body: http("POST", url, body),
                                  self.re, self.instance["pe"], self.instance["id"]):
            self.check(False, failure)
        self.observer.last_step = None

    def step(self, vector: list[float]) -> int:
        """Drive one step and wait for its completion point; its step number."""
        status, body = http("POST", f"{self.re}/api/perceive", {"vector": vector})
        if status != 200 or not isinstance(body, dict):
            raise RuntimeError(f"POST /api/perceive -> {status} {str(body)[:120]}")
        number = body.get("stepNumber", (body.get("step") or {}).get("stepNumber"))
        if not isinstance(number, int):
            raise RuntimeError("POST /api/perceive named no stepNumber")
        self.observer.observe_push({"step": {"stepNumber": number}})
        return number

    def put(self, control: str, value: Any) -> tuple[int, Any]:
        return http("PUT", f"{self.re}/api/engine/config/{control}", {"value": value})

    def restore(self) -> None:
        for control in DECLARED:
            http("DELETE", f"{self.re}/api/engine/config/{control}")


def exercise(rt: Runtime, baseline: dict | None, record: dict | None) -> dict[str, str]:
    """Run every per-runtime check; the bodies the cross-runtime comparison uses."""
    runtime = rt.instance["runtime"]
    shared: dict[str, str] = {}

    # -- controls --------------------------------------------------------------
    status, config = http("GET", f"{rt.re}/api/engine/config")
    controls = {c.get("name"): c for c in (config.get("controls") or [])} if isinstance(config, dict) else {}
    for name, default in DECLARED.items():
        control = controls.get(name) or {}
        if rt.check(bool(control), f"/api/engine/config has no {name} control"):
            rt.check(control.get("default") == default and control.get("scope") == "engine",
                     f"{name} declares {control.get('scope')}/{control.get('default')!r}, "
                     f"SURFACE_SPEC declares engine/{default!r}")
    rt.restore()

    # -- legacy ----------------------------------------------------------------
    rt.reset()
    status, raw = http_raw("GET", f"{rt.re}/api/arbitration")
    after_reset = mask_deployment(raw)
    rt.step(FIXTURE)
    status, raw = http_raw("GET", f"{rt.re}/api/arbitration")
    fixture = mask_deployment(raw)
    rt.step(QUIET)
    status, raw = http_raw("GET", f"{rt.re}/api/arbitration")
    empty = mask_deployment(raw)
    if record is not None:
        record.setdefault("fixture", {})[runtime] = fixture
        record.setdefault("empty", {})[runtime] = empty
    if baseline is not None:
        for label, observed in (("fixture", fixture), ("empty", empty)):
            expected = (baseline.get(label) or {}).get(runtime) or ""
            if rt.check(bool(expected), f"no legacy baseline for {runtime}/{label}"):
                rt.check(observed == expected,
                         f"legacy {label} body differs from the baseline byte for byte:\n"
                         f"      expected {expected[:200]}\n      observed {observed[:200]}")
    rt.check(after_reset == empty,
             "legacy body after a reset is not the empty object -- the previous step's records "
             "survived the reset (finding B)")
    status, _ = http("GET", f"{rt.re}/api/arbitration?step=0")
    rt.check(status == 409, f"?step with retention off answered {status}, expected 409")
    rt.put("arbitrationWindow", 2)
    rt.step(FIXTURE)
    status, body = http("GET", f"{rt.re}/api/arbitration")
    rt.check(isinstance(body, dict), "arbitrationWindow changed the legacy shape while retention is off")

    # -- windows ---------------------------------------------------------------
    rt.reset()
    rt.check(rt.put("arbitrationRetention", True)[0] == 200, "PUT arbitrationRetention true refused")
    rt.put("arbitrationWindow", 0)
    rt.step(FIXTURE)
    status, body = http("GET", f"{rt.re}/api/arbitration")
    rt.check(body == [], f"n = 0 answered {str(body)[:120]}, expected []")
    rt.put("arbitrationWindow", 1)
    first = rt.step(FIXTURE)
    status, body = http("GET", f"{rt.re}/api/arbitration")
    steps = steps_of(body)
    rt.check(steps == [first], f"n = 1 answered steps {steps}, expected [{first}]")
    rt.put("arbitrationWindow", 2)
    status, body = http("GET", f"{rt.re}/api/arbitration")
    steps = steps_of(body)
    rt.check(steps == [first], f"a widened window answered {steps}: it must not pad, expected [{first}]")
    second = rt.step(QUIET)
    status, window = http("GET", f"{rt.re}/api/arbitration")
    steps = steps_of(window)
    rt.check(steps == [first, second], f"n = 2 answered steps {steps}, expected [{first}, {second}]")
    if isinstance(window, list) and len(window) == 2:
        rt.check([e.get("count") for e in window] == [FIXTURE_RECORDS, 0],
                 f"n = 2 counts {[e.get('count') for e in window]}, expected [{FIXTURE_RECORDS}, 0]")
        ticks = [e.get("clock", {}).get("lamport") for e in window]
        rt.check(isinstance(ticks[0], int) and ticks[1] == ticks[0] + 1,
                 f"consecutive steps carry Lamport ticks {ticks}, expected consecutive")
        records = window[0].get("records") or []
        rt.check([r.get("cell") for r in records] == sorted(r.get("cell") for r in records),
                 "retained records are not ordered by cell")
        for r in records:
            keys = [(c.get("provider"), c.get("originId"), c.get("cesId") or "", c.get("outputVectorId") or "")
                    for c in (r.get("contributors") or [])]
            rt.check(keys == sorted(keys), f"cell {r.get('cell')} contributions are not in canonical order")
            rt.check(all(c.get("outputVectorId") == "0" for c in (r.get("contributors") or [])
                         if c.get("provider") == "machine"),
                     f"cell {r.get('cell')}: a machine contribution's outputVectorId is not \"0\"")
    shared["window"] = comparable(window)

    # -- ?step=N ---------------------------------------------------------------
    status, one = http("GET", f"{rt.re}/api/arbitration?step={first}")
    rt.check(status == 200 and isinstance(one, dict) and one.get("clock", {}).get("step") == first
             and one.get("count") == FIXTURE_RECORDS,
             f"?step={first} answered {status} {str(one)[:120]}")
    shared["step"] = comparable(one)
    for query, expected, why in ((second + 5, 404, "a step that has not resolved"),
                                 ("x", 400, "a malformed step")):
        status, _ = http("GET", f"{rt.re}/api/arbitration?step={query}")
        rt.check(status == expected, f"?step={query} ({why}) answered {status}, expected {expected}")
    rt.put("arbitrationWindow", 1)
    status, _ = http("GET", f"{rt.re}/api/arbitration?step={first}")
    rt.check(status == 410, f"?step={first} after narrowing to 1 answered {status}, expected 410 (evicted)")
    status, body = rt.put("arbitrationWindow", WINDOW_MAX + 1)
    rt.check(status == 400, f"arbitrationWindow {WINDOW_MAX + 1} answered {status}, expected 400")

    # -- clock -----------------------------------------------------------------
    status, before = http("GET", f"{rt.re}/api/engine/clock")
    if rt.check(status == 200 and isinstance(before, dict), f"GET /api/engine/clock answered {status}"):
        rt.check(before.get("step") == second, f"clock step {before.get('step')}, expected {second}")
        rt.check(isinstance(before.get("instance"), str) and len(before["instance"]) == 36,
                 f"clock instance {before.get('instance')!r} is not a UUID")
        rt.reset()
        _, after = http("GET", f"{rt.re}/api/engine/clock")
        rt.check(after.get("step") == -1 and after.get("lamport") == before.get("lamport")
                 and after.get("instance") == before.get("instance"),
                 f"a reset moved the clock {before} -> {after}: step restarts, lamport and instance do not")

    # -- toggle ----------------------------------------------------------------
    rt.step(FIXTURE)
    rt.put("arbitrationRetention", False)
    status, body = http("GET", f"{rt.re}/api/arbitration")
    rt.check(isinstance(body, dict), "turning retention off did not restore the legacy object on the next read")
    rt.put("arbitrationRetention", True)
    status, body = http("GET", f"{rt.re}/api/arbitration")
    rt.check(body == [], f"turning retention on answered {str(body)[:80]}: it must start empty")

    rt.restore()
    rt.reset()
    return shared


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", type=Path, default=Path("/tmp/re-registry/re-registry.json"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--step-window-ms", type=int, default=DEFAULT_WINDOW_MS)
    parser.add_argument("--record-legacy-baseline", action="store_true")
    args = parser.parse_args()

    instances = load_instances(args.registry)
    report: dict[str, Any] = {"status": "passed", "failures": [], "runtimes": {}}
    if not instances:
        report.update(status="skipped", reason="no instances in the instance registry")
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("arbitration-retention: SKIPPED -- no instances in the instance registry")
        return 0

    baseline = None if args.record_legacy_baseline else json.loads(BASELINE.read_text(encoding="utf-8"))
    recorded: dict | None = {} if args.record_legacy_baseline else None
    shared: dict[str, dict[str, str]] = {}
    violations: list[str] = []
    for instance in instances:
        rt = Runtime(instance, args.step_window_ms)
        print(f"\n== {rt.name}")
        try:
            shared[rt.name] = exercise(rt, baseline, recorded)
        except Exception as exc:  # noqa: BLE001 -- one runtime failing is that runtime's result
            rt.check(False, f"aborted: {exc}")
            rt.restore()
        violations.extend(f"{rt.name}: {v}" for v in rt.observer.violations)
        report["runtimes"][rt.name] = {"failures": rt.failures}
        report["failures"].extend(rt.failures)

    # 3-of-3: every runtime answered, and the retained bodies agree byte for byte.
    if len(shared) != len(instances):
        report["failures"].append(
            f"quorum: {len(shared)} of {len(instances)} runtimes produced retained bodies; "
            "a runtime that does not answer is not agreement")
    for key in ("window", "step"):
        bodies: dict[str, list[str]] = {}
        for name, observed in shared.items():
            bodies.setdefault(observed.get(key, ""), []).append(name)
        if len(bodies) > 1:
            report["failures"].append(
                f"retained {key} bodies are not byte-identical across runtimes: "
                + " | ".join(f"{'+'.join(names)}: {body[:160]}" for body, names in bodies.items()))
    report["quorum"] = {"runtimes": sorted(shared), "of": len(instances)}
    if violations:
        report["exclusivityViolations"] = violations
        report["failures"].extend(f"exclusivity: {v}" for v in violations)

    if recorded is not None and not report["failures"]:
        current = json.loads(BASELINE.read_text(encoding="utf-8")) if BASELINE.exists() else {}
        current.update(recorded)
        BASELINE.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
        print(f"\nlegacy baseline recorded: {BASELINE}")

    if report["failures"]:
        report["status"] = "failed"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print()
    if report["failures"]:
        print(f"arbitration-retention: FAILED ({len(report['failures'])} problem(s))")
        for failure in report["failures"]:
            print(f"  - {failure}")
        return 1
    print(f"arbitration-retention: OK -- {len(shared)} of {len(instances)} runtimes conform, "
          "retained bodies byte-identical 3-of-3, legacy bodies match the baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
