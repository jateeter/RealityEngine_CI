#!/usr/bin/env bash
# Unit tests for scripts/lib/healthkit-token.sh — the HealthKit bridge token's
# one home (.secrets/healthkit-bridge-token) and the move from its old one.
# Every case runs in a scratch CI dir; no real token is read or printed.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../lib/healthkit-token.sh
source "$CI_DIR/scripts/lib/healthkit-token.sh"

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

echo "healthkit-token.sh"

# A fresh checkout: generated in .secrets, private.
A="$TMP/fresh"; mkdir -p "$A/config"
healthkit_token_ensure "$A"
f="$(healthkit_token_path "$A")"
check "$([ -s "$f" ] && echo yes)" yes "a fresh checkout gets a token in .secrets/"
check "$(mode "$f")" 600 "the token file is 0600"
check "$(mode "$(dirname "$f")")" 700 "the .secrets directory is 0700"
check "$(healthkit_token_read "$A" | grep -cE '^hk-[0-9a-f]{32}$')" 1 "the generated token has the hk-<32 hex> shape"
first="$(healthkit_token_read "$A")"
healthkit_token_ensure "$A"
check "$(healthkit_token_read "$A")" "$first" "an existing token is never regenerated"

# A checkout started before the move: same value, new home, old file gone.
B="$TMP/legacy"; mkdir -p "$B/config"
printf 'hk-legacyvalue0123456789abcdef0123\n' > "$B/config/.healthkit-bridge-token"
check "$(healthkit_token_read "$B")" "hk-legacyvalue0123456789abcdef0123" "read falls back to the old path before the move"
healthkit_token_ensure "$B"
check "$(healthkit_token_read "$B")" "hk-legacyvalue0123456789abcdef0123" "the move keeps the value (a paired device keeps working)"
check "$([ -e "$B/config/.healthkit-bridge-token" ] && echo present || echo gone)" gone "the old file is removed after the move"
check "$(mode "$(healthkit_token_path "$B")")" 600 "the moved token is 0600"

# No token anywhere: read is empty, not an error.
C="$TMP/none"; mkdir -p "$C"
check "$(healthkit_token_read "$C")" "" "no token reads as empty"

# The secret can never be committed.
check "$(git -C "$CI_DIR" check-ignore -q .secrets/healthkit-bridge-token && echo ignored)" ignored ".secrets/ is gitignored"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
