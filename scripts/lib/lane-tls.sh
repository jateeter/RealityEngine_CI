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

# _lane_tls_link TARGET LINK: point LINK at TARGET. Docker creates a missing bind
# source as an empty directory; such a directory is replaced, anything else that
# is not a link is refused.
_lane_tls_link() {
    local target="$1" link="$2"
    if [ -d "$link" ] && [ ! -L "$link" ]; then
        rmdir "$link" 2>/dev/null || { _lane_tls_say warn "$link is a non-empty directory, not a link; not replacing it"; return 1; }
    elif [ -e "$link" ] && [ ! -L "$link" ]; then
        _lane_tls_say warn "$link is a file, not a link; not replacing it"; return 1
    fi
    ln -sfn "$target" "$link"
}

# lane_tls_docker_instance ID RUNTIME UUID HOST_IP: the docker lane's certificate
# for instance ID, whose RE and PE are the compose services engine-RUNTIME-re
# and engine-RUNTIME-pe. Links what docker-compose.yml mounts:
#   <state>/docker/tls/ID      -> the PKI's issued/ID (chain.pem, key.pem)
#   <state>/docker/tls/ca.crt  -> the lane CA     <state>/docker/tls/ca.crl -> its CRL
# Links, not copies, so keys stay in the PKI's 0600 files; the CA directory is
# never mounted, because it holds the CA key. Writes <state>/docker/ID.tls.env,
# which carries RE_TLS_* (container paths) only when the lane is on.
# <state> is RE_INSTANCE_STATE_DIR, default ~/.reality-engine, as for the
# instance's <id>.env.
lane_tls_docker_instance() {
    local id="$1" rt="$2" uuid="$3" host_ip="${4:-127.0.0.1}"
    local state="${RE_INSTANCE_STATE_DIR:-$HOME/.reality-engine}"
    local env_file="$state/docker/$id.tls.env" links="$state/docker/tls"
    mkdir -p "$links"
    printf '# Lane TLS for %s (RealityEngine_CI#732), written by startUniverse.sh. Empty while RE_TLS is off.\n' "$id" > "$env_file"
    [ "$LANE_TLS_READY" = 1 ] || { lane_tls_enabled && return 1; return 0; }
    local args="--kind both --dns localhost --dns $id.localhost --dns engine-$rt-re --dns engine-$rt-pe"
    args="$args --dns host.docker.internal --ip 127.0.0.1"
    [ "$host_ip" != "127.0.0.1" ] && args="$args --ip $host_ip"
    [ -n "$uuid" ] && args="$args --instance-uuid $uuid"
    # shellcheck disable=SC2086  # args is a word list built above
    python3 "$LANE_TLS_PKI" issue "$id" $args >/dev/null || { lane_tls_enabled && return 1; return 0; }
    local issued; issued=$(dirname "$(_lane_tls_path "$id" chain)")
    _lane_tls_link "$issued" "$links/$id" &&
        _lane_tls_link "$LANE_TLS_CA" "$links/ca.crt" &&
        _lane_tls_link "$LANE_TLS_CRL" "$links/ca.crl" || { lane_tls_enabled && return 1; return 0; }
    if lane_tls_enabled; then
        printf 'RE_TLS_CERT=/run/re-tls/instance/chain.pem\nRE_TLS_KEY=/run/re-tls/instance/key.pem\nRE_TLS_CA=/run/re-tls/ca.crt\nRE_TLS_CRL=/run/re-tls/ca.crl\n' >> "$env_file"
    fi
}

# lane_tls_localai HOST_IP: localAIStack's certificates for its lane overlay
# (localAIStack docker-compose.tls.yml, localAIStack#172). Issues localai-api,
# localai-qdrant and localai-redis (each serves and calls, so a container's own
# healthcheck can present it) and links them, with the lane CA and CRL, into
# <state>/localai/tls as the overlay expects:
#   api/ qdrant/ redis/ -> the PKI's issued/<name> (chain.pem, key.pem)
#   ca.crt ca.crl       -> the lane CA and its CRL
# Links, not copies, as for the docker lane: keys stay in the PKI's 0600 files
# and the CA directory is never mounted. Sets LANE_TLS_LOCALAI_DIR, empty unless
# the lane is on.
# shellcheck disable=SC2034  # LANE_TLS_LOCALAI_DIR is read by the caller (startUniverse.sh)
lane_tls_localai() {
    local host_ip="${1:-127.0.0.1}"
    local dir="${RE_INSTANCE_STATE_DIR:-$HOME/.reality-engine}/localai/tls"
    LANE_TLS_LOCALAI_DIR=""
    lane_tls_enabled || return 0
    [ "$LANE_TLS_READY" = 1 ] || return 1
    mkdir -p "$dir"
    local lan=""
    [ "$host_ip" != "127.0.0.1" ] && lan="--ip $host_ip"
    # shellcheck disable=SC2086  # the --dns/--ip lists are word lists
    python3 "$LANE_TLS_PKI" issue localai-api --kind both --dns localhost --dns localai.localhost \
        --dns api --dns localai_api --dns host.docker.internal --ip 127.0.0.1 $lan >/dev/null &&
    python3 "$LANE_TLS_PKI" issue localai-qdrant --kind both --dns localhost --dns qdrant \
        --dns localai_qdrant --ip 127.0.0.1 >/dev/null &&
    python3 "$LANE_TLS_PKI" issue localai-redis --kind both --dns localhost --dns redis \
        --dns localai_redis --ip 127.0.0.1 >/dev/null || return 1
    local svc
    for svc in api qdrant redis; do
        _lane_tls_link "$(dirname "$(_lane_tls_path "localai-$svc" chain)")" "$dir/$svc" || return 1
    done
    _lane_tls_link "$LANE_TLS_CA" "$dir/ca.crt" && _lane_tls_link "$LANE_TLS_CRL" "$dir/ca.crl" || return 1
    LANE_TLS_LOCALAI_DIR="$dir"
}

# lane_tls_openclaw HOST_IP: localOpenClawStack's certificates for the native
# gateway on the lane (localOpenClawStack#92; its scripts/lib/lane-tls.sh).
# Issues openclaw-gateway (serves TLS 1.3, and calls the Ollama front, CDP and
# the engines with mTLS, so kind both) and openclaw-browser (the sidecar's CDP
# proxy, kind server), and links them, with the lane CA and CRL, into
# <state>/openclaw/tls:
#   gateway/ browser/ -> the PKI's issued/<name> (chain.pem, key.pem)
#   ca.crt ca.crl     -> the lane CA and its CRL
# Sets LANE_TLS_OPENCLAW_DIR, empty unless the lane is on; startUniverse.sh
# passes it to localOpenClawStack as OPENCLAW_TLS_DIR.
# shellcheck disable=SC2034  # LANE_TLS_OPENCLAW_DIR is read by the caller (startUniverse.sh)
lane_tls_openclaw() {
    local host_ip="${1:-127.0.0.1}"
    local dir="${RE_INSTANCE_STATE_DIR:-$HOME/.reality-engine}/openclaw/tls"
    LANE_TLS_OPENCLAW_DIR=""
    lane_tls_enabled || return 0
    [ "$LANE_TLS_READY" = 1 ] || return 1
    mkdir -p "$dir"
    local lan=""
    [ "$host_ip" != "127.0.0.1" ] && lan="--ip $host_ip"
    # shellcheck disable=SC2086  # the --ip list is a word list
    python3 "$LANE_TLS_PKI" issue openclaw-gateway --kind both --dns localhost --dns openclaw.localhost \
        --dns host.docker.internal --ip 127.0.0.1 $lan >/dev/null &&
    python3 "$LANE_TLS_PKI" issue openclaw-browser --kind server --dns localhost --ip 127.0.0.1 >/dev/null || return 1
    _lane_tls_link "$(dirname "$(_lane_tls_path openclaw-gateway chain)")" "$dir/gateway" &&
        _lane_tls_link "$(dirname "$(_lane_tls_path openclaw-browser chain)")" "$dir/browser" &&
        _lane_tls_link "$LANE_TLS_CA" "$dir/ca.crt" && _lane_tls_link "$LANE_TLS_CRL" "$dir/ca.crl" || return 1
    LANE_TLS_OPENCLAW_DIR="$dir"
}

# Ollama's TLS front (localAIStack scripts/ollama_tls_front.py; owner option a,
# RealityEngine_CI#668): TLS 1.3 with mTLS on 127.0.0.1:LANE_OLLAMA_FRONT_PORT,
# relaying to Ollama on 127.0.0.1:11434. Every Ollama client on the lane uses it.
LANE_OLLAMA_FRONT_PORT="${LANE_OLLAMA_FRONT_PORT:-11443}"
LANE_OLLAMA_FRONT_PID_FILE="${LANE_OLLAMA_FRONT_PID_FILE:-/tmp/realityengine-ollama-tls-front.pid}"
LANE_OLLAMA_FRONT_LOG="${LANE_OLLAMA_FRONT_LOG:-/tmp/realityengine-ollama-tls-front.log}"

lane_tls_ollama_front_stop() {
    local pid
    pid=$(cat "$LANE_OLLAMA_FRONT_PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q ollama_tls_front; then
        kill "$pid" 2>/dev/null || true
        local n=0
        while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.25; n=$((n+1)); done
    fi
    rm -f "$LANE_OLLAMA_FRONT_PID_FILE"
}

# lane_tls_ollama_front_start LAS_DIR HOST_IP: (re)start the front with its own
# certificate and wait until it answers over the lane's mTLS. Returns 1 when the
# lane is on and it does not come up; does nothing with the lane off.
lane_tls_ollama_front_start() {
    local las_dir="$1" host_ip="${2:-127.0.0.1}"
    lane_tls_enabled || return 0
    [ "$LANE_TLS_READY" = 1 ] || return 1
    local front="$las_dir/scripts/ollama_tls_front.py"
    [ -f "$front" ] || { _lane_tls_say warn "$front is missing; localAIStack predates its lane TLS (localAIStack#172)"; return 1; }
    local lan=""
    [ "$host_ip" != "127.0.0.1" ] && lan="--ip $host_ip"
    # shellcheck disable=SC2086  # the --ip list is a word list
    python3 "$LANE_TLS_PKI" issue ollama-front --kind server --dns localhost --dns ollama.localhost \
        --dns host.docker.internal --ip 127.0.0.1 $lan >/dev/null || return 1
    lane_tls_ollama_front_stop
    RE_TLS_CERT="$(_lane_tls_path ollama-front chain)" RE_TLS_KEY="$(_lane_tls_path ollama-front key)" \
    RE_TLS_CA="$LANE_TLS_CA" RE_TLS_CRL="$LANE_TLS_CRL" \
        nohup python3 "$front" --bind 127.0.0.1 --port "$LANE_OLLAMA_FRONT_PORT" \
        --pid-file "$LANE_OLLAMA_FRONT_PID_FILE" > "$LANE_OLLAMA_FRONT_LOG" 2>&1 &
    local n=0
    while [ "$n" -lt 40 ]; do
        lane_curl_get "https://localhost:$LANE_OLLAMA_FRONT_PORT/api/version" -sf --max-time 2 -o /dev/null 2>/dev/null && return 0
        sleep 0.25; n=$((n+1))
    done
    _lane_tls_say warn "Ollama's TLS front did not answer on :$LANE_OLLAMA_FRONT_PORT; log: $LANE_OLLAMA_FRONT_LOG"
    return 1
}

# lane_ollama_url FROM: Ollama's address for a client on the host (host) or in a
# container (docker): the front when the lane is on, Ollama itself when off.
lane_ollama_url() {
    local h=localhost port=11434
    [ "${1:-host}" = docker ] && h=host.docker.internal
    lane_tls_enabled && port="$LANE_OLLAMA_FRONT_PORT"
    echo "$(lane_tls_scheme)://$h:$port"
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
