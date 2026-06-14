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

CREATED=$(python3 -c "
import json, sys
try:
    d = json.loads('''$RESP''')
    print(int(d.get('created', 0)))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

echo "  [pe-bootstrap] PE: ${PE_URL}  sources created: ${CREATED}"
