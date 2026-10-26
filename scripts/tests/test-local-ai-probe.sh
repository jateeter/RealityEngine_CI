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
# Stub pids go to a file, not an array: spawn runs as PORT=$(spawn ...), a
# subshell, so an array it appended to was the subshell's copy and the trap
# found it empty. Every run left its six stubs listening, orphaned to launchd.
PIDFILE="$TMP/stub.pids"
cleanup() {
  if [ -f "$PIDFILE" ]; then
    while read -r p; do kill "$p" 2>/dev/null || true; done < "$PIDFILE"
  fi
  rm -rf "$TMP"
}
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
  echo "$!" >> "$PIDFILE"
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

# A containerized PE reports the Mac's Ollama as host.docker.internal, which
# only containers resolve. The probe asks the same Ollama at --ollama-url
# (run e1-20261019c reported "could not list installed models" here).
printf '{"reachable":true,"model":"gpt-oss:20b","baseUrl":"http://host.docker.internal:11434"}\n' > "$TMP/pe-docker.json"
PE_DOCKER=$(spawn "$TMP/pe-docker.json")
registry "$TMP/reg-docker.json" "$PE_DOCKER"
set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-docker.json" --localai-url "http://127.0.0.1:$STACK" \
  --ollama-url "http://127.0.0.1:$OLLAMA" --out "$TMP/docker.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "0" "a PE's host.docker.internal Ollama is checked at --ollama-url"
assert_eq "$(python3 -c "import json;print(len(json.load(open('$TMP/docker.json'))['installedModels']))")" "2" \
  "and its installed models are listed"

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

# ── Check 5: --agent-turn ──────────────────────────────────────────────────
# A routed stub: GET and POST by path. A PE's agent sensor either advances its
# lastUpdated on every read (the turn wrote it) or holds it (it did not).
cat > "$TMP/routed.py" <<'PYEOF'
import json, sys, itertools
from http.server import BaseHTTPRequestHandler, HTTPServer
port = int(sys.argv[1]); routes = json.load(open(sys.argv[2]))
tick = itertools.count(1000)
class H(BaseHTTPRequestHandler):
    def reply(self):
        key = f"{self.command} {self.path}"
        r = routes.get(key)
        if r is None:
            self.send_response(404); self.end_headers(); return
        body = r["body"]
        if r.get("advance"):
            body = json.loads(json.dumps(body).replace('"__TICK__"', str(next(tick))))
        self.send_response(r.get("status", 200))
        self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_GET(self): self.reply()
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0))); self.reply()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
spawn_routed() {              # $1=routes-file -> echoes port
  local port
  port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 "$TMP/routed.py" "$port" "$1" >/dev/null 2>&1 &
  echo "$!" >> "$PIDFILE"
  for _ in $(seq 1 40); do
    curl -s "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
    sleep 0.1
  done
  echo "$port"
}
pe_routes() {                 # $1=out  $2=advance(true|false)
  python3 - "$1" "$2" "$OLLAMA" <<'PYEOF'
import json, sys
out, advance, ollama = sys.argv[1], sys.argv[2] == "true", sys.argv[3]
sensor = {"id": "source-x", "sensorId": "localai_agent_activity", "type": "sensor",
          "active": advance, "lastUpdated": "__TICK__" if advance else 5}
json.dump({
    "GET /api/integrations/ollama/status": {"body": {"reachable": True, "model": "gpt-oss:20b",
                                                     "baseUrl": f"http://127.0.0.1:{ollama}"}},
    "GET /api/sources": {"body": [{"id": "other", "type": "test"}, sensor], "advance": advance},
}, open(out, "w"))
PYEOF
}
stack_routes() {              # $1=out  $2=agent-status  $3=agent-body-json
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
json.dump({"GET /health": {"body": {"status": "ok"}},
           "POST /graph/agent": {"status": int(sys.argv[2]), "body": json.loads(sys.argv[3])}},
          open(sys.argv[1], "w"))
PYEOF
}
pe_routes "$TMP/pe-writes.json" true;  PE_WRITES=$(spawn_routed "$TMP/pe-writes.json")
pe_routes "$TMP/pe-silent.json" false; PE_SILENT=$(spawn_routed "$TMP/pe-silent.json")
stack_routes "$TMP/st-good.json" 200 '{"answer":"Low HRV suggests incomplete recovery.","tool_calls_made":1}'
stack_routes "$TMP/st-notool.json" 200 '{"answer":"Low HRV suggests incomplete recovery.","tool_calls_made":0}'
stack_routes "$TMP/st-500.json" 500 '{"detail":"Internal Server Error"}'
ST_GOOD=$(spawn_routed "$TMP/st-good.json")
ST_NOTOOL=$(spawn_routed "$TMP/st-notool.json")
ST_500=$(spawn_routed "$TMP/st-500.json")

registry "$TMP/reg-writes.json" "$PE_WRITES" "$PE_WRITES"
OUT="$(python3 "$TOOL" --registry "$TMP/reg-writes.json" --localai-url "http://127.0.0.1:$ST_GOOD" --agent-turn --out "$TMP/turn-ok.json" 2>&1)"; CODE=$?
assert_eq "$CODE" "0" "an answered agent turn that wrote every PE passes"
assert_contains "$OUT" "1 tool call(s), localai_agent_activity written on 2 PE(s)" "reports the turn"

# localAIStack#145: the tools node raised on every turn that called a tool.
set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-writes.json" --localai-url "http://127.0.0.1:$ST_500" --agent-turn --out "$TMP/turn-500.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "an agent turn that errors fails the stage"
assert_contains "$OUT" "agent turn failed" "names the agent turn"

set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-writes.json" --localai-url "http://127.0.0.1:$ST_NOTOOL" --agent-turn --out "$TMP/turn-notool.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "a turn that called no tool fails"
assert_contains "$OUT" "tools node was not exercised" "says the tools node went unexercised"

registry "$TMP/reg-silent.json" "$PE_WRITES" "$PE_SILENT"
set +e
OUT="$(python3 "$TOOL" --registry "$TMP/reg-silent.json" --localai-url "http://127.0.0.1:$ST_GOOD" --agent-turn --out "$TMP/turn-silent.json" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "a PE the turn did not write fails"
assert_contains "$OUT" "rt-2: the agent turn did not write localai_agent_activity" "names that PE"

# Without --agent-turn the stage is what it was: no POST is made.
OUT="$(python3 "$TOOL" --registry "$TMP/reg-writes.json" --localai-url "http://127.0.0.1:$ST_500" --out "$TMP/turn-off.json" 2>&1)"; CODE=$?
assert_eq "$CODE" "0" "no --agent-turn, no agent turn"
assert_eq "$(python3 -c "import json;print('agentTurn' in json.load(open('$TMP/turn-off.json')))")" "False" "and none is reported"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
