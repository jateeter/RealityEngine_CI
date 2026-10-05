#!/usr/bin/env bash
# Unit tests for scripts/serve_openapi.py — the Swagger portal's proxy.
#
# The engines serve TLS with certificates from the dev CA, which the system
# trust store does not hold. The proxy opened a default HTTPSConnection, so in
# the Docker lane — whose instance registry lists https engines — every "Try it
# out" request failed ("Swagger RE/PE proxy execution failed for scala").
#
# These tests stand up a real HTTPS "engine" with a certificate from a throwaway
# CA, point the portal's instance registry at it, and go through the proxy:
#   - trusted CA (RE_CA_CERT)    -> the engine answers through the proxy
#   - a CA the portal doesn't trust -> 502, never a silent pass
#
# And the instance-scoped route (#323): /proxy/instance/<id>/<re|pe>/... reaches
# the named instance, and every served spec lists every running instance of
# its surface, globally and on each path.
#
# Usage: bash scripts/tests/test-serve-openapi.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() {
    local p
    for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill "$p" 2>/dev/null || true; done
    rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }

command -v openssl >/dev/null || { echo "openssl not found — cannot build the test CA" >&2; exit 1; }

# A CA OpenSSL 3 will verify against (keyUsage present), and a localhost leaf.
make_ca() {  # <dir>
    mkdir -p "$1"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=test-ca" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$1/ca.key" -out "$1/ca.crt" >/dev/null 2>&1
}
make_leaf() {  # <ca-dir> <out-dir>
    mkdir -p "$2"
    openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
        -keyout "$2/server.key" -out "$2/server.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > "$2/ext"
    openssl x509 -req -in "$2/server.csr" -CA "$1/ca.crt" -CAkey "$1/ca.key" -CAcreateserial \
        -days 1 -extfile "$2/ext" -out "$2/server.crt" >/dev/null 2>&1
}

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

wait_for() {  # <url> [curl args...]
    local url="$1"; shift
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "$@" "$url" && return 0
        sleep 0.1
    done
    return 1
}

# An HTTPS "engine" answering GET /api/health.
start_engine() {  # <cert-dir> <port>
    python3 - "$1" "$2" <<'PY' &
import http.server, ssl, sys
d, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ('{"status":"healthy","port":%d}' % port).encode()
        self.send_response(200 if self.path == "/api/health" else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(f"{d}/server.crt", f"{d}/server.key")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
    PIDS+=("$!")
}

start_portal() {  # <registry> <port> <ca>
    RE_CA_CERT="$3" python3 "$CI_DIR/scripts/serve_openapi.py" \
        --host 127.0.0.1 --port "$2" --docroot "$CI_DIR/docs/openapi" --registry "$1" \
        >"$TMP/portal-$2.log" 2>&1 &
    PIDS+=("$!")
}

registry_for() {  # <engine-port> <out>
    printf '{"instances":[{"id":"scala-1","runtime":"scala","re_url":"https://localhost:%s","pe_url":"https://localhost:%s","status":"running"}]}\n' \
        "$1" "$1" > "$2"
}

make_ca "$TMP/ca"
make_leaf "$TMP/ca" "$TMP/engine"
make_ca "$TMP/other-ca"

ENGINE_PORT="$(free_port)"
start_engine "$TMP/engine" "$ENGINE_PORT"
wait_for "https://localhost:$ENGINE_PORT/api/health" -k || { echo "test engine did not start" >&2; exit 1; }
registry_for "$ENGINE_PORT" "$TMP/registry.json"

echo "serve_openapi.py proxy over TLS"

# 1. The portal trusts the engines' CA: the proxied request reaches the engine.
P1="$(free_port)"
start_portal "$TMP/registry.json" "$P1" "$TMP/ca/ca.crt"
wait_for "http://127.0.0.1:$P1/" || { echo "portal did not start" >&2; exit 1; }
code="$(curl -s -o "$TMP/r1" -w '%{http_code}' "http://127.0.0.1:$P1/proxy/scala/re/api/health")"
if [ "$code" = 200 ] && grep -q healthy "$TMP/r1"; then
    ok "proxy reaches an https engine whose CA it trusts (200)"
else
    bad "proxy to a trusted https engine answered $code: $(cat "$TMP/r1")"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P1/proxy/scala/pe/api/health")"
[ "$code" = 200 ] && ok "the PE surface proxies too (200)" || bad "PE proxy answered $code"

# 2. Verification is real: a CA that did not sign the engine's certificate fails.
P2="$(free_port)"
start_portal "$TMP/registry.json" "$P2" "$TMP/other-ca/ca.crt"
wait_for "http://127.0.0.1:$P2/" || { echo "portal did not start" >&2; exit 1; }
code="$(curl -s -o "$TMP/r2" -w '%{http_code}' "http://127.0.0.1:$P2/proxy/scala/re/api/health")"
if [ "$code" = 502 ]; then
    ok "an untrusted engine certificate is refused (502), not passed"
else
    bad "an untrusted engine certificate answered $code: $(cat "$TMP/r2")"
fi

# 3. A runtime the registry does not list has no target.
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P1/proxy/cpp/re/api/health")"
[ "$code" = 503 ] && ok "a runtime absent from the registry answers 503" || bad "absent runtime answered $code"

echo "serve_openapi.py instance-scoped targets (#323)"

# 4. Two engines of different runtimes; the instance route names each one.
ENGINE2_PORT="$(free_port)"
start_engine "$TMP/engine" "$ENGINE2_PORT"
wait_for "https://localhost:$ENGINE2_PORT/api/health" -k || { echo "second test engine did not start" >&2; exit 1; }
printf '{"instances":[
 {"id":"scala-1","runtime":"scala","re_url":"https://localhost:%s","pe_url":"https://localhost:%s","status":"running"},
 {"id":"cpp-2","runtime":"cpp","re_url":"https://localhost:%s","pe_url":"https://localhost:%s","status":"running"},
 {"id":"lsp-9","runtime":"lsp","re_url":"https://localhost:1","pe_url":"https://localhost:1","status":"stopped"}]}\n' \
    "$ENGINE_PORT" "$ENGINE_PORT" "$ENGINE2_PORT" "$ENGINE2_PORT" > "$TMP/registry2.json"
P3="$(free_port)"
start_portal "$TMP/registry2.json" "$P3" "$TMP/ca/ca.crt"
wait_for "http://127.0.0.1:$P3/" || { echo "portal did not start" >&2; exit 1; }

code="$(curl -s -o "$TMP/r4" -w '%{http_code}' "http://127.0.0.1:$P3/proxy/instance/cpp-2/re/api/health")"
if [ "$code" = 200 ] && grep -q "\"port\": *$ENGINE2_PORT" "$TMP/r4"; then
    ok "the instance route reaches the named instance (cpp-2 RE)"
else
    bad "instance route to cpp-2 answered $code: $(cat "$TMP/r4")"
fi
code="$(curl -s -o "$TMP/r5" -w '%{http_code}' "http://127.0.0.1:$P3/proxy/instance/scala-1/pe/api/health")"
if [ "$code" = 200 ] && grep -q "\"port\": *$ENGINE_PORT" "$TMP/r5"; then
    ok "and a different named instance on the PE surface (scala-1 PE)"
else
    bad "instance route to scala-1 PE answered $code: $(cat "$TMP/r5")"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P3/proxy/instance/lsp-9/re/api/health")"
[ "$code" = 503 ] && ok "a stopped or unknown instance answers 503" || bad "stopped instance answered $code"
code="$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "http://127.0.0.1:$P3/proxy/instance/cpp-2/re/api/health")"
[ "$code" = 204 ] && ok "CORS preflight on the instance route (204)" || bad "preflight answered $code"

# 5. Served specs: every running instance of the surface, the spec's runtime
#    first, ?instance=<id> first when given, and the list on every path.
spec_servers() {  # <url> -> instance ids in server order
    curl -s "$1" | python3 -c '
import sys, re
text = sys.stdin.read()
top = text.split("servers: &instance_servers\n", 1)[1].split("\n", 40)
ids = [re.search(r"/proxy/instance/([^/]+)/", l).group(1) for l in top if l.startswith("- url: ")]
paths = sum(1 for l in text.splitlines() if re.match(r"^  /.*:$", l))
aliased = text.count("    servers: *instance_servers\n")
print(" ".join(ids), f"paths={paths} aliased={aliased}")'
}
got="$(spec_servers "http://127.0.0.1:$P3/scala-re.yaml")"
case "$got" in
    "scala-1 cpp-2 paths="*) ok "scala-re.yaml lists every running instance, scala first: $got" ;;
    *) bad "scala-re.yaml servers: $got" ;;
esac
got="$(spec_servers "http://127.0.0.1:$P3/scala-re.yaml?instance=cpp-2")"
case "$got" in
    "cpp-2 scala-1 "*) ok "?instance=cpp-2 makes it every operation's default: $got" ;;
    *) bad "?instance=cpp-2 servers: $got" ;;
esac
paths="${got##*paths=}"; paths="${paths%% *}"; aliased="${got##*aliased=}"
[ "$paths" -gt 0 ] && [ "$paths" = "$aliased" ] && ok "every path carries the instance list ($aliased of $paths)" \
    || bad "paths=$paths aliased=$aliased"

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
