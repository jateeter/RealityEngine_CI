#!/usr/bin/env bash
# Unit tests for scripts/regression-local-ai.py — stub HTTP, no Ollama.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/regression-local-ai.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}
assert_contains() {
  case "$1" in *"$2"*) echo "  PASS: $3"; PASS=$((PASS+1)) ;;
  *) echo "  FAIL: $3"; echo "        wanted: $2"; echo "        got: $(echo "$1" | head -c 300)"; FAIL=$((FAIL+1)) ;; esac
}

TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

# A stub that serves one fixed JSON body on every path.
cat > "$TMP/stub.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port = int(sys.argv[1]); body = open(sys.argv[2]).read()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

spawn() {                     # $1=body-file -> echoes port
  local port
  port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 "$TMP/stub.py" "$port" "$1" >/dev/null 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 40); do
    curl -sf "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
    sleep 0.1
  done
  echo "$port"
}

registry() {                  # $1=out  $2..=pe ports
  local out="$1"; shift
  local entries="" i=1
  for p in "$@"; do
    [ -n "$entries" ] && entries="$entries,"
    entries="$entries{\"id\":\"rt-$i\",\"runtime\":\"rt$i\",\"pe_url\":\"http://127.0.0.1:$p\"}"
    i=$((i+1))
  done
  printf '{"host":"127.0.0.1","instances":[%s]}\n' "$entries" > "$out"
}

echo "local-ai probe"

printf '{"status":"ok"}\n' > "$TMP/stack-ok.json"
# baseUrl points at the stub Ollama, filled in once its port is known.
printf '{"reachable":false,"model":"gpt-oss:20b","error":"connection refused"}\n' > "$TMP/pe-down.json"
# pe-othermodel.json is written after the Ollama stub port is known too.

# A stub Ollama that has gpt-oss:20b installed but not llama3.2.
printf '{"models":[{"name":"gpt-oss:20b"},{"name":"nomic-embed-text:latest"}]}\n' > "$TMP/ollama.json"
OLLAMA=$(spawn "$TMP/ollama.json")

printf '{"reachable":true,"model":"gpt-oss:20b","baseUrl":"http://127.0.0.1:%s"}\n' "$OLLAMA" > "$TMP/pe-ok.json"
printf '{"reachable":true,"model":"llama3.2","baseUrl":"http://127.0.0.1:%s"}\n' "$OLLAMA" > "$TMP/pe-othermodel.json"
printf '{"reachable":true,"model":"missing-model:70b","baseUrl":"http://127.0.0.1:%s"}\n' "$OLLAMA" > "$TMP/pe-nomodel.json"

STACK=$(spawn "$TMP/stack-ok.json")
PE_OK=$(spawn "$TMP/pe-ok.json")
PE_DOWN=$(spawn "$TMP/pe-down.json")
PE_OTHER=$(spawn "$TMP/pe-othermodel.json")
PE_NOMODEL=$(spawn "$TMP/pe-nomodel.json")

# Healthy: stack up, every PE reachable, one model.
registry "$TMP/reg-ok.json" "$PE_OK" "$PE_OK"
OUT="$(python3 "$TOOL" --registry "$TMP/reg-ok.json" --localai-url "http://127.0.0.1:$STACK" --out "$TMP/ok.json" 2>&1)"; CODE=$?
assert_eq "$CODE" "0" "healthy stack and providers pass"
assert_contains "$OUT" "PASS local AI" "reports a pass"
assert_eq "$(python3 -c "import json;print(json.load(open('$TMP/ok.json'))['status'])")" "passed" "report says passed"

# A PE that answers cleanly but reports the provider down is still a defect on
# a lane whose whole purpose is running that provider.
registry "$TMP/reg-down.json" "$PE_DOWN"
set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-down.json" --localai-url "http://127.0.0.1:$STACK" --out "$TMP/down.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "an orderly 'unreachable' still fails"
assert_contains "$OUT" "unreachable on a lane that starts it" "explains why that is a failure"

# Runtimes disagreeing on the model makes any comparison meaningless.
registry "$TMP/reg-split.json" "$PE_OK" "$PE_OTHER"
set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-split.json" --localai-url "http://127.0.0.1:$STACK" --out "$TMP/split.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "model disagreement fails"
assert_contains "$OUT" "disagree on the Ollama model" "names the disagreement"

# reachable:true is not enough — the configured model has to exist. This is
# the real-world case: on the first live run all three PEs reported reachable
# while pointing at models the local Ollama had never pulled.
registry "$TMP/reg-nomodel.json" "$PE_NOMODEL"
set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-nomodel.json" --localai-url "http://127.0.0.1:$STACK" --out "$TMP/nomodel.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "a reachable provider missing the configured model fails"
assert_contains "$OUT" "which is not installed" "names the missing model"
assert_contains "$OUT" "gpt-oss:20b" "lists what is available instead"

# Stack down, providers fine.
registry "$TMP/reg-ok2.json" "$PE_OK"
set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-ok2.json" --localai-url "http://127.0.0.1:1" --out "$TMP/nostack.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "an unreachable localAIStack fails"
assert_contains "$OUT" "localAIStack health failed" "names the stack"

# An empty registry must not pass by having nothing to check.
printf '{"host":"127.0.0.1","instances":[]}\n' > "$TMP/reg-empty.json"
set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-empty.json" --localai-url "http://127.0.0.1:$STACK" --out "$TMP/empty.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "no instances is a failure, not a pass"
assert_contains "$OUT" "no PE instances" "says the registry was empty"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
