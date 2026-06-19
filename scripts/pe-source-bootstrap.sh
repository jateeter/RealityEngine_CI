#!/usr/bin/env bash
# pe-source-bootstrap.sh — Bootstrap PE test sources from already-loaded RE machines
#
# Calls POST /api/sources/bootstrap-from-machines on the PE.  The PE fetches
# /api/machines from its connected RE and materialises one consolidated test
# source per machine that is not already registered.
#
# Usage:
#   scripts/pe-source-bootstrap.sh <pe_url>
#
# Exit:
#   0 — bootstrap succeeded (even if 0 sources were created because all exist)
#   1 — request failed or PE did not respond

set -uo pipefail

PE_URL="${1:?Usage: pe-source-bootstrap.sh <pe_url>}"

RESP=$(curl -sf -X POST "${PE_URL}/api/sources/bootstrap-from-machines" \
    -H "Content-Type: application/json" \
    --max-time 30 2>/dev/null || true)

if [ -z "$RESP" ]; then
    echo "  [pe-bootstrap] No response from ${PE_URL}/api/sources/bootstrap-from-machines" >&2
    exit 1
fi

SUMMARY=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    if d.get("success") is False:
        raise SystemExit(2)
    print("{} {} {}".format(
        int(d.get("created", 0)),
        int(d.get("skipped", 0)),
        int(d.get("machinesSeen", 0)),
    ))
except Exception:
    raise SystemExit(1)
' "$RESP" 2>/dev/null || true)

if [ -z "$SUMMARY" ]; then
    echo "  [pe-bootstrap] Invalid bootstrap response from ${PE_URL}: ${RESP}" >&2
    exit 1
fi

set -- $SUMMARY
CREATED="$1"
SKIPPED="$2"
MACHINES_SEEN="$3"

echo "  [pe-bootstrap] PE: ${PE_URL}  machines seen: ${MACHINES_SEEN}  sources created: ${CREATED}  skipped: ${SKIPPED}"
