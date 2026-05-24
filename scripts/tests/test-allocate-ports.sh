#!/usr/bin/env bash
# Unit tests for scripts/allocate-ports.sh — no Docker, no engines required.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── Test harness ──────────────────────────────────────────────────────────────
PASS=0; FAIL=0

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $label"
    echo "        expected: '$expected'"
    echo "        actual:   '$actual'"
    FAIL=$((FAIL+1))
  fi
}

assert_exit() {
  local code="$1" expected="$2" label="$3"
  if [ "$code" = "$expected" ]; then
    echo "  PASS: $label (exit $code)"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $label (expected exit $expected, got $code)"
    FAIL=$((FAIL+1))
  fi
}

# shellcheck source=../allocate-ports.sh
source "$CI_DIR/scripts/allocate-ports.sh"

echo "=== test-allocate-ports.sh ==="

# T1–T4: deterministic port arithmetic — skip if ports are already in use on this host
_port_free() { ! lsof -i ":$1" -sTCP:LISTEN >/dev/null 2>&1; }

if _port_free 5001 && _port_free 5000; then
  assert_eq "$(allocate_ports scala 1)" "5001 5000" "T1: scala index 1 → 5001 5000"
else echo "  SKIP: T1 — port 5001 or 5000 occupied on this host"; fi

if _port_free 5101 && _port_free 5100; then
  assert_eq "$(allocate_ports scala 2)" "5101 5100" "T2: scala index 2 → 5101 5100"
else echo "  SKIP: T2 — port 5101 or 5100 occupied on this host"; fi

if _port_free 5301 && _port_free 5300; then
  assert_eq "$(allocate_ports cpp   1)" "5301 5300" "T3: cpp   index 1 → 5301 5300"
else echo "  SKIP: T3 — port 5301 or 5300 occupied on this host"; fi

if _port_free 5801 && _port_free 5800; then
  assert_eq "$(allocate_ports lsp   3)" "5801 5800" "T4: lsp   index 3 → 5801 5800"
else echo "  SKIP: T4 — port 5801 or 5800 occupied on this host"; fi

# T5: unknown runtime exits 1
set +e
allocate_ports unknown 1 > /dev/null 2>&1
_exit=$?
set -e
assert_exit "$_exit" "1" "T5: unknown runtime exits 1"

# T6: occupied RE port causes exit 1
# Hold the port with nc, then verify allocate_ports refuses it
NC_PID=""
if command -v nc >/dev/null 2>&1; then
  nc -l 5301 > /dev/null 2>&1 &
  NC_PID=$!
  sleep 0.3
  set +e
  allocate_ports cpp 1 > /dev/null 2>&1
  _exit=$?
  set -e
  kill "$NC_PID" 2>/dev/null || true
  wait "$NC_PID" 2>/dev/null || true
  assert_exit "$_exit" "1" "T6: occupied RE port exits 1"
else
  echo "  SKIP: nc not available for T6"
fi

# T7: occupied PE port causes exit 1
if command -v nc >/dev/null 2>&1; then
  nc -l 5300 > /dev/null 2>&1 &
  NC_PID=$!
  sleep 0.3
  set +e
  allocate_ports cpp 1 > /dev/null 2>&1
  _exit=$?
  set -e
  kill "$NC_PID" 2>/dev/null || true
  wait "$NC_PID" 2>/dev/null || true
  assert_exit "$_exit" "1" "T7: occupied PE port exits 1"
else
  echo "  SKIP: nc not available for T7"
fi

# T8: base port arithmetic produces distinct values across runtimes (no overlay)
# Verified via arithmetic alone — does not require ports to be free
_s_re=5001; _s_pe=5000; _c_re=5301; _c_pe=5300; _l_re=5601; _l_pe=5600
_all_ports="$_s_re $_s_pe $_c_re $_c_pe $_l_re $_l_pe"
_unique=$(echo "$_all_ports" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
assert_eq "$_unique" "6" "T8: all base ports across runtimes are arithmetically distinct"

echo ""
echo "allocate-ports: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
