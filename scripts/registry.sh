#!/bin/bash
# Instance registry helpers — CRUD for /tmp/re-registry.json
#
# Source this file, then call:
#   registry_add   <id> <runtime> <re_url> <pe_url> <pid_re> <pid_pe>
#   registry_remove <id>
#   registry_list          — prints full JSON to stdout
#   registry_get    <id>   — prints single instance JSON; exits 1 if not found
#   registry_ids           — one id per line
#   registry_set_service <name> <url>  — upsert a non-instance endpoint
#   registry_services      — prints the services object
#   registry_set_allocation <mode> <stride>  — record the active port template
#   registry_start_server  — serves /tmp/re-registry.json on PORT 5999
#   registry_stop_server   — kills the server started above

REGISTRY_FILE="${RE_REGISTRY_FILE:-/tmp/re-registry/re-registry.json}"
REGISTRY_PID_FILE="/tmp/re-registry-server.pid"
REGISTRY_PORT="${RE_REGISTRY_PORT:-5999}"

_registry_init() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        local host_ip="${HOST_IP:-127.0.0.1}"
        printf '{"host":"%s","instances":[],"services":{}}\n' "$host_ip" > "$REGISTRY_FILE"
    fi
}

# Non-instance endpoints — Manager, the registry shim, MCP, Swagger, MQTT.
#
# The registry already answers "where is engine X" (`re_url`/`pe_url` per
# instance). It could not answer "where is the Manager", so every consumer that
# needed one hardcoded it: 19 literal host:port pairs across the two workflow
# files, and five of six e2e specs (RealityEngine_CI#278).
#
# Published here and read by nothing at first, deliberately. While port
# allocation is still deterministic these values are the same numbers the
# consumers already hardcode, so the publication contract can be settled while
# being provably inert — and the conversion of each consumer is then a change
# that alters no behaviour.
registry_set_service() {
    local name="$1" url="$2"
    [ -n "$name" ] && [ -n "$url" ] || return 0
    _registry_init
    python3 - "$REGISTRY_FILE" "$name" "$url" <<'EOF'
import json, sys
path, name, url = sys.argv[1:]
with open(path) as f:
    reg = json.load(f)
# Backfill: a registry written before this existed has no `services` key, and a
# reader that assumed one would fault on exactly the upgrade path this supports.
services = reg.setdefault('services', {})
def _port(u):
    try:
        return int(u.rsplit(':', 1)[-1].split('/')[0])
    except Exception:
        return 0
services[name] = {'url': url, 'port': _port(url)}
with open(path, 'w') as f:
    json.dump(reg, f, indent=2)
EOF
}

# The allocation template actually in force — RealityEngine_CI#278.
#
# Without this the registry says *where* an engine is and never *how* that was
# decided, so a reader cannot tell a deterministic run from a free-port one, and
# an artifact from a failed run does not say which world produced it.
#
# Nominal is not enough, because the nominal base is not always what is used.
# `allocate_ports` does not shift when a port is busy — it fails. So on a host
# where something already holds the base (macOS gives port 5000 to AirPlay
# Receiver) the operator pins a different one: this checkout carries
# SCALA_PE_BASE=5100 in .env, and Scala comes up on 5100/5101 while the built-in
# default still reads 5000/5001.
#
# A record of the built-in default would therefore publish a number contradicted
# by the endpoints beside it — worse than publishing nothing, because it reads
# as authoritative.
#
# So both are recorded, and reconciled against the instances that actually
# registered: `templates` is what allocation computed from, `effective` is what
# the ports turned out to be, and `shifted` names any runtime where they differ.
# Call this again after spawning to fill `effective` in; it is idempotent, and
# calling it early means the mode is published even if a spawn then fails.
registry_set_allocation() {
    local mode="${1:-deterministic}" stride="${2:-100}"
    _registry_init
    python3 - "$REGISTRY_FILE" "$mode" "$stride" \
             "${SCALA_PE_BASE:-5000}" "${CPP_PE_BASE:-5300}" "${LSP_PE_BASE:-5600}" <<'EOF'
import json, sys
path, mode, stride, scala_pe, cpp_pe, lsp_pe = sys.argv[1:]
stride = int(stride)
with open(path) as f:
    reg = json.load(f)

def pair(pe):
    pe = int(pe)
    return {'pe_base': pe, 're_base': pe + 1}

templates = {'scala': pair(scala_pe), 'cpp': pair(cpp_pe), 'lsp': pair(lsp_pe)}

# Effective bases, derived from the instances that actually came up: take the
# lowest-index instance of each runtime and subtract the stride it was offset
# by. An id is "<runtime>-<n>" with n starting at 1.
effective, shifted = {}, []
lowest = {}
for inst in reg.get('instances', []):
    runtime = inst.get('runtime')
    try:
        idx = int(str(inst.get('id', '')).rsplit('-', 1)[1]) - 1
    except (IndexError, ValueError):
        continue
    if runtime in templates and (runtime not in lowest or idx < lowest[runtime][0]):
        lowest[runtime] = (idx, inst)
for runtime, (idx, inst) in lowest.items():
    re_port, pe_port = inst.get('re_port'), inst.get('pe_port')
    if not re_port or not pe_port:
        continue
    base = {'pe_base': pe_port - idx * stride, 're_base': re_port - idx * stride}
    effective[runtime] = base
    if base != templates[runtime]:
        shifted.append(runtime)

reg['allocation'] = {
    'mode': mode,
    'stride': stride,
    'inForce': mode == 'deterministic',
    'templates': templates,
    'effective': effective,
    # Named rather than implied: a shifted runtime is normal (an occupied port,
    # AirPlay on 5000), but a reader comparing a hardcoded literal against the
    # template needs to know the template was departed from.
    'shifted': sorted(shifted),
}
with open(path, 'w') as f:
    json.dump(reg, f, indent=2)
EOF
}

registry_allocation() {
    [ -f "$REGISTRY_FILE" ] || { echo '{}'; return 0; }
    python3 - "$REGISTRY_FILE" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    print(json.dumps(json.load(f).get('allocation', {})))
EOF
}

registry_services() {
    [ -f "$REGISTRY_FILE" ] || { echo '{}'; return 0; }
    python3 - "$REGISTRY_FILE" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    print(json.dumps(json.load(f).get('services', {})))
EOF
}

registry_add() {
    local id="$1" runtime="$2" re_url="$3" pe_url="$4" pid_re="${5:-}" pid_pe="${6:-}"
    _registry_init
    python3 - "$REGISTRY_FILE" "$id" "$runtime" "$re_url" "$pe_url" "$pid_re" "$pid_pe" <<'EOF'
import json, sys, datetime
path, iid, runtime, re_url, pe_url, pid_re, pid_pe = sys.argv[1:]
with open(path) as f:
    reg = json.load(f)
reg['instances'] = [i for i in reg['instances'] if i['id'] != iid]
def _port(url):
    try: return int(url.rsplit(':', 1)[-1])
    except: return 0
entry = {
    'id': iid, 'runtime': runtime,
    're_url': re_url, 'pe_url': pe_url,
    're_port': _port(re_url), 'pe_port': _port(pe_url),
    'pid_re': int(pid_re) if pid_re else None,
    'pid_pe': int(pid_pe) if pid_pe else None,
    'started_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'status': 'running'
}
reg['instances'].append(entry)
with open(path, 'w') as f:
    json.dump(reg, f, indent=2)
EOF
}

registry_remove() {
    local id="$1"
    [ -f "$REGISTRY_FILE" ] || return 0
    python3 - "$REGISTRY_FILE" "$id" <<'EOF'
import json, sys
path, iid = sys.argv[1:]
with open(path) as f:
    reg = json.load(f)
reg['instances'] = [i for i in reg['instances'] if i['id'] != iid]
with open(path, 'w') as f:
    json.dump(reg, f, indent=2)
EOF
}

registry_list() {
    [ -f "$REGISTRY_FILE" ] && cat "$REGISTRY_FILE" || echo '{"host":"","instances":[]}'
}

registry_get() {
    local id="$1"
    [ -f "$REGISTRY_FILE" ] || { echo "{}"; return 1; }
    python3 - "$REGISTRY_FILE" "$id" <<'EOF'
import json, sys
path, iid = sys.argv[1:]
with open(path) as f:
    reg = json.load(f)
for inst in reg.get('instances', []):
    if inst['id'] == iid:
        print(json.dumps(inst))
        sys.exit(0)
sys.exit(1)
EOF
}

registry_ids() {
    [ -f "$REGISTRY_FILE" ] || return 0
    python3 - "$REGISTRY_FILE" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    reg = json.load(f)
for inst in reg.get('instances', []):
    print(inst['id'])
EOF
}

# Reap a stale registry shim still bound to REGISTRY_PORT. A prior run that
# crashed or was never stopped (registry_stop_server not called) leaves its
# python3 http.server holding :$REGISTRY_PORT but dead — the new bind then fails
# and the readiness poll times out, failing the whole multi-engine deploy at
# phase 3.5. Kill the recorded PID first, then any python3 listener still on the
# port (guarded so an unrelated service is never killed), and wait for release.
_registry_free_port() {
    local pid
    if [ -f "$REGISTRY_PID_FILE" ]; then
        pid="$(cat "$REGISTRY_PID_FILE" 2>/dev/null || true)"
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
        rm -f "$REGISTRY_PID_FILE"
    fi
    pid="$(lsof -ti tcp:"$REGISTRY_PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ]; then
        case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
            *[Pp]ython*)
                echo "[registry] reaping stale shim (pid $pid) on :$REGISTRY_PORT" >&2
                kill -9 "$pid" 2>/dev/null || true ;;
            *)
                echo "[registry] warning: :$REGISTRY_PORT held by non-python process $pid — not reaping" >&2 ;;
        esac
    fi
    local _n=0
    while [ "$_n" -lt 10 ]; do
        lsof -ti tcp:"$REGISTRY_PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
        _n=$((_n + 1)); sleep 0.3
    done
}

registry_start_server() {
    # Serve a dedicated subdirectory so only registry files are exposed (not all of /tmp/)
    local serve_dir
    serve_dir="$(dirname "$REGISTRY_FILE")"
    mkdir -p "$serve_dir"
    _registry_init
    _registry_free_port
    python3 -c "
import http.server, os, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
http.server.HTTPServer(('0.0.0.0', int(sys.argv[2])), H).serve_forever()
" "$serve_dir" "$REGISTRY_PORT" > /tmp/re-registry-server.log 2>&1 &
    echo $! > "$REGISTRY_PID_FILE"
}

registry_stop_server() {
    if [ -f "$REGISTRY_PID_FILE" ]; then
        local pid; pid="$(cat "$REGISTRY_PID_FILE" 2>/dev/null || true)"
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
        rm -f "$REGISTRY_PID_FILE"
    fi
}
