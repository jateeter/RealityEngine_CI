#!/usr/bin/env bash
# Unit tests for scripts/lib/step_observer.py (RealityEngine_CI#375): a step is
# read at its completion point, and a step the observer did not cause is named.
set -euo pipefail
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$CI_DIR" <<'PY'
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts/lib")
from step_observer import StepObserver, StepNotResolved, StepNotRetained

passed = failed = 0
def check(label, ok):
    global passed, failed
    print(("  PASS: " if ok else "  FAIL: ") + label)
    passed, failed = passed + bool(ok), failed + (not ok)

def pair(n):
    return {"stepNumber": n, "isre": {"stepNumber": n, "length": 4, "nonZero": []},
            "osre": {"stepNumber": n, "length": 4, "nonZero": [{"index": 1, "value": 1}]}}

calls = []
def get_ok(url):
    calls.append(url)
    n = int(url.split("/steps/")[1].split("/")[0])
    return 200, pair(n)

obs = StepObserver(get_ok, "http://re/", window_ms=1234)
isre, osre = obs.observe_push({"step": {"stepNumber": 0}})
check("the pair for the pushed step is returned", isre["stepNumber"] == 0 and osre["stepNumber"] == 0)
check("the wait names the step and the window", calls[-1] == "http://re/api/engine/steps/0/pair?timeoutMs=1234")
obs.observe_push({"step": {"stepNumber": 1}})
check("contiguous steps raise no violation", obs.violations == [] and sorted(obs.pairs) == [0, 1])
obs.observe_push({"step": {"stepNumber": 4}})
check("an interloper is named by step number", len(obs.violations) == 1 and "[2, 3]" in obs.violations[0])

for status, exc in ((408, StepNotResolved), (410, StepNotRetained)):
    o = StepObserver(lambda url, s=status: (s, {"error": "x"}), "http://re")
    try:
        o.await_pair(7); check(f"{status} raises", False)
    except exc:
        check(f"{status} raises {exc.__name__}", True)

o = StepObserver(lambda url: (200, pair(9)), "http://re")
try:
    o.await_pair(8); check("a reply for another step is refused", False)
except RuntimeError:
    check("a reply for another step is refused", True)

try:
    StepObserver(get_ok, "http://re").observe_push({"globalStep": 3})
    check("a push without step.stepNumber is refused", False)
except RuntimeError:
    check("a push without step.stepNumber is refused", True)

print(f"\nTotals: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
