#!/usr/bin/env bash
# Unit tests for scripts/lib/registry-url.sh and registry_url.py — one lookup
# order, the same in both: RE_REGISTRY_URL, then .universe-registry-url, then
# http://127.0.0.1:${RE_REGISTRY_PORT:-5999}/re-registry.json.
# RE_UNIVERSE_REGISTRY_URL_FILE points both at a scratch file, so the real
# .universe-registry-url of a running universe is never read or written.
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
# shellcheck source=scripts/lib/registry-url.sh
source "$CI_DIR/scripts/lib/registry-url.sh"


check() {  # check <name> <want> [VAR=value ...]
  local name="$1" want="$2"; shift 2
  local got_sh got_py
  got_sh="$(env -u RE_REGISTRY_URL -u RE_REGISTRY_PORT RE_UNIVERSE_REGISTRY_URL_FILE="$T/url" "$@" bash -c "source '$CI_DIR/scripts/lib/registry-url.sh'; registry_url")"
  got_py="$(env -u RE_REGISTRY_URL -u RE_REGISTRY_PORT RE_UNIVERSE_REGISTRY_URL_FILE="$T/url" "$@" \
    python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from registry_url import registry_url; print(registry_url())' \
    "$CI_DIR/scripts/lib")"
  if [ "$got_sh" = "$want" ] && [ "$got_py" = "$want" ]; then
    echo "  PASS: $name"; PASS=$((PASS+1))
  else
    echo "  FAIL: $name: want $want, bash $got_sh, python $got_py"; FAIL=$((FAIL+1))
  fi
}

rm -f "$T/url"
check "no file, no env: the fixed-port default" "http://127.0.0.1:5999/re-registry.json"
check "RE_REGISTRY_PORT moves the default" "http://127.0.0.1:6111/re-registry.json" RE_REGISTRY_PORT=6111

printf 'http://192.168.1.9:50422/re-registry.json\n' > "$T/url"
check "the universe's recorded address beats the default" "http://192.168.1.9:50422/re-registry.json"
check "...and beats RE_REGISTRY_PORT" "http://192.168.1.9:50422/re-registry.json" RE_REGISTRY_PORT=6111
check "RE_REGISTRY_URL beats the file" "http://10.0.0.2:7000/re-registry.json" RE_REGISTRY_URL=http://10.0.0.2:7000/re-registry.json

: > "$T/url"
check "an empty file falls through to the default" "http://127.0.0.1:5999/re-registry.json"

echo ""
echo "registry-url tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
