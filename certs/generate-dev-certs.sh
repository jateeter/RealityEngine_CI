#!/usr/bin/env bash
# Generates a self-signed CA and a service certificate for local development.
#
# Outputs (all in the certs/ directory):
#   ca.key          Root CA private key
#   ca.crt          Root CA certificate (install this as trusted on the host)
#   server.key      Service private key
#   server.crt      Service certificate (signed by ca.crt, valid for all service names)
#   keystore.p12    PKCS12 keystore for JVM services (contains server cert + key + CA chain)
#
# Run from the repo root:  bash certs/generate-dev-certs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYSTORE_PASS="realityengine"

echo "Generating Reality Engine dev certificates..."

# ── Root CA ──────────────────────────────────────────────────────────────────
openssl genrsa -out "${SCRIPT_DIR}/ca.key" 4096

openssl req -x509 -new -nodes \
  -key    "${SCRIPT_DIR}/ca.key" \
  -sha256 -days 3650 \
  -out    "${SCRIPT_DIR}/ca.crt" \
  -subj   "/C=US/ST=Dev/L=Dev/O=RealityEngine/CN=RealityEngine Dev CA"

# ── Service key + CSR ─────────────────────────────────────────────────────────
openssl genrsa -out "${SCRIPT_DIR}/server.key" 2048

openssl req -new \
  -key  "${SCRIPT_DIR}/server.key" \
  -out  "${SCRIPT_DIR}/server.csr" \
  -subj "/C=US/ST=Dev/L=Dev/O=RealityEngine/CN=localhost"

# ── Sign with CA — SANs cover every Docker service hostname + localhost ───────
openssl x509 -req \
  -in     "${SCRIPT_DIR}/server.csr" \
  -CA     "${SCRIPT_DIR}/ca.crt" \
  -CAkey  "${SCRIPT_DIR}/ca.key" \
  -CAcreateserial \
  -out    "${SCRIPT_DIR}/server.crt" \
  -days   825 \
  -sha256 \
  -extfile <(cat <<'SAN'
[ext]
subjectAltName = DNS:localhost,DNS:reality-engine,DNS:visualizer-backend,DNS:perception-engine-backend,DNS:qdrant,DNS:loki,DNS:grafana,DNS:visualizer-frontend,DNS:perception-engine-frontend,IP:127.0.0.1
SAN
) -extensions ext

# ── PKCS12 keystore for JVM services (server cert + key + CA chain) ───────────
openssl pkcs12 -export \
  -out      "${SCRIPT_DIR}/keystore.p12" \
  -inkey    "${SCRIPT_DIR}/server.key" \
  -in       "${SCRIPT_DIR}/server.crt" \
  -certfile "${SCRIPT_DIR}/ca.crt" \
  -name     "reality-engine" \
  -passout  pass:"${KEYSTORE_PASS}"

# ── Clean up CSR and CA serial ────────────────────────────────────────────────
rm -f "${SCRIPT_DIR}/server.csr" "${SCRIPT_DIR}/ca.srl"

# ── Permissions ───────────────────────────────────────────────────────────────
chmod 600 "${SCRIPT_DIR}/ca.key" "${SCRIPT_DIR}/server.key" "${SCRIPT_DIR}/keystore.p12"
chmod 644 "${SCRIPT_DIR}/ca.crt" "${SCRIPT_DIR}/server.crt"

echo ""
echo "✓ certs/ca.key          (CA private key — keep secret)"
echo "✓ certs/ca.crt          (CA certificate — install as trusted)"
echo "✓ certs/server.key      (service private key)"
echo "✓ certs/server.crt      (service certificate, valid 825 days)"
echo "✓ certs/keystore.p12    (JVM keystore, password: ${KEYSTORE_PASS})"
echo ""
echo "SANs: localhost, reality-engine, visualizer-backend, perception-engine-backend,"
echo "      qdrant, loki, grafana, visualizer-frontend, perception-engine-frontend, 127.0.0.1"
echo ""
echo "── Trust the CA on the host to silence browser/client warnings ──────────"
echo "  macOS:   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/ca.crt"
echo "  Linux:   sudo cp certs/ca.crt /usr/local/share/ca-certificates/reality-engine-ca.crt && sudo update-ca-certificates"
echo "  Windows: certutil -addstore -f 'ROOT' certs\\ca.crt"
