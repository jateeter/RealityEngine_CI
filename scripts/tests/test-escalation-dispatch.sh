#!/usr/bin/env bash
# Unit tests for scripts/regression-escalation-dispatch.py: the counter parse,
# the ledger grouping and the verdict. No engines, no network.
#
# semantic_escalation_dispatches_total sat at zero on every runtime, which is
# also what an engine that never counts reports, and no stage read it. The
# stage compares what one drive did to it across the runtimes; these pin what
# it reads and what it fails on.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/regression-escalation-dispatch.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/run.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ed", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
case = json.load(sys.stdin)
what = sys.argv[2]
if what == "parse":
    print(json.dumps(m.parse_escalations(case["text"]), sort_keys=True))
elif what == "delta":
    print(json.dumps(m.delta(case["after"], case["before"]), sort_keys=True))
elif what == "ledger":
    print(json.dumps(m.ledger_by_machine(case["records"]), sort_keys=True))
else:
    print(json.dumps(m.evaluate(case["esc"], case.get("machines", {}), case.get("comparable", True),
                                case.get("expect", False))))
PYEOF
py() { python3 "$TMP/run.py" "$TOOL" "$1"; }
field() { python3 -c "import json,sys; v=json.load(sys.stdin)$1; print(v if isinstance(v,(str,int)) else json.dumps(v))"; }

echo "== parse_escalations =="

TEXT='# HELP semantic_escalation_dispatches_total Escalation-class actions dispatched, by RAG status of the determination.\n# TYPE semantic_escalation_dispatches_total counter\nsemantic_escalation_dispatches_total{rag=\"RED\",runtime=\"cpp\"} 21\nsemantic_escalation_dispatches_total{runtime=\"lsp\",rag=\"unstated\"} 2\nsemantic_dispatch_records_total{runtime=\"cpp\"} 40\n'
assert_eq "$(printf '{"text":"%s"}' "$TEXT" | py parse)" '{"RED": 21, "unstated": 2}' \
  "reads every rag series in any label order, and nothing else"
assert_eq "$(printf '{"text":"semantic_dispatch_records_total 3\\n"}' | py parse)" '{}' \
  "an exposition without the counter reads as no escalations"

echo "== delta =="

assert_eq "$(printf '{"after":{"RED":26},"before":{"RED":21}}' | py delta)" '{"RED": 5}' \
  "the counter is never reset, so only the drive's change counts"
assert_eq "$(printf '{"after":{"RED":21},"before":{"RED":21}}' | py delta)" '{}' \
  "an unchanged counter is no escalation"
assert_eq "$(printf '{"after":{"RED":3,"AMBER":1},"before":{}}' | py delta)" '{"AMBER": 1, "RED": 3}' \
  "a series that first appears in the drive counts from zero"

echo "== ledger_by_machine =="

R='{"id":"%s","machineId":"%s","semantics":{"actionCode":"%s"}}'
recs="[$(printf "$R" 1 m-a urgent-intervention),$(printf "$R" 2 m-a urgent-intervention),$(printf "$R" 3 m-b emergency-dispatch),$(printf "$R" 4 m-c notify)]"
assert_eq "$(printf '{"records":%s}' "$recs" | py ledger)" \
  '{"m-a": {"urgent-intervention": 2}, "m-b": {"emergency-dispatch": 1}}' \
  "escalation-class records only, by machine and action"

echo "== evaluate =="

AGREE='{"cpp-1":{"RED":5},"lsp-1":{"RED":5},"scala-1":{"RED":5}}'
assert_eq "$(printf '{"esc":%s,"expect":true}' "$AGREE" | py evaluate)" "[]" \
  "three runtimes escalating alike at RED pass"

r="$(printf '{"esc":{"cpp-1":{"RED":5},"lsp-1":{"RED":4},"scala-1":{"RED":5}}}' | py evaluate)"
assert_eq "$(field '[0]' <<<"$r")" \
  'escalation counter deltas disagree across runtimes: cpp-1+scala-1 | lsp-1 (cpp-1+scala-1={"RED": 5}; lsp-1={"RED": 4})' \
  "a split is reported as clusters with every party's value, none as the reference"

r="$(printf '{"esc":{"cpp-1":{},"lsp-1":{},"scala-1":{}},"expect":true}' | py evaluate)"
assert_eq "$(field '[0]' <<<"$r" | cut -c1-40)" "cpp-1: the drive escalated nothing at RE" \
  "with --expect-escalation, three runtimes agreeing on zero still fail"
assert_eq "$(printf '{"esc":{"cpp-1":{},"lsp-1":{},"scala-1":{}}}' | py evaluate)" "[]" \
  "without it, agreeing on zero passes"

r="$(printf '{"esc":{"cpp-1":{"AMBER":1},"lsp-1":{"AMBER":1},"scala-1":{"AMBER":1}}}' | py evaluate)"
assert_eq "$(field '[0]' <<<"$r")" \
  "cpp-1: escalation under a non-RED status {'AMBER': 1} — re:EscalationDetermination requires RED" \
  "an escalation under an explicit non-RED status fails even when unanimous"
assert_eq "$(printf '{"esc":{"cpp-1":{"unstated":1},"lsp-1":{"unstated":1}}}' | py evaluate)" "[]" \
  "an unstated status is open-world, not a violation"

M='{"cpp-1":{"m-a":{"urgent-intervention":2}},"lsp-1":{"m-a":{"urgent-intervention":1},"m-b":{"urgent-intervention":1}}}'
E='{"cpp-1":{"RED":2},"lsp-1":{"RED":2}}'
r="$(printf '{"esc":%s,"machines":%s}' "$E" "$M" | py evaluate)"
assert_eq "$(field '[0]' <<<"$r" | cut -c1-62)" "escalating machines (dispatch ledger) disagree across runtimes" \
  "equal totals from different machines are a disagreement"
assert_eq "$(printf '{"esc":%s,"machines":%s,"comparable":false}' "$E" "$M" | py evaluate)" "[]" \
  "a ledger the ring evicted is not compared per machine"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
