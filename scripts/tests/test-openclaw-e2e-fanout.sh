#!/usr/bin/env bash
# Unit tests for the PE selection in scripts/test-openclaw-integration.sh:
# with no PE_URL the contract runs against every engine in the instance
# registry, with PE_URL it runs against that one, and with no instance registry
# the legacy default applies. The engines here are unreachable on purpose: this
# tests which targets get run, not the contract itself (that needs a universe).
set -euo pipefail
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$CI_DIR/scripts/test-openclaw-integration.sh"
TMP="$(mktemp -d -t re-oc-fanout.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }
contains() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

echo "test-openclaw-integration.sh PE selection"
printf '%s' '{"instances":[{"id":"a-1","pe_url":"http://127.0.0.1:9"},{"id":"b-1","pe_url":"http://127.0.0.1:9"}]}' > "$TMP/reg.json"

out="$(env -u PE_URL RE_REGISTRY_FILE="$TMP/reg.json" bash "$SCRIPT" --report-json "$TMP/rep.json" 2>&1)" && rc=0 || rc=$?
check "$rc" 1 "no PE_URL, two unreachable engines: the run fails"
check "$(contains "$out" '=== a-1 (http://127.0.0.1:9) ===')" yes "runs against a-1 from the instance registry"
check "$(contains "$out" '=== b-1 (http://127.0.0.1:9) ===')" yes "runs against b-1 from the instance registry"
check "$(contains "$out" 'failed on: a-1 b-1')" yes "names every engine that failed"
check "$(contains "$out" 'localhost:3004')" no "does not fall back to the legacy PE while a registry exists"
check "$([ -f "$TMP/rep.a-1.json" ] && [ -f "$TMP/rep.b-1.json" ] && echo both)" both "writes one report per engine"

out="$(PE_URL=http://127.0.0.1:9 RE_REGISTRY_FILE="$TMP/reg.json" bash "$SCRIPT" 2>&1)" && rc=0 || rc=$?
check "$(contains "$out" '===')" no "explicit PE_URL runs that one target only"
check "$(contains "$out" 'PE URL: http://127.0.0.1:9')" yes "explicit PE_URL is honoured"

out="$(env -u PE_URL RE_REGISTRY_FILE="$TMP/none.json" bash "$SCRIPT" 2>&1)" && rc=0 || rc=$?
check "$(contains "$out" 'PE URL: https://localhost:3004')" yes "no instance registry: the legacy default applies"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
