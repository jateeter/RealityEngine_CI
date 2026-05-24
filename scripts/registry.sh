#!/bin/bash
# Instance registry helpers — CRUD for /tmp/re-registry.json
#
# Source this file, then call:
#   registry_add   <id> <runtime> <re_url> <pe_url> <pid_re> <pid_pe>
#   registry_remove <id>
#   registry_list          — prints full JSON to stdout
#   registry_get    <id>   — prints single instance JSON; exits 1 if not found
#   registry_ids           — one id per line
#   registry_start_server  — serves /tmp/re-registry.json on PORT 5999
#   registry_stop_server   — kills the server started above

REGISTRY_FILE="${RE_REGISTRY_FILE:-/tmp/re-registry/re-registry.json}"
REGISTRY_PID_FILE="/tmp/re-registry-server.pid"
REGISTRY_PORT="${RE_REGISTRY_PORT:-5999}"

_registry_init() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        local host_ip="${HOST_IP:-127.0.0.1}"
        printf '{"host":"%s","instances":[]}\n' "$host_ip" > "$REGISTRY_FILE"
    fi
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

registry_start_server() {
    # Serve a dedicated subdirectory so only registry files are exposed (not all of /tmp/)
    local serve_dir
    serve_dir="$(dirname "$REGISTRY_FILE")"
    mkdir -p "$serve_dir"
    _registry_init
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
