#!/bin/bash
# Deterministic port allocation for multi-engine instances.
#
# Base ports per runtime:
#   scala  RE=5001  PE=5000
#   cpp    RE=5301  PE=5300
#   lsp    RE=5601  PE=5600
#
# Each additional instance of the same runtime gets +100 on both ports.
#
# Usage (sourced):
#   allocate_ports <runtime> <index>   # prints "<re_port> <pe_port>" or exits 1
#
# RE_FREE_PORTS=true switches to claiming ports the OS says are free, instead of
# computing them (RealityEngine_CI#278 step 4). Default is unset — deterministic,
# byte for byte what it has always done.
#
# Why the option exists: this function does not shift when a base is busy, it
# fails. A host whose base port is taken therefore needs a manual pin — macOS
# gives 5000 to AirPlay Receiver, so this checkout carries SCALA_PE_BASE=5100 in
# .env. Free allocation removes the need for a per-host pin, and removes the
# class of failure where one stale process turns every subsequent run red.

# Claim a port the OS reports as free.
#
# Probe by binding to port 0 and reading back what was assigned. The socket is
# closed before the value is returned, which leaves a race: something else can
# take it between the close and the engine's own bind. That race is inherent to
# handing a port to a separate process — narrowing it is the best available, and
# the caller retries.
#
# Ports claimed during a run are remembered and never handed out twice, even
# after the holder exits, so a late reader with a stale endpoint gets a refused
# connection rather than a different engine that inherited the number.
_RE_CLAIMED_PORTS="${_RE_CLAIMED_PORTS:-}"

_claim_free_port() {
    local attempt port
    for attempt in 1 2 3 4 5; do
        port=$(python3 -c "
import socket
s = socket.socket()
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
" 2>/dev/null) || continue
        [ -n "$port" ] || continue
        case " $_RE_CLAIMED_PORTS " in *" $port "*) continue ;; esac
        if lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
            continue
        fi
        _RE_CLAIMED_PORTS="$_RE_CLAIMED_PORTS $port"
        echo "$port"
        return 0
    done
    echo "_claim_free_port: no free port after 5 attempts" >&2
    return 1
}

allocate_ports() {
    local runtime="${1:?runtime required}" index="${2:?index required}"
    local base_re base_pe re_port pe_port

    # Free mode is opt-in and returns before any of the deterministic path runs,
    # so that path is unchanged rather than conditionally changed.
    if [ "${RE_FREE_PORTS:-false}" = "true" ]; then
        case "$runtime" in
            scala|cpp|lsp) ;;
            *) echo "allocate_ports: unknown runtime '$runtime'" >&2; return 1 ;;
        esac
        re_port=$(_claim_free_port) || return 1
        pe_port=$(_claim_free_port) || return 1
        echo "${re_port} ${pe_port}"
        return 0
    fi

    case "$runtime" in
        scala) base_pe="${SCALA_PE_BASE:-5000}"; base_re=$(( base_pe + 1 )) ;;
        cpp)   base_pe="${CPP_PE_BASE:-5300}";   base_re=$(( base_pe + 1 )) ;;
        lsp)   base_pe="${LSP_PE_BASE:-5600}";   base_re=$(( base_pe + 1 )) ;;
        *)     echo "allocate_ports: unknown runtime '$runtime'" >&2; return 1 ;;
    esac

    re_port=$(( base_re + (index - 1) * 100 ))
    pe_port=$(( base_pe + (index - 1) * 100 ))

    if lsof -i ":${re_port}" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "allocate_ports: RE port ${re_port} already in use" >&2
        return 1
    fi
    if lsof -i ":${pe_port}" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "allocate_ports: PE port ${pe_port} already in use" >&2
        return 1
    fi

    echo "${re_port} ${pe_port}"
}
