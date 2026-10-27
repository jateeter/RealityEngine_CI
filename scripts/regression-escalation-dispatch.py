#!/usr/bin/env python3
"""Escalation dispatch parity: do the runtimes escalate alike, and at all?

`semantic_escalation_dispatches_total{rag}` counts a dispatch record whose
action is `emergency-dispatch` or `urgent-intervention`, keyed by the RAG status
of the determination behind it (docs/PE_METRICS_CONTRACT.md). Every PE exports
it, and until the regression corpus carried the escalation trio (BSX118, CSX022,
TFX047) nothing in a lane could make it move: the one escalating machine,
FallDetection, has no agentBinding, so its dispatch is dropped before a record
exists. A counter at zero on every runtime is also what an engine that never
counts reports — C++ and LSP declared it and never incremented it
(RealityEngine_CPP#179, RealityEngine_LSP#175) — and no stage read it, so no
lane could tell the two apart.

The drive is trajectory-parity's, imported rather than restated: reset RE and
PE, arm the corpus's interned test sources, and push the longest interned
sequence through, observing each step at its completion point. What it
measures is the effect of that drive alone:

* the counter's change per `rag` label on each runtime, read from
  `GET {pe}/api/metrics` before and after — a counter is never reset, so the
  absolute value carries every earlier stage;
* the dispatch-ledger records the drive created (`GET {pe}/api/dispatch/ledger`,
  ids not present before), grouped by machine and action, so the runtimes must
  agree on which machines escalated how often and not only on a total.

What fails:

* runtimes that disagree on either — reported as agreement clusters, no
  runtime is the reference;
* an escalation under an explicit non-RED status: re:EscalationDetermination
  requires RED, and an unstated status is counted apart because the axiom is
  open-world;
* with `--expect-escalation`, a drive that escalated nothing at RED. The
  harness passes it for a corpus that holds escalating machines.

Skipped, with a report saying so, when no runtime has trigger dispatch active
(`GET {pe}/api/triggers/status` participation): there is then nothing to count.
Runtimes that differ in participation are a failure, not a skip.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from registry_url import registry_url  # noqa: E402
from reset_contract import reset_instances  # noqa: E402

_spec = importlib.util.spec_from_file_location("trajectory", HERE / "regression-trajectory-parity.py")
assert _spec is not None and _spec.loader is not None
trajectory = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(trajectory)

LEDGER_LIMIT = 256
ESCALATION_ACTIONS = ("emergency-dispatch", "urgent-intervention")
METRIC = "semantic_escalation_dispatches_total"
_METRIC_LINE = re.compile(rf"^{METRIC}\{{(?P<labels>[^}}]*)\}}\s+(?P<value>[0-9.eE+-]+)\s*$")
_RAG_LABEL = re.compile(r'rag="(?P<rag>[^"]*)"')


def parse_escalations(text: str) -> dict[str, int]:
    """{rag: count} from a Prometheus text exposition. Absent series read as 0."""
    out: dict[str, int] = {}
    for line in text.splitlines():
        match = _METRIC_LINE.match(line.strip())
        if not match:
            continue
        rag = _RAG_LABEL.search(match.group("labels"))
        key = rag.group("rag") if rag else "unstated"
        out[key] = out.get(key, 0) + int(float(match.group("value")))
    return out


def delta(after: dict[str, int], before: dict[str, int]) -> dict[str, int]:
    return {rag: after.get(rag, 0) - before.get(rag, 0)
            for rag in sorted(set(after) | set(before))
            if after.get(rag, 0) - before.get(rag, 0) != 0}


def ledger_by_machine(records: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    """{machineId: {actionCode: n}} over escalation-class records."""
    out: dict[str, dict[str, int]] = {}
    for record in records:
        action = ((record.get("semantics") or {}).get("actionCode")) or ""
        if action not in ESCALATION_ACTIONS:
            continue
        machine = str(record.get("machineId") or "unidentified")
        out.setdefault(machine, {})
        out[machine][action] = out[machine].get(action, 0) + 1
    return {m: dict(sorted(v.items())) for m, v in sorted(out.items())}


def non_red(escalations: dict[str, int]) -> dict[str, int]:
    return {rag: n for rag, n in escalations.items() if rag not in ("RED", "unstated") and n}


def agreement_failure(label: str, values: dict[str, Any]) -> str | None:
    """None when every runtime holds the same value, else the clusters."""
    clusters = trajectory.cluster(values)
    if len(clusters) <= 1:
        return None
    shape = " | ".join("+".join(members) for members in clusters)
    detail = "; ".join(f"{members[0] if len(members) == 1 else '+'.join(members)}="
                       f"{json.dumps(values[members[0]], sort_keys=True)}" for members in clusters)
    return f"{label} disagree across runtimes: {shape} ({detail})"


def evaluate(escalations: dict[str, dict[str, int]], machines: dict[str, dict[str, dict[str, int]]],
             ledger_comparable: bool, expect: bool) -> list[str]:
    """The stage's verdict over what the drive produced. Pure, so it is unit tested."""
    failures: list[str] = []
    failure = agreement_failure("escalation counter deltas", escalations)
    if failure:
        failures.append(failure)
    if ledger_comparable:
        failure = agreement_failure("escalating machines (dispatch ledger)", machines)
        if failure:
            failures.append(failure)
    for instance, counts in sorted(escalations.items()):
        bad = non_red(counts)
        if bad:
            failures.append(f"{instance}: escalation under a non-RED status {bad} — "
                            f"re:EscalationDetermination requires RED")
    if expect:
        for instance, counts in sorted(escalations.items()):
            if counts.get("RED", 0) <= 0:
                failures.append(
                    f"{instance}: the drive escalated nothing at RED — the corpus holds "
                    f"escalating machines with an agentBinding, so a zero counter is an "
                    f"engine that did not dispatch or did not count")
    return failures


def get_text(url: str, timeout: int = 20) -> tuple[int, str]:
    req = trajectory.request.Request(url, headers={"accept": "text/plain"})
    try:
        with trajectory.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except trajectory.error.HTTPError as exc:
        return exc.code, ""
    except (trajectory.error.URLError, TimeoutError, OSError):
        return 0, ""


def read_counter(instance: dict[str, Any]) -> tuple[dict[str, int] | None, str | None]:
    status, text = get_text(f"{instance['pe']}/api/metrics")
    if status != 200:
        return None, f"{instance['id']}: GET /api/metrics returned {status}"
    return parse_escalations(text), None


def read_ledger(instance: dict[str, Any]) -> tuple[list[dict[str, Any]] | None, str | None]:
    status, payload = trajectory.get_json(f"{instance['pe']}/api/dispatch/ledger")
    if status != 200 or not isinstance(payload, dict) or not isinstance(payload.get("records"), list):
        return None, f"{instance['id']}: GET /api/dispatch/ledger returned {status}"
    return payload["records"], None


def participation(instance: dict[str, Any]) -> str:
    status, payload = trajectory.get_json(f"{instance['pe']}/api/triggers/status")
    if status != 200 or not isinstance(payload, dict):
        return f"unreadable ({status})"
    return str(payload.get("participation") or ("active" if payload.get("enabled") else "not-active"))


def write(out: Path, report: dict[str, Any]) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", default=registry_url())
    parser.add_argument("--out", type=Path, required=True,
                        help="report path; a skip writes <stem>-skipped.json beside it instead")
    parser.add_argument("--steps", type=int, default=0,
                        help="push count; 0 (default) walks the longest interned sequence")
    parser.add_argument("--expect-escalation", action="store_true",
                        help="fail when the drive escalates nothing at RED")
    parser.add_argument("--step-window-ms", type=int, default=trajectory.DEFAULT_WINDOW_MS)
    args = parser.parse_args()

    instances = trajectory.load_instances(args.registry)
    if len(instances) < 2:
        print(f"FAIL escalation dispatch needs at least two runtimes, found {len(instances)}", file=sys.stderr)
        return 1
    ids = [i["id"] for i in instances]

    taking_part = {i["id"]: participation(i) for i in instances}
    if all(p != "active" for p in taking_part.values()) and len(set(taking_part.values())) == 1:
        reason = f"trigger dispatch is {taking_part[ids[0]]} on every runtime; nothing dispatches, so nothing escalates"
        write(args.out.with_name(f"{args.out.stem}-skipped.json"), {"status": "skipped", "reason": reason})
        print(f"SKIP escalation dispatch: {reason}")
        return 0

    failures: list[str] = []
    if len(set(taking_part.values())) > 1:
        failures.append(f"trigger dispatch participation differs across runtimes: {taking_part}")

    failures.extend(f"{item} — the drive below starts from unknown prior state"
                    for item in reset_instances(trajectory.post_json, instances))

    steps = args.steps or max((trajectory.longest_interned_sequence(i) for i in instances), default=0)
    if steps == 0:
        failures.append("no interned test sequences on any runtime; nothing drives the corpus")

    before_counter: dict[str, dict[str, int]] = {}
    before_ledger: dict[str, set[str]] = {}
    for instance in instances:
        counter, err = read_counter(instance)
        if counter is None:
            failures.append(str(err))
        else:
            before_counter[instance["id"]] = counter
        records, err = read_ledger(instance)
        if records is None:
            failures.append(str(err))
        else:
            before_ledger[instance["id"]] = {str(r.get("id")) for r in records}

    baselines = {i["id"]: trajectory.history_length(i, "isre") for i in instances}
    violations: set[str] = set()
    for instance in instances:
        if steps:
            failures.extend(trajectory.run_seed_sequence(
                instance, steps, args.step_window_ms,
                baseline=baselines.get(instance["id"]), violations=violations))

    escalations: dict[str, dict[str, int]] = {}
    machines: dict[str, dict[str, dict[str, int]]] = {}
    ledger_comparable = True
    evicted: dict[str, int] = {}
    for instance in instances:
        iid = instance["id"]
        counter, err = read_counter(instance)
        if counter is None:
            failures.append(str(err))
        elif iid in before_counter:
            escalations[iid] = delta(counter, before_counter[iid])
        records, err = read_ledger(instance)
        if records is None or iid not in before_ledger:
            if records is None:
                failures.append(str(err))
            ledger_comparable = False
            continue
        seen = {str(r.get("id")) for r in records}
        # The ledger is a ring (TRIGGER_DISPATCH_LEDGER_LIMIT, default 256) that
        # drops its oldest first, and the stages before this one fill it, so a
        # drive always pushes earlier records out. Its own are all still there
        # while any record from before it survives; only when none does, or an
        # empty ledger filled to the limit, may it have lost some, and then the
        # per-machine view is incomparable rather than wrong.
        survived = len(before_ledger[iid] & seen)
        if not survived and (before_ledger[iid] or len(records) >= LEDGER_LIMIT):
            evicted[iid] = len(before_ledger[iid])
            ledger_comparable = False
        machines[iid] = ledger_by_machine([r for r in records if str(r.get("id")) not in before_ledger[iid]])

    warnings: list[str] = []
    if not ledger_comparable:
        warnings.append(f"dispatch ledger not comparable (no pre-drive record survived the ring {evicted}); "
                        f"per-machine agreement was not checked, the counters were")
    if len(escalations) == len(instances):
        failures.extend(evaluate(escalations, machines, ledger_comparable, args.expect_escalation))
    else:
        failures.append(f"escalation counter readable on {sorted(escalations)} of {ids}; agreement not demonstrated")

    report = {
        "status": "failed" if failures else "passed",
        "instances": ids,
        "seedSteps": steps,
        "participation": taking_part,
        "expectEscalation": args.expect_escalation,
        "escalations": escalations,
        "escalatingMachines": machines,
        "ledgerComparable": ledger_comparable,
        "exclusivityViolations": sorted(violations),
        "failures": failures,
        "warnings": warnings,
    }
    write(args.out, report)
    red = {iid: counts.get("RED", 0) for iid, counts in escalations.items()}
    if failures:
        print(f"FAIL escalation dispatch ({len(failures)} failure(s)); RED per runtime {red}")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"PASS escalation dispatch: {steps} steps, RED per runtime {red}, "
          f"{sum(len(m) for m in machines.values()) // max(len(machines), 1)} escalating machine(s), "
          f"{len(ids)}-of-{len(ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
