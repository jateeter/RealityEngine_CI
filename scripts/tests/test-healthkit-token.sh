#!/usr/bin/env bash
# Unit tests for scripts/lib/healthkit-token.sh and scripts/lib/secrets-home.sh:
# the HealthKit bridge token's one home (the suite's secrets home,
# $RE_SECRETS_DIR/RealityEngine_CI/healthkit-bridge-token) and the copy from its
# old in-checkout homes. Every case runs with RE_SECRETS_DIR in a scratch
# directory; no real token is read or printed.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../lib/healthkit-token.sh
source "$CI_DIR/scripts/lib/healthkit-token.sh"

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }
# GNU stat first: on Linux `stat -f` is filesystem status and *succeeds*,
# so trying the BSD form first returned filesystem details instead of a mode.
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

echo "secrets-home.sh"
check "$(RE_SECRETS_DIR=/s RE_INSTANCE_STATE_DIR=/x re_secrets_dir)" /s "RE_SECRETS_DIR wins"
check "$(unset RE_SECRETS_DIR; RE_INSTANCE_STATE_DIR=/x re_secrets_dir)" /x/secrets "then the state root's secrets/"
check "$(unset RE_SECRETS_DIR RE_INSTANCE_STATE_DIR; re_secrets_dir)" "$HOME/.reality-engine/secrets" "then ~/.reality-engine/secrets"

echo "healthkit-token.sh"

# A fresh machine: generated in the secrets home, private, outside the checkout.
export RE_SECRETS_DIR="$TMP/home1"
A="$TMP/fresh"; mkdir -p "$A/config"
healthkit_token_ensure "$A"
f="$(healthkit_token_path "$A")"
check "$f" "$TMP/home1/RealityEngine_CI/healthkit-bridge-token" "the token lives in the secrets home, not the checkout"
check "$([ -s "$f" ] && echo yes)" yes "a fresh machine gets a token"
check "$(mode "$f")" 600 "the token file is 0600"
check "$(mode "$(dirname "$f")")" 700 "the repo's secrets directory is 0700"
check "$(healthkit_token_read "$A" | grep -cE '^hk-[0-9a-f]{32}$')" 1 "the generated token has the hk-<32 hex> shape"
first="$(healthkit_token_read "$A")"
healthkit_token_ensure "$A"
check "$(healthkit_token_read "$A")" "$first" "an existing token is never regenerated"
# Another checkout (a regression worktree) on the same machine reads the same token.
W="$TMP/worktree"; mkdir -p "$W"
healthkit_token_ensure "$W"
check "$(healthkit_token_read "$W")" "$first" "every checkout reads the same token"

# A checkout holding the token in .secrets/ (the previous home): copied, kept.
export RE_SECRETS_DIR="$TMP/home2"
B="$TMP/secrets-era"; mkdir -p "$B/.secrets"
printf 'hk-secretsvalue0123456789abcdef012\n' > "$B/.secrets/healthkit-bridge-token"
check "$(healthkit_token_read "$B")" "hk-secretsvalue0123456789abcdef012" "read falls back to .secrets/ before the copy"
healthkit_token_ensure "$B"
check "$(tr -d '\n' < "$(healthkit_token_path "$B")")" "hk-secretsvalue0123456789abcdef012" "the copy keeps the value (a paired device keeps working)"
check "$([ -e "$B/.secrets/healthkit-bridge-token" ] && echo kept || echo gone)" kept "the old copy is never deleted"
check "$(mode "$(healthkit_token_path "$B")")" 600 "the copied token is 0600"

# A checkout from before .secrets/: config/.healthkit-bridge-token.
export RE_SECRETS_DIR="$TMP/home3"
C="$TMP/legacy"; mkdir -p "$C/config"
printf 'hk-legacyvalue0123456789abcdef0123\n' > "$C/config/.healthkit-bridge-token"
healthkit_token_ensure "$C"
check "$(healthkit_token_read "$C")" "hk-legacyvalue0123456789abcdef0123" "the oldest home is copied too"
check "$([ -e "$C/config/.healthkit-bridge-token" ] && echo kept || echo gone)" kept "and kept"

# No token anywhere: read is empty, not an error.
export RE_SECRETS_DIR="$TMP/home4"
D="$TMP/none"; mkdir -p "$D"
check "$(healthkit_token_read "$D")" "" "no token reads as empty"

# The old in-checkout homes stay gitignored for the copies operators still hold.
check "$(git -C "$CI_DIR" check-ignore -q .secrets/healthkit-bridge-token && echo ignored)" ignored ".secrets/ is gitignored"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
