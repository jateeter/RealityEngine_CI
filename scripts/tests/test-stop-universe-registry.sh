#!/usr/bin/env bash
# stopUniverse.sh is driven by the current instance registry, not by the stamp.
#
# A universe started from a regression run worktree leaves its
# .universe-engine-selection stamp there. Teardown from the main checkout found
# no stamp, never stopped the instances the instance registry listed, and
# printed "Universe shutdown complete" over six live engines on free ports and
# a live shim (opt3-1456, 2026-10-05).
#
# Sandboxed: stopUniverse.sh runs from a scratch CI directory with no stamp, no
# .env and no sibling repos; the instance registry, every PID file and every
# port base point into the sandbox, and --re-engine/--pe-engine=cpp keep the
# AI-stack, Manager and Ollama steps out of it. The "engines" are local
# listeners on free ports.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
# A file, not an array: the listeners are started inside $(...), whose
# assignments never reach this shell.
LISTENERS="$TMP/listeners"
cleanup() {
  local p
  if [ -f "$LISTENERS" ]; then
    while read -r p; do kill -KILL "$p" 2>/dev/null || true; done < "$LISTENERS"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }

SANDBOX="$TMP/ci"
mkdir -p "$SANDBOX/scripts/lib" "$TMP/registry"
cp "$CI_DIR/stopUniverse.sh" "$SANDBOX/"
cp "$CI_DIR/scripts/registry.sh" "$SANDBOX/scripts/"
cp "$CI_DIR/scripts/lib/stack-owner.sh" "$SANDBOX/scripts/lib/"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# An engine-shaped listener (its command line names http.server, as the shim's does).
engine_listener() {  # <port> -> pid
  python3 -m http.server --bind 127.0.0.1 "$1" >/dev/null 2>&1 &
  echo "$!" >> "$LISTENERS"; echo "$!"
}
# A listener that is neither an engine nor the shim.
other_listener() {  # <port> -> pid
  python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(); time.sleep(600)' "$1" >/dev/null 2>&1 &
  echo "$!" >> "$LISTENERS"; echo "$!"
}
wait_listening() {  # <port>
  local n=0
  while ! lsof -ti ":$1" -sTCP:LISTEN >/dev/null 2>&1 && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
}
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

REG="$TMP/registry/re-registry.json"
run_stop_with() {  # [stopUniverse.sh args...]
  env RE_REGISTRY_FILE="$REG" RE_REGISTRY_PID_FILE="$TMP/registry-server.pid" \
      RE_REGISTRY_PORT="$(free_port)" \
      CPP_PE_BASE="$(free_port)" LSP_PE_BASE="$(free_port)" SCALA_PE_BASE="$(free_port)" \
      MCP_HTTP_PID_FILE="$TMP/mcp.pid" OPENAPI_SWAGGER_PID_FILE="$TMP/swagger.pid" \
      BRIDGE_METRICS_PID_FILE="$TMP/metrics.pid" \
      MANAGER_UNIVERSE_PID_FILE="$TMP/manager.pid" OLLAMA_UNIVERSE_PID_FILE="$TMP/ollama.pid" \
      bash "$SANDBOX/stopUniverse.sh" "$@" 2>&1
}
run_stop() { run_stop_with --re-engine=cpp --pe-engine=cpp; }

echo "no stamp, free ports: the instance registry's instances and shim are stopped"
P1=$(free_port); P2=$(free_port); P3=$(free_port); P4=$(free_port); PS=$(free_port)
R1=$(engine_listener "$P1"); E1=$(engine_listener "$P2")
R2=$(engine_listener "$P3"); E2=$(engine_listener "$P4")
SHIM=$(engine_listener "$PS")   # a shim no PID file knows about
for p in "$P1" "$P2" "$P3" "$P4" "$PS"; do wait_listening "$p"; done
cat > "$REG" <<JSON
{"host":"127.0.0.1",
 "instances":[
  {"id":"cpp-1","runtime":"cpp","re_port":$P1,"pe_port":$P2,"pid_re":$R1,"pid_pe":$E1},
  {"id":"lsp-1","runtime":"lsp","re_port":$P3,"pe_port":$P4,"pid_re":$R2,"pid_pe":$E2}],
 "services":{"registry":{"url":"http://127.0.0.1:$PS","port":$PS}}}
JSON
check "$([ -e "$SANDBOX/.universe-engine-selection" ] && echo stamp || echo none)" none "the sandbox has no stamp"
set +e; out=$(run_stop); rc=$?; set -e
check "$rc" 0 "teardown exits 0"
check "$(grep -c 'Instance registry .*: cpp-1 lsp-1' <<<"$out")" 1 "names the instances it read from the instance registry"
check "$(grep -c 'Stopped instance: cpp-1' <<<"$out")" 1 "stops cpp-1 without a stamp"
check "$(grep -c 'Stopped instance: lsp-1' <<<"$out")" 1 "stops lsp-1 without a stamp"
check "$(alive "$R1")$(alive "$E1")$(alive "$R2")$(alive "$E2")" nononono "every registered PID is gone"
check "$(alive "$SHIM")" no "the shim on its free port is gone"
check "$([ -e "$REG" ] && echo present || echo removed)" removed "the instance registry file is removed"
check "$(grep -c 'Universe shutdown complete' <<<"$out")" 1 "and only then reports a complete shutdown"

echo "a registered port held by something that is not an engine is reported, not killed"
P5=$(free_port); P6=$(free_port)
OTHER=$(other_listener "$P6"); wait_listening "$P6"
cat > "$REG" <<JSON
{"host":"127.0.0.1",
 "instances":[{"id":"scala-1","runtime":"scala","re_port":$P5,"pe_port":$P6,"pid_re":null,"pid_pe":null}],
 "services":{}}
JSON
set +e; out=$(run_stop); rc=$?; set -e
check "$rc" 1 "teardown exits 1"
check "$(grep -q "Registered port $P6 is held by PID $OTHER" <<<"$out" && echo named)" named "names the port and its holder"
check "$(alive "$OTHER")" yes "and leaves it running"
check "$(grep -c 'Universe shutdown INCOMPLETE' <<<"$out")" 1 "and does not report a complete shutdown"

echo "no instance registry: nothing registered to stop"
rm -f "$REG"
set +e; out=$(run_stop); rc=$?; set -e
check "$rc" 0 "teardown exits 0"
check "$(grep -c 'Stopped instance' <<<"$out")" 0 "stops no instance"

echo "a multi-engine stamp: the header names its engines, and the AI stack stops once"
# The stamp of a --engines universe carries RE_ENGINE=ai beside ENGINES=, so the
# header announced the single ai pair and Manager's stop ran twice. A stub
# Manager stop.sh in the sandbox counts its calls; OPENCLAW=no and the default
# (no --stop-docker) keep OpenClaw and Docker out of it.
mkdir -p "$TMP/RealityEngine_Manager"
printf '#!/usr/bin/env bash\necho "STUB MANAGER STOP"\n' > "$TMP/RealityEngine_Manager/stop.sh"
chmod +x "$TMP/RealityEngine_Manager/stop.sh"
printf 'RE_ENGINE=ai\nPE_ENGINE=ai\nENGINES=cpp:1,lsp:1,scala:1\nMULTI_ENGINE_MODE=true\nOPENCLAW=no\n' \
  > "$SANDBOX/.universe-engine-selection"
set +e; out=$(run_stop_with); rc=$?; set -e
check "$rc" 0 "teardown exits 0"
check "$(grep -c 'Engine selection: ENGINES=cpp:1,lsp:1,scala:1' <<<"$out")" 1 "the header names the engines launched"
check "$(grep -c 'RE_ENGINE=ai' <<<"$out")" 0 "and not the ai pair the stamp also carries"
check "$(grep -c 'STUB MANAGER STOP' <<<"$out")" 1 "Manager is stopped once, not twice"
check "$([ -e "$SANDBOX/.universe-engine-selection" ] && echo present || echo removed)" removed "the stamp is removed"

echo "no stamp: the header says the instance registry decides"
set +e; out=$(run_stop); rc=$?; set -e
check "$(grep -c 'no stamp in this checkout' <<<"$out")" 1 "the header says there is no stamp here"

echo ""
echo "stop-universe-registry: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
