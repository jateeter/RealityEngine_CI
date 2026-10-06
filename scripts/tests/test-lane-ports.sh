#!/usr/bin/env bash
# Unit tests for regression-test.sh lane_ports: the ports the local lane's Docker
# preflight requires free.
#
# Under RE_FREE_PORTS=true the engines and the instance registry shim take free
# ports, so their template ports are not the lane's. Checking them refused a
# free-port run over macOS AirPlay on 5000, a port the run never binds (the
# defect startUniverse.sh had, #549).
#
# lane_ports is extracted from regression-test.sh and run against a scratch
# CI_DIR whose .env each case writes.
# shellcheck disable=SC2034
set -euo pipefail

CI_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }

FN="$(sed -n '/^lane_ports() {/,/^}/p' "$CI_DIR_REAL/scripts/regression-test.sh")"
check "$([ -n "$FN" ] && echo found)" found "lane_ports extracted from regression-test.sh"

ports() {  # <.env contents> [env assignments...] -> sorted port list on one line
  local env_body="$1"; shift
  printf '%s\n' "$env_body" > "$TMP/.env"
  env -u RE_FREE_PORTS -u SCALA_PE_BASE -u CPP_PE_BASE -u LSP_PE_BASE "$@" CI_DIR="$TMP" \
    bash -c "$FN"$'\n''lane_ports' | sort -n | tr '\n' ' ' | sed 's/ $//'
}
has() { case " $1 " in *" $2 "*) echo yes ;; *) echo no ;; esac; }
FIXED="3001 4000 5173 7331 8080 8088 18789"

echo "deterministic ports"
p="$(ports "")"
check "$p" "3001 4000 5000 5001 5173 5300 5301 5600 5601 5999 7331 8080 8088 18789" "defaults: every template port and the instance registry's 5999"
p="$(ports "SCALA_PE_BASE=5100")"
check "$(has "$p" 5100)$(has "$p" 5101)$(has "$p" 5000)" "yesyesno" ".env's SCALA_PE_BASE moves Scala's ports"

echo "free ports"
p="$(ports "" RE_FREE_PORTS=true)"
check "$p" "$FIXED" "RE_FREE_PORTS=true: only the fixed-port services"
check "$(has "$p" 5000)$(has "$p" 5999)" "nono" "AirPlay's 5000 and the shim's 5999 are not the lane's"
p="$(ports "RE_FREE_PORTS=true")"
check "$p" "$FIXED" "RE_FREE_PORTS=true from .env counts the same"
p="$(ports "SCALA_PE_BASE=5100" RE_FREE_PORTS=true)"
check "$(has "$p" 5100)" "no" "a template base is ignored when ports are free"

echo ""
echo "lane-ports: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
