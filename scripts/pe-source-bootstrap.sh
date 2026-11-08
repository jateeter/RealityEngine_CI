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

CURL=(curl)
CURL_FLAGS=(-sf)
if [ "${RE_TLS:-off}" = on ]; then
    # Lane TLS (#668): the PE requires a client certificate, so the harness's
    # (RE_HARNESS_TLS_*, exported by lane_tls_init) and the lane CA, through a
    # curl that speaks TLS 1.3. No unverified fallback.
    # shellcheck source=lib/lane-tls.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-tls.sh"
    for v in RE_HARNESS_TLS_CA RE_HARNESS_TLS_CERT RE_HARNESS_TLS_KEY; do
        [ -f "${!v:-}" ] || { echo "  [pe-bootstrap] RE_TLS=on but $v is unset or not a file" >&2; exit 1; }
    done
    CURL=("$(lane_curl)" --tlsv1.3 --cacert "$RE_HARNESS_TLS_CA" --cert "$RE_HARNESS_TLS_CERT" --key "$RE_HARNESS_TLS_KEY")
else
    case "$PE_URL" in
        https://localhost:*|https://127.0.0.1:*|https://host.docker.internal:*)
            CURL_FLAGS=(-skf)
            ;;
    esac
fi

RESP=$("${CURL[@]}" "${CURL_FLAGS[@]}" -X POST "${PE_URL}/api/sources/bootstrap-from-machines" \
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
