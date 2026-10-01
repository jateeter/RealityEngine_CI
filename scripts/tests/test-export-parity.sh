#!/usr/bin/env bash
# Unit tests for scripts/regression-export-parity.py.
#
# The gate exists because every export defect so far was found by hand-diffing:
# Scala#104 (4 missing event fields), LSP#104 (timestamp hardcoded to 0), and
# the four in #436 — one of which, a dropped `outputMergeTransformation`, made a
# machine come back with a different fold on re-ingestion.
#
# So the cases below reproduce those shapes on stub engines and assert the gate
# goes red and NAMES the path. A gate that cannot fail would leave the surface
# exactly as unguarded as it was.
#
# Usage: bash scripts/tests/test-export-parity.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="$CI_DIR/scripts/regression-export-parity.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill $(jobs -p) 2>/dev/null' EXIT

PASS=0
FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }

# A stub engine serving /api/machines and /api/machines/:id/export, with the
# export body supplied per runtime so a case can perturb exactly one field.
#
# It also answers the two resets the stage issues before exporting (#464). The
# optional third file is what the export becomes after `POST /api/engine/reset`
# — a runtime that was driven before the stage and returns to its loaded state.
# A fourth argument of `fail` makes the RE reset answer 500.
start_stub() {  # start_stub <port> <machine-json-file> [<after-reset-json-file>] [fail]
  python3 - "$1" "$2" "${3:-}" "${4:-}" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, path, after, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
machine = json.load(open(path))
class H(BaseHTTPRequestHandler):
    def reply(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        if self.path == "/api/machines":
            body = {"machines": [{"id": f"machine-{port}", "name": machine["name"]}]}
        elif self.path.endswith("/export"):
            body = {"version": "1.0.0", "machine": dict(machine, id=f"machine-{port}")}
        else:
            self.send_response(404); self.end_headers(); return
        self.reply(200, body)
    def do_POST(self):
        global machine
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/api/engine/reset":
            if mode == "fail":
                return self.reply(500, {"error": "reset refused"})
            if after:
                machine = json.load(open(after))
            return self.reply(200, {"success": True})
        if self.path == "/api/reset":
            return self.reply(200, {"success": True})
        self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  for _ in $(seq 1 50); do
    curl -sf --max-time 1 "http://127.0.0.1:$1/api/machines" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

machine_json() {  # machine_json <file> <python-mutation>
  python3 - "$1" "$2" <<'PY'
import json, sys
m = {
    "name": "Probe Machine",
    "description": "export parity fixture",
    "arbiterRule": "PASSTHROUGH",
    "outputMergeTransformation": "or",
    "metadata": {},
    "perceptualMapping": {"input": {"offset": 0, "length": 2},
                          "output": {"offset": 20, "length": 2}},
    "sequences": [{"id": "seq-1", "name": "Seq One", "metadata": {},
                   "events": [
                       {"id": "ev-000", "isInitial": True, "elements": [{"value": 1.0}],
                        "outputEvents": [{"id": "out-1", "vector": [1, 0],
                                          "metadata": {}, "timestamp": 111}]},
                       {"id": "ev-001", "isInitial": False, "elements": [{"value": 0.0}],
                        "outputEvents": []}]}],
}
exec(sys.argv[2])
json.dump(m, open(sys.argv[1], "w"))
PY
}

registry() { # registry <p1> <p2> <p3>
  python3 - "$@" > "$TMP/registry.json" <<'PY'
import json, sys
print(json.dumps({"instances": [
    {"id": rid, "runtime": rid.split("-")[0],
     "re_url": f"http://127.0.0.1:{p}", "pe_url": f"http://127.0.0.1:{p}"}
    for rid, p in zip(("cpp-1", "lsp-1", "scala-1"), sys.argv[1:])]}))
PY
}

run_stage() { python3 "$STAGE" --registry "$TMP/registry.json" --machines 1 >"$TMP/out" 2>&1; }

echo "regression-export-parity.py"

machine_json "$TMP/base.json" "pass"
start_stub 5901 "$TMP/base.json" || { echo "stub failed"; exit 1; }
start_stub 5902 "$TMP/base.json" || { echo "stub failed"; exit 1; }
start_stub 5903 "$TMP/base.json" || { echo "stub failed"; exit 1; }
registry 5901 5902 5903

# ── identical exports pass ───────────────────────────────────────────────────
if run_stage; then ok "identical exports pass"
else bad "identical exports reported as differing"; sed 's/^/        /' "$TMP/out"; fi

# ── the engine-minted machine id must NOT split them ─────────────────────────
# Each stub reports its own `machine-<port>` id. If that were compared, every
# run would fail unconditionally — which is the defect #146 records.
if run_stage && ! grep -q "machine.id" "$TMP/out"; then
  ok "the engine-minted machine id is excluded, not compared"
else
  bad "the minted machine id leaked into the comparison"; sed 's/^/        /' "$TMP/out"
fi

# ── a dropped field is caught and NAMED ──────────────────────────────────────
# The #436 defect that lost data: a machine exported without its fold came back
# as the default `or` on re-ingestion, silently retuning a training variable.
machine_json "$TMP/nofold.json" "m.pop('outputMergeTransformation')"
start_stub 5904 "$TMP/nofold.json" || { echo "stub failed"; exit 1; }
registry 5901 5902 5904
if run_stage; then
  bad "a dropped outputMergeTransformation was not caught"
else
  if grep -q "outputMergeTransformation" "$TMP/out"; then
    ok "a dropped field is caught and named"
  else
    bad "caught, but did not name the field"; sed 's/^/        /' "$TMP/out"
  fi
fi

# ── reordered events are caught ──────────────────────────────────────────────
# The subtlest of the four: the same events in a different order. A set
# comparison calls this equal; a consumer reading events positionally does not.
machine_json "$TMP/reordered.json" "m['sequences'][0]['events'].reverse()"
start_stub 5905 "$TMP/reordered.json" || { echo "stub failed"; exit 1; }
registry 5901 5902 5905
if run_stage; then
  bad "reordered events were not caught"
else
  if grep -q "events\[0\].id" "$TMP/out"; then
    ok "reordered events are caught, by path and index"
  else
    bad "caught, but not attributed to the event positions"; sed 's/^/        /' "$TMP/out"
  fi
fi

# ── load timestamps must NOT split them ──────────────────────────────────────
# Stamped at ingestion, so two engines started at different times always differ.
# Comparing them would make the gate fail on every healthy universe.
machine_json "$TMP/latertime.json" "m['sequences'][0]['events'][0]['outputEvents'][0]['timestamp'] = 999999"
start_stub 5906 "$TMP/latertime.json" || { echo "stub failed"; exit 1; }
registry 5901 5902 5906
if run_stage; then ok "load timestamps are excluded, not compared"
else bad "a load timestamp split the runtimes"; sed 's/^/        /' "$TMP/out"; fi

# ── a corpus-declared id IS compared ─────────────────────────────────────────
# The distinction that makes this gate different from parity_identity: in an
# export, sequence and event ids are corpus-declared and are the most important
# thing to compare. Only .machine.id is minted.
machine_json "$TMP/renamed.json" "m['sequences'][0]['events'][0]['id'] = 'ev-renamed'"
start_stub 5907 "$TMP/renamed.json" || { echo "stub failed"; exit 1; }
registry 5901 5902 5907
if run_stage; then
  bad "a changed corpus-declared event id was not caught"
else
  ok "a corpus-declared event id is compared"
fi

# ── a runtime that will not answer is not agreement ──────────────────────────
registry 5901 5902 5999
if run_stage; then
  bad "an unreachable runtime was treated as agreement"
else
  if grep -q "QUORUM NOT FORMED" "$TMP/out"; then
    ok "an unreachable runtime refuses the comparison rather than reporting parity"
  else
    bad "failed, but not as a quorum refusal"; sed 's/^/        /' "$TMP/out"
  fi
fi

# ── run state is compared after a reset, not before (#464) ───────────────────
# The hosted bridges drive the runtimes unequally before they are muted, so one
# arrives with a match the others never saw. The stage resets first, and a
# runtime whose reset returns the event to its loaded state agrees.
machine_json "$TMP/driven.json" "m['sequences'][0]['events'][0]['wasJustMatched'] = True"
machine_json "$TMP/loaded.json" "m['sequences'][0]['events'][0]['wasJustMatched'] = False"
start_stub 5908 "$TMP/loaded.json" || { echo "stub failed"; exit 1; }
start_stub 5909 "$TMP/loaded.json" || { echo "stub failed"; exit 1; }
start_stub 5910 "$TMP/driven.json" "$TMP/loaded.json" || { echo "stub failed"; exit 1; }
registry 5908 5909 5910
if run_stage; then ok "a runtime driven before the stage agrees once reset"
else bad "the stage compared drive history instead of resetting first"; sed 's/^/        /' "$TMP/out"; fi

# ── a reset that keeps the match is caught, with every runtime's value ───────
# SURFACE_SPEC: reset clears wasJustMatched. A runtime that keeps it is the
# finding, and the report carries all three values — no runtime is the baseline
# the others are diffed against, so the agreeing pair is named too.
start_stub 5911 "$TMP/driven.json" || { echo "stub failed"; exit 1; }
registry 5908 5909 5911
if run_stage; then
  bad "a reset that kept wasJustMatched was not caught"
else
  if grep -q "wasJustMatched: cpp-1='False', lsp-1='False', scala-1='True'" "$TMP/out"; then
    ok "a kept match is caught and every runtime's value is reported"
  else
    bad "caught, but not reported with all three values"; sed 's/^/        /' "$TMP/out"
  fi
fi

# ── a runtime that will not reset is not compared ────────────────────────────
start_stub 5912 "$TMP/base.json" "" fail || { echo "stub failed"; exit 1; }
registry 5901 5902 5912
if run_stage; then
  bad "a failed reset was compared anyway"
else
  if grep -q "NOT COMPARED" "$TMP/out"; then
    ok "a runtime that did not reset refuses the comparison"
  else
    bad "failed, but not as a reset refusal"; sed 's/^/        /' "$TMP/out"
  fi
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "export-parity: $PASS passed, $FAIL FAILED"
  exit 1
fi
echo "export-parity: $PASS passed"
