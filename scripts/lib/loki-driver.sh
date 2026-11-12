#!/usr/bin/env bash
# loki-driver.sh — what state the Loki Docker logging driver is in.
#
# The probe this replaces was
#
#   LOKI_ENABLED=$(docker plugin inspect loki --format '{{.Enabled}}' 2>/dev/null || echo "missing")
#
# and it could not see the one case it existed for. When the plugin is absent,
# `docker plugin inspect` writes an empty line to stdout before it fails, so the
# fallback is appended to that line instead of replacing it. Command
# substitution strips trailing newlines, not leading ones, and the value was
# $'\n'missing — which matched none of "missing" / "false" / "true". With no
# `else`, startUniverse.sh installed nothing and said nothing, and the services
# declaring `driver: loki` failed to create (RealityEngine_CI#362).
#
# So status is taken from the exit code, never from whether stdout was empty,
# and anything that is not a recognised state is reported as such, so the
# caller can fail on it by name rather than falling through.
#
#   source scripts/lib/loki-driver.sh
#   loki_driver_state     # prints exactly one of: true | false | missing | unknown:<raw>

loki_driver_state() {
  local raw="" try
  # Docker Desktop sometimes fails a plugin query for a moment while it is
  # busy, and a single miss read as "missing" stopped the docker lane with the
  # plugin installed and enabled (2026-11-11, twice). Missing means missing on
  # every one of five tries.
  for try in 1 2 3 4 5; do
    if raw=$(docker plugin inspect loki --format '{{.Enabled}}' 2>/dev/null); then break; fi
    raw=""
    [ "$try" -lt 5 ] && sleep 2
  done
  if [ -z "$raw" ]; then
    echo missing
    return 0
  fi
  raw=${raw//[$'\n\r\t ']/}
  case "$raw" in
    true|false) echo "$raw" ;;
    *)          echo "unknown:$raw" ;;
  esac
}
