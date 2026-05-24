#!/usr/bin/env bash
# Unit tests for scripts/registry.sh — no Docker, no engines required.
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
    echo "        expected: $(echo "$expected" | head -c 200)"
    echo "        actual:   $(echo "$actual"   | head -c 200)"
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

# ── Isolated temp environment ─────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
export RE_REGISTRY_FILE="$TMPDIR_TEST/re-registry.json"
export HOST_IP="127.0.0.1"
# shellcheck source=../registry.sh
source "$CI_DIR/scripts/registry.sh"

cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# ── Tests ─────────────────────────────────────────────────────────────────────
echo "=== test-registry.sh ==="

# T1: registry_add creates file with correct schema
registry_add "test-1" "scala" "http://127.0.0.1:5001" "http://127.0.0.1:5000" "1001" "1002"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(len(d['instances']))")" "1" "T1: add creates 1 entry"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(d['instances'][0]['id'])")" "test-1" "T1: id field correct"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(d['instances'][0]['runtime'])")" "scala" "T1: runtime field correct"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(d['instances'][0]['re_port'])")" "5001" "T1: re_port derived from url"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(d['instances'][0]['status'])")" "running" "T1: status=running"

# T2: second add with same id is idempotent upsert (no duplicate)
registry_add "test-1" "scala" "http://127.0.0.1:5001" "http://127.0.0.1:5000" "1001" "1002"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(len(d['instances']))")" "1" "T2: duplicate add stays at 1 entry"

# T3: two distinct ids produce 2 entries
registry_add "test-2" "cpp" "http://127.0.0.1:5301" "http://127.0.0.1:5300" "2001" ""
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(len(d['instances']))")" "2" "T3: two distinct ids → 2 entries"

# T4: registry_get returns matching JSON and exits 0
entry=$(registry_get "test-1")
assert_eq "$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['runtime'])")" "scala" "T4: registry_get returns correct entry"

# T5: registry_get missing id exits 1
set +e
registry_get "nonexistent" > /dev/null 2>&1
_exit=$?
set -e
assert_exit "$_exit" "1" "T5: registry_get missing id exits 1"

# T6: registry_remove removes entry, leaves other intact
registry_remove "test-1"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(len(d['instances']))")" "1" "T6: remove leaves 1 entry"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(d['instances'][0]['id'])")" "test-2" "T6: remaining entry is test-2"

# T7: registry_ids outputs one line per instance, no blanks
registry_add "test-3" "lsp" "http://127.0.0.1:5601" "http://127.0.0.1:5600" "3001" "3002"
ids=$(registry_ids)
assert_eq "$(echo "$ids" | grep -c .)" "2" "T7: registry_ids returns 2 lines"
assert_eq "$(echo "$ids" | grep -c '^$')" "0" "T7: no blank lines in ids output" 2>/dev/null || true

# T8: registry_list returns valid JSON with instances array
listing=$(registry_list)
assert_eq "$(echo "$listing" | python3 -c "import json,sys; d=json.load(sys.stdin); print(type(d['instances']).__name__)")" "list" "T8: registry_list returns valid JSON with instances array"

# T9: registry_remove on file-absent entry is a no-op (no error)
rm -f "$RE_REGISTRY_FILE"
set +e
registry_remove "ghost" 2>/dev/null
_exit=$?
set -e
assert_exit "$_exit" "0" "T9: remove on missing file exits 0"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "registry: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
