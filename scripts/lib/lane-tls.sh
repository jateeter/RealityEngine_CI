#!/usr/bin/env bash
# Lane TLS: each lane issues and hands out its certificates (RealityEngine_CI#668, #732).
#
# Sourced, not executed. Bash 3.2 compatible, because startUniverse.sh's
# shebang is /bin/bash. Needs CI_DIR, and the info/warn helpers when the caller
# has them.
#
# The lane switch is RE_TLS (default off):
#   off  the lane runs as before: http URLs, and no RE_TLS_* reaches a service.
#        Certificates are still issued (cheap, idempotent), so turning the lane
#        on later needs nothing new.
#   on   every instance gets RE_TLS_CERT/KEY/CA/CRL, URLs are https, and health
#        polls verify with the lane CA and present the harness certificate.
# RE_TLS_* is passed only when the lane is on, because a service serves TLS as
# soon as RE_TLS_CERT is set (docs/TRANSPORT_SECURITY.md, the runtime
# contract). An upgraded engine must not switch alone while the instance
# registry still says http.

LANE_TLS_PKI="${LANE_TLS_PKI:-${CI_DIR:-.}/scripts/lib/re_pki.py}"
LANE_TLS_READY=0
LANE_TLS_CA=""
LANE_TLS_CRL=""
LANE_TLS_HARNESS_CERT=""
LANE_TLS_HARNESS_KEY=""

lane_tls_enabled() { [ "${RE_TLS:-off}" = "on" ]; }

lane_tls_scheme() { if lane_tls_enabled; then echo https; else echo http; fi; }

_lane_tls_say() { # level message
    if command -v "$1" >/dev/null 2>&1; then "$1" "$2"; else echo "lane-tls: $2" >&2; fi
}

_lane_tls_path() { # name key -> one path from `re_pki.py paths`
    python3 "$LANE_TLS_PKI" paths "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}

# lane_tls_init LANE: create or reuse the lane's CA, renew what is due, and
# issue the harness's client certificate. Returns 1 only when the lane is on
# and the PKI is unusable; with the lane off a failure is a warning.
lane_tls_init() {
    local lane="${1:-native}"
    export RE_PKI_LANE="$lane"
    LANE_TLS_READY=0; LANE_TLS_CA=""; LANE_TLS_CRL=""; LANE_TLS_HARNESS_CERT=""; LANE_TLS_HARNESS_KEY=""
    if ! { python3 "$LANE_TLS_PKI" init >/dev/null &&
           python3 "$LANE_TLS_PKI" renew >/dev/null &&
           python3 "$LANE_TLS_PKI" issue harness --kind client >/dev/null; } 2>/dev/null; then
        if lane_tls_enabled; then
            _lane_tls_say warn "RE_TLS=on but the $lane PKI is unusable ($LANE_TLS_PKI)"
            return 1
        fi
        _lane_tls_say warn "the $lane PKI could not be prepared; the lane stays plaintext (RE_TLS=off)"
        return 0
    fi
    LANE_TLS_CA=$(_lane_tls_path harness ca)
    LANE_TLS_CRL=$(_lane_tls_path harness crl)
    LANE_TLS_HARNESS_CERT=$(_lane_tls_path harness chain)
    LANE_TLS_HARNESS_KEY=$(_lane_tls_path harness key)
    LANE_TLS_READY=1
    # The harness's own trust, for re_tls.py and anything else CI runs. Not the
    # services' RE_TLS_* names: a child would inherit those and serve with the
    # harness's identity.
    if lane_tls_enabled; then
        export RE_HARNESS_TLS_CA="$LANE_TLS_CA" RE_HARNESS_TLS_CERT="$LANE_TLS_HARNESS_CERT" RE_HARNESS_TLS_KEY="$LANE_TLS_HARNESS_KEY"
    else
        unset RE_HARNESS_TLS_CA RE_HARNESS_TLS_CERT RE_HARNESS_TLS_KEY
    fi
}

# lane_tls_issue_service NAME HOST_IP: a server certificate for a listener CI
# runs itself (the instance registry shim), covering localhost, NAME.localhost,
# 127.0.0.1 and HOST_IP. Sets SVC_TLS_CERT/KEY, empty unless the lane is on.
# shellcheck disable=SC2034  # SVC_TLS_* are read by the caller (registry.sh)
lane_tls_issue_service() {
    local name="$1" host_ip="${2:-127.0.0.1}"
    SVC_TLS_CERT=""; SVC_TLS_KEY=""
    lane_tls_enabled || return 0
    [ "$LANE_TLS_READY" = 1 ] || return 1
    local args="--kind server --dns localhost --dns $name.localhost --ip 127.0.0.1"
    [ "$host_ip" != "127.0.0.1" ] && args="$args --ip $host_ip"
    # shellcheck disable=SC2086  # args is a word list built above
    python3 "$LANE_TLS_PKI" issue "$name" $args >/dev/null || return 1
    SVC_TLS_CERT=$(_lane_tls_path "$name" chain)
    SVC_TLS_KEY=$(_lane_tls_path "$name" key)
}

# lane_tls_issue_instance ID UUID HOST_IP: issue the instance's certificate
# (serves and calls, so kind both; urn:uuid:<UUID> in its SANs) and set
# INST_TLS_CERT/KEY/CA/CRL, which are empty unless the lane is on.
# shellcheck disable=SC2034  # INST_TLS_* are read by the caller (startUniverse.sh)
lane_tls_issue_instance() {
    local id="$1" uuid="$2" host_ip="${3:-127.0.0.1}"
    INST_TLS_CERT=""; INST_TLS_KEY=""; INST_TLS_CA=""; INST_TLS_CRL=""
    [ "$LANE_TLS_READY" = 1 ] || { lane_tls_enabled && return 1; return 0; }
    local args="--kind both --dns localhost --dns $id.localhost --ip 127.0.0.1"
    [ "$host_ip" != "127.0.0.1" ] && args="$args --ip $host_ip"
    [ -n "$uuid" ] && args="$args --instance-uuid $uuid"
    # shellcheck disable=SC2086  # args is a word list built above
    python3 "$LANE_TLS_PKI" issue "$id" $args >/dev/null || { lane_tls_enabled && return 1; return 0; }
    if lane_tls_enabled; then
        INST_TLS_CERT=$(_lane_tls_path "$id" chain)
        INST_TLS_KEY=$(_lane_tls_path "$id" key)
        INST_TLS_CA="$LANE_TLS_CA"
        INST_TLS_CRL="$LANE_TLS_CRL"
    fi
}

# lane_curl: a curl that speaks TLS 1.3. macOS's /usr/bin/curl is built on
# SecureTransport and cannot; it is refused when the lane is on.
lane_curl() {
    local c
    for c in /opt/homebrew/opt/curl/bin/curl /usr/local/opt/curl/bin/curl "$(command -v curl 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] || continue
        if "$c" -V 2>/dev/null | head -1 | grep -q -E "OpenSSL|BoringSSL|GnuTLS|wolfSSL|rustls"; then
            echo "$c"; return 0
        fi
    done
    if lane_tls_enabled; then
        _lane_tls_say warn "no TLS 1.3-capable curl (macOS /usr/bin/curl is SecureTransport); install Homebrew curl"
        return 1
    fi
    command -v curl
}

# lane_curl_get URL [curl args...]: GET with the lane's TLS settings when on.
lane_curl_get() {
    local url="$1"; shift
    local c; c=$(lane_curl) || return 1
    if lane_tls_enabled && [ "$LANE_TLS_READY" = 1 ]; then
        "$c" --tlsv1.3 --cacert "$LANE_TLS_CA" --cert "$LANE_TLS_HARNESS_CERT" --key "$LANE_TLS_HARNESS_KEY" "$@" "$url"
    else
        "$c" "$@" "$url"
    fi
}
