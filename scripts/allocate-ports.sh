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

allocate_ports() {
    local runtime="${1:?runtime required}" index="${2:?index required}"
    local base_re base_pe re_port pe_port

    case "$runtime" in
        scala) base_re=5001; base_pe=5000 ;;
        cpp)   base_re=5301; base_pe=5300 ;;
        lsp)   base_re=5601; base_pe=5600 ;;
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
