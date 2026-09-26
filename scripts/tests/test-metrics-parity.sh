#!/usr/bin/env bash
# Unit tests for scripts/verify-metrics-parity.sh — no engines required.
#
# Serves fixture expositions and an instance registry from a local HTTP server
# and checks the verdicts: state asymmetry in lazy multi-series counters is
# reported, not scored as drift (RealityEngine_Machines#126), while real
# exposition drift in a shared series still fails.
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
PASS=0; FAIL=0
cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

block() {  # block <runtime> <integration...>
  local rt="$1"; shift
  cat <<EOF
# HELP semantic_manifest_available Corpus OWL semantics manifest resolved (1/0).
# TYPE semantic_manifest_available gauge
semantic_manifest_available{runtime="$rt"} 1
# HELP semantic_manifest_machines Machines carrying a semantic identity in the manifest.
# TYPE semantic_manifest_machines gauge
semantic_manifest_machines{runtime="$rt"} 12
# HELP semantic_audit_buffer_records re:PerceptionEvent records held in the audit ring buffer.
# TYPE semantic_audit_buffer_records gauge
semantic_audit_buffer_records{runtime="$rt"} 3
EOF
  local i
  for i in "$@"; do
    cat <<EOF
# HELP semantic_perception_events_total re:PerceptionEvent records emitted, by originating integration.
# TYPE semantic_perception_events_total counter
semantic_perception_events_total{integration="$i",runtime="$rt"} 7
EOF
  done
  cat <<EOF
# HELP semantic_dispatch_records_total Dispatch records created with a semantics link.
# TYPE semantic_dispatch_records_total counter
semantic_dispatch_records_total{runtime="$rt"} 0
# HELP semantic_dispatch_records_iri_joined_total Dispatch records whose machine resolved to a corpus ABox IRI.
# TYPE semantic_dispatch_records_iri_joined_total counter
semantic_dispatch_records_iri_joined_total{runtime="$rt"} 0
EOF
}

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
for rt in cpp lsp scala; do mkdir -p "$T/$rt/api"; done
cat > "$T/re-registry.json" <<EOF
{"instances":[
 {"id":"cpp-1","runtime":"cpp","pe_url":"$BASE/cpp"},
 {"id":"lsp-1","runtime":"lsp","pe_url":"$BASE/lsp"},
 {"id":"scala-1","runtime":"scala","pe_url":"$BASE/scala"}]}
EOF
(cd "$T" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -sf "$BASE/re-registry.json" >/dev/null 2>&1 && break; sleep 0.1; done

run_case() {  # run_case <name> <expected rc> <expected output regex> [args]
  local name="$1" want_rc="$2" want_out="$3"; shift 3
  local out rc
  out="$(RE_REGISTRY_URL="$BASE/re-registry.json" bash "$CI_DIR/scripts/verify-metrics-parity.sh" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -Eq "$want_out"; then
    echo "  PASS: $name"; PASS=$((PASS+1))
  else
    echo "  FAIL: $name (rc=$rc, want $want_rc; want output /$want_out/)"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL+1))
  fi
}

# 1. Zero state: identical, no multi-series counters.
block cpp > "$T/cpp/api/metrics"; block lsp > "$T/lsp/api/metrics"; block scala > "$T/scala/api/metrics"
run_case "identical zero state passes" 0 "OK \(3 PEs"

# 2. Different traffic: cpp saw healthkit, all saw test. Same exposition.
block cpp healthkit test > "$T/cpp/api/metrics"; block lsp test > "$T/lsp/api/metrics"; block scala test > "$T/scala/api/metrics"
run_case "state asymmetry is reported, not drift" 0 "STATE — cpp-1 .*integration=healthkit"
run_case "state asymmetry still passes overall" 0 "OK \(3 PEs"

# 3. --with-values asserts equal state, so asymmetry fails there.
run_case "--with-values stays strict" 1 "exposition differs" --with-values

# 4. Real drift in a shared series (HELP wording) still fails.
block cpp test > "$T/cpp/api/metrics"
block lsp test | sed 's/by originating integration\./by integration./' > "$T/lsp/api/metrics"
block scala test > "$T/scala/api/metrics"
run_case "HELP drift in a shared series fails" 1 "cpp-1 != lsp-1"

# 5. Real drift in an unlabelled metric still fails.
block cpp > "$T/cpp/api/metrics"
block lsp | sed 's/semantic_manifest_machines{runtime/semantic_manifest_machines{scope="all",runtime/' > "$T/lsp/api/metrics"
block scala > "$T/scala/api/metrics"
run_case "label drift in an unlabelled metric fails" 1 "cpp-1 != lsp-1"

# 6. A missing required metric still fails.
block cpp > "$T/cpp/api/metrics"
block lsp | grep -v "semantic_dispatch_records_total" > "$T/lsp/api/metrics"
block scala > "$T/scala/api/metrics"
run_case "missing required metric fails" 1 "missing required metrics"

echo ""
echo "metrics-parity tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
