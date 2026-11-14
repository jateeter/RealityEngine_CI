#!/usr/bin/env bash
# healthkit-token.sh — the one place the PE HealthKit ingest bridge token lives.
#
# The token authenticates the on-device iOS bridge (and the simulator leg) to
# every PE runtime's POST /api/integrations/healthkit/ingest. It is a secret, so
# it lives in the suite's secrets home (scripts/lib/secrets-home.sh):
# $RE_SECRETS_DIR/RealityEngine_CI/healthkit-bridge-token, default
# ~/.reality-engine/secrets/RealityEngine_CI/ (directory 0700, file 0600, outside
# every repository). Every consumer — startUniverse.sh, the regression harness,
# run-all-tests.sh and the hosted workflow — reads it through here rather than
# each knowing a path.
#
# It used to sit in the checkout: RealityEngine_CI/.secrets/healthkit-bridge-token,
# and before that config/.healthkit-bridge-token. A regression cold-start
# worktree had neither, so it minted a new token that the paired iPhone did not
# hold. An existing token is copied to the secrets home, never replaced: a paired
# device was provisioned with that value and must keep working. The old copies
# are left in place for the operator to delete (owner, 2026-11-14).
#
# Precedence everywhere: an exported HEALTHKIT_BRIDGE_TOKEN wins.
#
#   source scripts/lib/healthkit-token.sh
#   healthkit_token_path   <ci-dir>   # prints the canonical file path
#   healthkit_token_ensure <ci-dir>   # migrate or generate; prints nothing
#   healthkit_token_read   <ci-dir>   # prints the token, or nothing if none exists
#
# <ci-dir> names the checkout whose old copies are migrated; the token itself is
# the same for every checkout on the machine.

# shellcheck source=secrets-home.sh
. "$(dirname "${BASH_SOURCE[0]}")/secrets-home.sh"

healthkit_token_path() {
  printf '%s/RealityEngine_CI/healthkit-bridge-token\n' "$(re_secrets_dir)"
}

# The checkout's old copies, newest home first.
_healthkit_token_legacy() {
  printf '%s/.secrets/healthkit-bridge-token\n' "$1"
  printf '%s/config/.healthkit-bridge-token\n' "$1"
}

healthkit_token_ensure() {
  local ci="$1" file legacy
  file="$(healthkit_token_path "$ci")"
  [ -s "$file" ] && return 0
  re_secrets_repo_dir RealityEngine_CI >/dev/null
  while IFS= read -r legacy; do
    if [ -s "$legacy" ]; then
      # Same value, new home: the paired device keeps authenticating.
      re_secret_copy_verified "$legacy" "$file" || return 1
      return 0
    fi
  done < <(_healthkit_token_legacy "$ci")
  ( umask 177; printf 'hk-%s\n' "$(openssl rand -hex 16)" > "$file" )
  chmod 600 "$file"
}

healthkit_token_read() {
  local ci="$1" file legacy
  file="$(healthkit_token_path "$ci")"
  if [ -s "$file" ]; then
    tr -d '\r\n' < "$file"
    return 0
  fi
  # A checkout not yet started since the move still holds it here.
  while IFS= read -r legacy; do
    if [ -s "$legacy" ]; then tr -d '\r\n' < "$legacy"; return 0; fi
  done < <(_healthkit_token_legacy "$ci")
}
