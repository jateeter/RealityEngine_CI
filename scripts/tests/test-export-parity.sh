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
start_stub() {  # start_stub <port> <machine-json-file>
  python3 - "$1" "$2" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, path = int(sys.argv[1]), sys.argv[2]
machine = json.load(open(path))
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/machines":
            body = {"machines": [{"id": f"machine-{port}", "name": machine["name"]}]}
        elif self.path.endswith("/export"):
            body = {"version": "1.0.0", "machine": dict(machine, id=f"machine-{port}")}
        else:
            self.send_response(404); self.end_headers(); return
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers(); self.wfile.write(raw)
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

echo
if [ "$FAIL" -ne 0 ]; then
  echo "export-parity: $PASS passed, $FAIL FAILED"
  exit 1
fi
echo "export-parity: $PASS passed"
