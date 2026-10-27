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

# ── Instance UUIDs (RealityEngine_CI#296) ────────────────────────────────────
# A UUID belongs to an instance, never an engine type; no two instances share one.
export RE_INSTANCE_STATE_DIR="$TMPDIR_TEST/instance-state"
rm -f "$RE_REGISTRY_FILE"

u_cpp1=$(instance_uuid_allocate native cpp-1)
u_cpp2=$(instance_uuid_allocate native cpp-2)
u_lsp1=$(instance_uuid_allocate native lsp-1)
assert_eq "$(python3 -c "import re,sys; print(all(re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', u) for u in sys.argv[1:]))" "$u_cpp1" "$u_cpp2" "$u_lsp1")" "True" "U1: allocations are canonical v7 UUIDs"
assert_eq "$(printf '%s\n' "$u_cpp1" "$u_cpp2" "$u_lsp1" | sort -u | wc -l | tr -d ' ')" "3" "U2: two instances of one engine type get distinct UUIDs"
assert_eq "$(instance_uuid_allocate native cpp-1)" "$u_cpp1" "U3: an instance keeps its UUID across allocations (universes)"
u_docker_cpp1=$(instance_uuid_docker_env cpp-1)
[ "$u_docker_cpp1" != "$u_cpp1" ] && _distinct=yes || _distinct=no
assert_eq "$_distinct" "yes" "U4: the Docker lane's cpp-1 is a different instance from the native cpp-1"
assert_eq "$(cat "$RE_INSTANCE_STATE_DIR/docker/cpp-1.env")" "INSTANCE_UUID=$u_docker_cpp1
INSTANCE_CLOCK_DIR=/var/lib/reality-engine/clock" "U5: the Docker env file carries the UUID and the container clock dir"
assert_eq "$(instance_clock_dir)" "$RE_INSTANCE_STATE_DIR/clock" "U6: native clocks live under the state dir"

registry_add "cpp-1" "cpp" "http://127.0.0.1:5301" "http://127.0.0.1:5300" "" "" "$u_cpp1"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(d['instances'][0]['instance_uuid'])")" "$u_cpp1" "U7: registry_add records instance_uuid"
set +e
registry_add "cpp-2" "cpp" "http://127.0.0.1:5311" "http://127.0.0.1:5310" "" "" "$u_cpp1" 2>/dev/null
_exit=$?
set -e
assert_exit "$_exit" "1" "U8: a UUID another instance holds is refused"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(len(d['instances']))")" "1" "U8: and nothing was registered"
registry_add "cpp-1" "cpp" "http://127.0.0.1:5301" "http://127.0.0.1:5300" "" "" "$u_cpp1"
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print(len(d['instances']))")" "1" "U9: re-registering the same instance with its own UUID is an upsert"
registry_add "lsp-1" "lsp" "http://127.0.0.1:5601" "http://127.0.0.1:5600" "" ""
assert_eq "$(python3 -c "import json; d=json.load(open('$RE_REGISTRY_FILE')); print([i['instance_uuid'] for i in d['instances'] if i['id']=='lsp-1'][0])")" "None" "U10: without a UUID the field is null"
python3 "$CI_DIR/scripts/lib/instance_uuids.py" check-registry "$RE_REGISTRY_FILE"
assert_exit "$?" "0" "U11: check-registry passes a registry with unique UUIDs"
python3 - "$RE_REGISTRY_FILE" "$u_cpp1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['instances'].append({'id': 'cpp-9', 'instance_uuid': sys.argv[2]})
json.dump(d, open(sys.argv[1], 'w'))
PY
set +e
python3 "$CI_DIR/scripts/lib/instance_uuids.py" check-registry "$RE_REGISTRY_FILE" 2>/dev/null
_exit=$?
set -e
assert_exit "$_exit" "1" "U12: check-registry refuses two instances sharing a UUID"
python3 - "$RE_INSTANCE_STATE_DIR/instance-uuids.json" "$u_cpp1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['instances']['native/cpp-7'] = sys.argv[2]
json.dump(d, open(sys.argv[1], 'w'))
PY
set +e
instance_uuid_allocate native cpp-8 >/dev/null 2>&1
_exit=$?
set -e
assert_exit "$_exit" "1" "U13: an allocation table holding a duplicate is refused, not repaired"

# ── A live UUID is never handed to a second instance (#637) ──────────────────
# Two universes on one lane both have a cpp-1; while one holds its UUID, the
# other's cpp-1 is a different instance. The lock is held the way the engines
# hold it: a POSIX lock over <clock>/<uuid>.lock for the life of the process.
export RE_INSTANCE_STATE_DIR="$TMPDIR_TEST/instance-state-live"
u_live=$(instance_uuid_allocate native cpp-1)
mkdir -p "$RE_INSTANCE_STATE_DIR/clock"
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(sys.argv[2], "w").close()
time.sleep(60)' "$RE_INSTANCE_STATE_DIR/clock/$u_live.lock" "$TMPDIR_TEST/locked" &
_holder=$!
for _ in $(seq 1 50); do [ -f "$TMPDIR_TEST/locked" ] && break; sleep 0.1; done
assert_eq "$(python3 "$CI_DIR/scripts/lib/instance_uuids.py" holder "$u_live")" "$_holder" "L1: the probe names the process holding an instance's lock"
assert_eq "$(instance_uuid_live)" "$u_live $_holder" "L2: live lists every held instance lock"
u_second=$(instance_uuid_allocate native cpp-1 2>/dev/null)
[ "$u_second" != "$u_live" ] && _distinct=yes || _distinct=no
assert_eq "$_distinct" "yes" "L3: while cpp-1's UUID is live, a second cpp-1 is a different instance with its own UUID"
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['instances']['native/cpp-1#2'])" "$RE_INSTANCE_STATE_DIR/instance-uuids.json")" "$u_second" "L4: the second instance's UUID is recorded durably as native/cpp-1#2"
assert_eq "$(instance_uuid_allocate native cpp-1 2>/dev/null)" "$u_second" "L5: and it keeps it on its next allocation"
kill "$_holder"; wait "$_holder" 2>/dev/null || true
assert_eq "$(bash -c 'source "$1"; instance_uuid_allocate native cpp-1' _ "$CI_DIR/scripts/registry.sh")" "$u_live" "L6: once nothing holds it, the next universe's cpp-1 has the recorded UUID again"
set +e
python3 "$CI_DIR/scripts/lib/instance_uuids.py" holder "$u_live" >/dev/null
_exit=$?
set -e
assert_exit "$_exit" "1" "L7: holder exits 1 when no process holds the lock"

# A lease covers allocation up to the engine taking its lock: a second universe
# allocating the same id meanwhile gets another UUID, and the first universe's
# own repeat allocation does not.
sleep 120 & _owner_a=$!
u_a=$(python3 "$CI_DIR/scripts/lib/instance_uuids.py" allocate native lsp-1 "$_owner_a")
u_b=$(python3 "$CI_DIR/scripts/lib/instance_uuids.py" allocate native lsp-1 "$$" 2>/dev/null)
[ "$u_a" != "$u_b" ] && _distinct=yes || _distinct=no
assert_eq "$_distinct" "yes" "L8: a UUID leased by another starting universe is not handed out"
assert_eq "$(python3 "$CI_DIR/scripts/lib/instance_uuids.py" allocate native lsp-1 "$_owner_a")" "$u_a" "L9: the leasing universe gets its own UUID again"
kill "$_owner_a"; wait "$_owner_a" 2>/dev/null || true
assert_eq "$(python3 "$CI_DIR/scripts/lib/instance_uuids.py" allocate native lsp-1 "$$")" "$u_a" "L10: a lease ends with the universe that took it"
assert_eq "$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(sys.argv[2] in d.get('leases',{}), sys.argv[3] in d.get('leases',{}))" "$RE_INSTANCE_STATE_DIR/instance-uuids.json" "$u_a" "$u_b")" "True False" "L11: a universe re-allocating an id keeps one lease for it, not one per sibling"

# ── registry_live_engines: what a start must not orphan (#637) ───────────────
# A recorded pid counts while it is still an engine binary. The live one is a
# process whose command line names an engine; the dead one has exited; the
# reused one is alive but not an engine.
LIVE_DIR="$TMPDIR_TEST/bin"
mkdir -p "$LIVE_DIR"
# A script, not a copied binary: macOS kills a copied system binary on launch.
printf '#!/usr/bin/env python3\nimport time, sys\ntime.sleep(int(sys.argv[1]))\n' > "$LIVE_DIR/reality_engine_server"
chmod +x "$LIVE_DIR/reality_engine_server"
"$LIVE_DIR/reality_engine_server" 120 & _eng=$!
sleep 120 & _other=$!
sh -c 'exit 0' & _dead=$!; wait "$_dead" 2>/dev/null || true
cat > "$RE_REGISTRY_FILE" <<JSON
{"host":"127.0.0.1","instances":[
 {"id":"cpp-1","runtime":"cpp","pid_re":$_eng,"pid_pe":$_dead},
 {"id":"lsp-1","runtime":"lsp","pid_re":$_other,"pid_pe":null}]}
JSON
_live=$(registry_live_engines)
assert_eq "$(awk '{print $1, $2, $3}' <<<"$_live")" "cpp-1 RE $_eng" "R1: only the live engine pid is reported, with its instance and role"
kill "$_eng" "$_other" 2>/dev/null || true; wait "$_eng" "$_other" 2>/dev/null || true
assert_eq "$(registry_live_engines)" "" "R2: nothing once it has exited"
rm -f "$RE_REGISTRY_FILE"
assert_eq "$(registry_live_engines)" "" "R3: nothing without an instance registry"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "registry: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
