#!/usr/bin/env bash
# lane-get.sh: a GET that speaks the lane (RealityEngine_CI#668, #732).
#
# Under RE_TLS=on the instance registry and every engine require mTLS, so a
# probe presents the harness's lane CA and client certificate
# (RE_HARNESS_TLS_CA/CERT/KEY, exported by lane-tls.sh's lane_tls_init) with a
# TLS 1.3 curl; macOS's SecureTransport curl cannot. Without the lane it is the
# probe it always was. Plain probes made the deployment gate
# (run-all-tests.sh --deployment) read a running TLS universe as "live stack
# down" and its parity scripts report "registry unreachable" (2026-11-18).
#
#   lane_on                  the lane is on and the harness material is set
#   lane_get URL [curl args] GET URL, quietly (-s); add -f, --max-time, -H ...

lane_curl_bin() {
    local c
    for c in /opt/homebrew/opt/curl/bin/curl /usr/local/opt/curl/bin/curl "$(command -v curl 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && "$c" -V 2>/dev/null | head -1 | grep -qE "OpenSSL|BoringSSL|GnuTLS|wolfSSL|rustls" && { echo "$c"; return 0; }
    done
    command -v curl
}

lane_on() {
    [ "${RE_TLS:-off}" = on ] && [ -n "${RE_HARNESS_TLS_CA:-}" ] && [ -n "${RE_HARNESS_TLS_CERT:-}" ] && [ -n "${RE_HARNESS_TLS_KEY:-}" ]
}

lane_get() {
    local url="$1"; shift
    if lane_on && [[ "$url" == https://* ]]; then
        "$(lane_curl_bin)" -s --tlsv1.3 --cacert "$RE_HARNESS_TLS_CA" --cert "$RE_HARNESS_TLS_CERT" --key "$RE_HARNESS_TLS_KEY" "$@" "$url"
    elif [[ "$url" == https://* ]]; then
        curl -sk "$@" "$url"
    else
        curl -s "$@" "$url"
    fi
}
