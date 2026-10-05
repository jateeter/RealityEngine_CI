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
#
# The ledger is a FILE, not only a shell variable. startUniverse.sh calls
# `ports=$(allocate_ports …)`, and command substitution runs in a subshell, so a
# claim recorded in a variable was gone before the next instance asked. Until an
# engine binds its port, nothing is listening for lsof to see, so two instances
# could be handed the same number. test-allocate-ports.sh T16 caught it
# intermittently on the hosted lane, whose parity job runs --free-ports with
# four instances. The file is created once and exported, so every subshell of
# the run reads and appends the same ledger.
#
# Any free port will do. The allocator does not try to pack, minimise or
# predict ports (owner, 2026-10-05); it only guarantees each claim is distinct
# within a run.
if [ -z "${_RE_PORT_LEDGER:-}" ]; then
    _RE_PORT_LEDGER="$(mktemp "${TMPDIR:-/tmp}/re-port-ledger.XXXXXX")"
    export _RE_PORT_LEDGER
fi
_RE_CLAIMED_PORTS="${_RE_CLAIMED_PORTS:-}"
_RE_ALLOCATED_PORT=""

# Ask the OS for a free port: bind to port 0 and read back what was assigned.
# A function of its own so a test can force the collision the ledger exists for.
_re_probe_port() {
    python3 -c "
import socket
s = socket.socket()
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
" 2>/dev/null
}

_claim_free_port() {
    local port
    for _ in $(seq 1 20); do
        port=$(_re_probe_port) || continue
        [ -n "$port" ] || continue
        case " $_RE_CLAIMED_PORTS " in *" $port "*) continue ;; esac
        if grep -qx "$port" "$_RE_PORT_LEDGER" 2>/dev/null; then
            continue
        fi
        if lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; then
            continue
        fi
        echo "$port" >> "$_RE_PORT_LEDGER"
        _RE_CLAIMED_PORTS="$_RE_CLAIMED_PORTS $port"
        _RE_ALLOCATED_PORT="$port"
        return 0
    done
    echo "_claim_free_port: no free port after 20 attempts" >&2
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
        _claim_free_port || return 1
        re_port="$_RE_ALLOCATED_PORT"
        _claim_free_port || return 1
        pe_port="$_RE_ALLOCATED_PORT"
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
