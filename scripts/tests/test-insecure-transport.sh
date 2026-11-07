#!/usr/bin/env bash
# Unit tests for scripts/check-insecure-transport.py (RealityEngine_CI#668, #727).
#
# Builds a throwaway workspace of git repositories in a temp directory and runs
# the checker against it with --root and --baseline. Touches no real checkout
# and starts nothing.
#
# Usage: bash scripts/tests/test-insecure-transport.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$CI_DIR/scripts/check-insecure-transport.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

WS="$TMP/ws"
for r in RealityEngine_CI RealityEngine_Manager RealityEngine_Machines RealityEngine_CPP RealityEngine_LSP \
         RealityEngine_Scala RealityEngine_Rust localAIStack localOpenClawStack localHealthkitBridge localAssetStorageStack; do
  mkdir -p "$WS/$r"; git -C "$WS/$r" init -q
done
commit() { git -C "$WS/$1" add -A >/dev/null; git -C "$WS/$1" -c user.email=t@t -c user.name=t commit -q -m t >/dev/null 2>&1 || true; }

cat > "$WS/localAIStack/client.py" <<'PY'
URL = "http://localhost:4000"          # recorded
NS = "http://www.w3.org/2001/XMLSchema" # a namespace, never counted
PY
printf '# docs are not scanned: http://example.invalid\n' > "$WS/localAIStack/README.md"
commit localAIStack
BASE="$TMP/baseline.json"
run() { python3 "$CHECK" --root "$WS" --baseline "$BASE" "$@" 2>&1; }

echo "insecure transport"
out=$(run --write); [[ $? -eq 0 && "$out" == *"1 occurrence(s) in 1 file(s)"* ]] && ok "baseline counts one URL, skips the namespace and the docs" || bad "baseline: $out"
out=$(run); [[ $? -eq 0 && "$out" == *"none new"* ]] && ok "unchanged code passes" || bad "unchanged: $out"

printf 'import requests\nrequests.get(u, verify=False)\n' > "$WS/localAssetStorageStack/new.py"; commit localAssetStorageStack
out=$(run); [[ $? -ne 0 && "$out" == *"python-verify-off 0 -> 1"* ]] && ok "a new verify=False fails" || bad "new verify=False: $out"
git -C "$WS/localAssetStorageStack" rm -q new.py; commit localAssetStorageStack

printf 'URL = "http://localhost:4000"\nB = "http://127.0.0.1:9"\n' > "$WS/localAIStack/client.py"; commit localAIStack
out=$(run); [[ $? -ne 0 && "$out" == *"plaintext-url 1 -> 2"* ]] && ok "a second http:// in a recorded file fails" || bad "growth: $out"
out=$(run --write); [[ $? -ne 0 && "$out" == *"refusing to write a baseline that grows"* ]] && ok "--write refuses to record growth" || bad "write growth: $out"

printf 'URL = "https://localhost:4000"\n' > "$WS/localAIStack/client.py"; commit localAIStack
out=$(run); [[ $? -eq 0 && "$out" == *"1 retired since the baseline"* ]] && ok "a fix is reported as retired" || bad "shrink: $out"
run --write >/dev/null; out=$(run); [[ $? -eq 0 && "$out" == *"0 recorded occurrence(s)"* ]] && ok "--write records the shrink" || bad "record shrink: $out"

printf 'curl -k https://x\nfetch(u, { rejectUnauthorized: false })\n' > "$WS/RealityEngine_Manager/s.sh"; commit RealityEngine_Manager
out=$(run); [[ $? -ne 0 && "$out" == *"curl-insecure"* && "$out" == *"node-reject-unauthorized"* ]] && ok "curl -k and rejectUnauthorized: false fail" || bad "curl/node: $out"

rm -rf "$WS/RealityEngine_Rust"
out=$(run); [[ $? -ne 0 && "$out" == *"not scanned"*"RealityEngine_Rust"* ]] && ok "a missing sibling fails, named" || bad "missing: $out"

echo "insecure-transport: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
