#!/usr/bin/env bash
# Unit tests for scripts/regression-machine-set-parity.py.
#
# This gate exists because a correct machine-set comparison already lived inside
# regression-reset-contract.py and could not fire (#356). A replacement that
# cannot fail would be the same defect wearing a new name, so every case here
# builds a corpus shape and asserts the exit status — the green case is one test
# out of several, and the rest are the proof that green means something.
#
# Usage: bash scripts/tests/test-machine-set-parity.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="$CI_DIR/scripts/regression-machine-set-parity.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill $(jobs -p) 2>/dev/null' EXIT

PASS=0
FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }

# A stub engine per runtime, each serving a fixed /api/machines payload. Real
# engines would make this an integration test; the comparison is the subject
# here, and it must be testable without a universe.
PORTS=()
start_stub() {  # start_stub <port> <name...>
  local port="$1"; shift
  local names="$1"
  python3 - "$port" "$names" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, names = int(sys.argv[1]), sys.argv[2]
machines = [{"id": f"machine-{port}-{i}", "name": n}
            for i, n in enumerate(names.split(",")) if n]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"machines": machines}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  PORTS+=("$port")
  for _ in $(seq 1 50); do
    curl -sf --max-time 1 "http://127.0.0.1:$port/api/machines" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

registry() {  # registry <port> <port> <port>
  python3 - "$@" > "$TMP/registry.json" <<'PY'
import json, sys
print(json.dumps({"instances": [
    {"id": rid, "runtime": rid.split("-")[0],
     "re_url": f"http://127.0.0.1:{port}", "pe_url": f"http://127.0.0.1:{port}"}
    for rid, port in zip(("cpp-1", "lsp-1", "scala-1"), sys.argv[1:])]}))
PY
}

run_stage() { python3 "$STAGE" --registry "$TMP/registry.json" >"$TMP/out" 2>&1; }

echo "regression-machine-set-parity.py"

start_stub 5891 "Alpha,Beta,Gamma" || { echo "stub 5891 failed"; exit 1; }
start_stub 5892 "Alpha,Beta,Gamma" || { echo "stub 5892 failed"; exit 1; }
start_stub 5893 "Alpha,Beta,Gamma" || { echo "stub 5893 failed"; exit 1; }

# ── identical corpora pass ───────────────────────────────────────────────────
registry 5891 5892 5893
if run_stage; then ok "three runtimes holding the same machines pass"
else bad "identical corpora were reported as a split"; sed 's/^/        /' "$TMP/out"; fi

# ── one extra machine is a split, and the machine is NAMED ───────────────────
# A count difference says a split exists; the name says which machine to look
# at, and that is the difference between a finding and a ticket someone has to
# reproduce.
start_stub 5894 "Alpha,Beta,Gamma,Delta" || { echo "stub 5894 failed"; exit 1; }
registry 5891 5892 5894
if run_stage; then
  bad "an extra machine on one runtime was not caught"
else
  if grep -q "Delta" "$TMP/out" && grep -q "absent from cpp-1+lsp-1" "$TMP/out"; then
    ok "an extra machine is caught, and named with who holds it"
  else
    bad "caught, but did not name the machine"; sed 's/^/        /' "$TMP/out"
  fi
fi

# ── same COUNT, different machines ───────────────────────────────────────────
# The case a count check misses entirely, and the reason this compares sets.
start_stub 5895 "Alpha,Beta,Omega" || { echo "stub 5895 failed"; exit 1; }
registry 5891 5892 5895
if run_stage; then
  bad "same count with different machines was not caught"
else
  if grep -q "Gamma" "$TMP/out" && grep -q "Omega" "$TMP/out"; then
    ok "same count, different machines is caught and both are named"
  else
    bad "caught, but did not name both sides"; sed 's/^/        /' "$TMP/out"
  fi
fi

# ── a runtime that will not answer is not agreement ──────────────────────────
# Quorum is 3-of-3. A dead engine must not read as a split, and two dead engines
# must not agree with each other.
registry 5891 5892 5999
if run_stage; then
  bad "an unreachable runtime was treated as agreement"
else
  if grep -q "QUORUM NOT FORMED" "$TMP/out"; then
    ok "an unreachable runtime refuses the comparison rather than reporting parity"
  else
    bad "failed, but not as a quorum refusal"; sed 's/^/        /' "$TMP/out"
  fi
fi

# ── duplicates on ONE runtime are reported ───────────────────────────────────
# Not a cross-runtime finding, but it makes the set comparison lie by one, so it
# must not be silently deduplicated.
start_stub 5896 "Alpha,Beta,Gamma,Gamma" || { echo "stub 5896 failed"; exit 1; }
registry 5891 5892 5896
run_stage
if grep -q "duplicates on one runtime" "$TMP/out"; then
  ok "duplicate names on a single runtime are reported"
else
  bad "duplicates on one runtime were silently deduplicated"; sed 's/^/        /' "$TMP/out"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "machine-set-parity: $PASS passed, $FAIL FAILED"
  exit 1
fi
echo "machine-set-parity: $PASS passed"
