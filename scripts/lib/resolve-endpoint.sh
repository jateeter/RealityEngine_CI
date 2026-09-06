#!/bin/bash
# Endpoint resolution from the instance registry — RealityEngine_CI#278.
#
# One resolver, so that six consumers cannot each parse the registry slightly
# differently. That is not hypothetical: the parity signature ended up comparing
# `machineId` and nothing else useful because two places disagreed about what a
# key set meant, and #292 found the shared filters and a stage's local copy
# disagreeing about the same field.
#
# Usage (sourced):
#   re_endpoint <instance-id>            # RE base URL, e.g. re_endpoint cpp-1
#   pe_endpoint <instance-id>            # PE base URL
#   service_endpoint <name>              # manager_backend | manager_frontend |
#                                        # registry | mcp | swagger | mqtt
#   registry_instance_ids                # one id per line, registry order
#
# Every lookup is BY NAME. There is deliberately no positional accessor:
# RealityEngine_CI#274 is the standing example of `instances[0]` continuing to
# pass while silently comparing a different pair than the test claimed.
#
# Reads RE_REGISTRY_FILE, defaulting to the same path scripts/registry.sh writes.

RESOLVE_REGISTRY_FILE="${RE_REGISTRY_FILE:-/tmp/re-registry/re-registry.json}"

_resolve_query() {
    local expr="$1" arg="${2:-}"
    [ -f "$RESOLVE_REGISTRY_FILE" ] || return 1
    python3 - "$RESOLVE_REGISTRY_FILE" "$expr" "$arg" <<'EOF'
import json, sys
path, expr, arg = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as fh:
        reg = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)
if expr == 'ids':
    for inst in reg.get('instances', []):
        print(inst.get('id', ''))
    sys.exit(0)
if expr in ('re_url', 'pe_url'):
    for inst in reg.get('instances', []):
        if inst.get('id') == arg:
            value = inst.get(expr)
            if not value:
                sys.exit(1)
            print(value)
            sys.exit(0)
    sys.exit(1)
if expr == 'service':
    # `.get('services', {})` rather than `['services']`: a registry written
    # before the services block existed must resolve to "not found", not fault.
    entry = (reg.get('services') or {}).get(arg)
    if not entry or not entry.get('url'):
        sys.exit(1)
    print(entry['url'])
    sys.exit(0)
sys.exit(2)
EOF
}

re_endpoint()  { _resolve_query re_url "${1:?instance id required}"; }
pe_endpoint()  { _resolve_query pe_url "${1:?instance id required}"; }
service_endpoint() { _resolve_query service "${1:?service name required}"; }
registry_instance_ids() { _resolve_query ids; }
