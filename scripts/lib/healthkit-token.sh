#!/usr/bin/env bash
# healthkit-token.sh — the one place the PE HealthKit ingest bridge token lives.
#
# The token authenticates the on-device iOS bridge (and the simulator leg) to
# every PE runtime's POST /api/integrations/healthkit/ingest. It is a secret, so
# it lives in RealityEngine_CI/.secrets/ (directory 0700, file 0600, gitignored),
# and every consumer — startUniverse.sh, the regression harness, run-all-tests.sh
# and the hosted workflow — reads it through here rather than each knowing a path.
#
# It used to sit at config/.healthkit-bridge-token, and only startUniverse.sh and
# the regression harness read it. run-all-tests.sh never passed it on, so the
# Machines healthkit-ingest-contract spec sent no token and every PE answered 401
# (RealityEngine_Machines#126). An existing token is moved, not replaced: a
# paired device was provisioned with that value and must keep working.
#
# Precedence everywhere: an exported HEALTHKIT_BRIDGE_TOKEN wins.
#
#   source scripts/lib/healthkit-token.sh
#   healthkit_token_path   <ci-dir>   # prints the canonical file path
#   healthkit_token_ensure <ci-dir>   # migrate or generate; prints nothing
#   healthkit_token_read   <ci-dir>   # prints the token, or nothing if none exists

healthkit_token_path() {
  printf '%s/.secrets/healthkit-bridge-token\n' "$1"
}

_healthkit_token_legacy() {
  printf '%s/config/.healthkit-bridge-token\n' "$1"
}

healthkit_token_ensure() {
  local ci="$1" file legacy
  file="$(healthkit_token_path "$ci")"
  legacy="$(_healthkit_token_legacy "$ci")"
  [ -s "$file" ] && return 0
  ( umask 077; mkdir -p "$(dirname "$file")" )
  chmod 700 "$(dirname "$file")"
  if [ -s "$legacy" ]; then
    # Same value, new home: the paired device keeps authenticating.
    ( umask 177; tr -d '\r\n' < "$legacy" > "$file"; printf '\n' >> "$file" )
    rm -f "$legacy"
  else
    ( umask 177; printf 'hk-%s\n' "$(openssl rand -hex 16)" > "$file" )
  fi
  chmod 600 "$file"
}

healthkit_token_read() {
  local ci="$1" file legacy
  file="$(healthkit_token_path "$ci")"
  legacy="$(_healthkit_token_legacy "$ci")"
  if [ -s "$file" ]; then
    tr -d '\r\n' < "$file"
  elif [ -s "$legacy" ]; then
    # A checkout not yet started since the move still holds it here.
    tr -d '\r\n' < "$legacy"
  fi
}
