#!/bin/bash
# =============================================================================
# setup.sh — First-run setup for RealityEngine_CI
#
# 1. Verifies Docker + docker compose v2 prerequisites
# 2. Copies .env.example → .env (if .env is missing)
# 3. Generates dev TLS certificates (if missing or expiring within 30 days)
# 4. Installs the Loki Docker logging driver (if missing)
# 5. Checks that required sibling repos are present
#
# Usage:  bash scripts/setup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$SCRIPT_DIR/.."

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}ℹ${NC} $*"; }
warn() { echo -e "${RED}⚠${NC} $*"; }
die()  { echo -e "${RED}✗  FATAL:${NC} $*"; exit 1; }

echo "════════════════════════════════════════════════════════════════════"
echo "  RealityEngine_CI — First-run Setup"
echo "════════════════════════════════════════════════════════════════════"
echo ""

# ── 1. Prerequisites ──────────────────────────────────────────────────────
echo "Checking prerequisites..."

command -v docker > /dev/null 2>&1 || die "Docker not installed — install Docker Desktop first"
ok "Docker: $(docker --version | head -1)"

docker compose version > /dev/null 2>&1 || die "docker compose v2 not found (install Docker Desktop >= 3.x)"
ok "docker compose: v$(docker compose version --short 2>/dev/null || echo unknown)"

docker info > /dev/null 2>&1 || die "Docker daemon not running — start Docker Desktop"
ok "Docker daemon reachable"

command -v openssl > /dev/null 2>&1 && ok "openssl available" || warn "openssl not found — cert check skipped"

# ── 2. .env file ──────────────────────────────────────────────────────────
echo ""
if [ ! -f "$CI_DIR/.env" ]; then
    cp "$CI_DIR/.env.example" "$CI_DIR/.env"
    ok "Created .env from .env.example"
    info "Review $CI_DIR/.env and set any required values before starting"
else
    ok ".env already exists"
fi

# ── 3. TLS certificates ───────────────────────────────────────────────────
echo ""
info "Checking TLS certificates..."
MISSING_CERTS=""
for f in certs/server.crt certs/server.key certs/ca.crt certs/keystore.p12; do
    [ ! -f "$CI_DIR/$f" ] && MISSING_CERTS="$MISSING_CERTS $f"
done

if [ -n "$MISSING_CERTS" ]; then
    info "Generating dev TLS certificates (missing:$MISSING_CERTS)..."
    bash "$CI_DIR/certs/generate-dev-certs.sh"
    ok "TLS certificates generated"
elif command -v openssl > /dev/null 2>&1; then
    if ! openssl x509 -in "$CI_DIR/certs/server.crt" -noout -checkend $((30*86400)) > /dev/null 2>&1; then
        warn "TLS cert expires within 30 days — regenerating..."
        bash "$CI_DIR/certs/generate-dev-certs.sh"
        ok "TLS certificates regenerated"
    else
        ok "TLS certificates valid"
    fi
else
    ok "TLS certificates present (skipping expiry check — openssl not found)"
fi

# ── 4. Loki Docker logging driver ─────────────────────────────────────────
echo ""
LOKI_ENABLED=$(docker plugin inspect loki --format '{{.Enabled}}' 2>/dev/null || echo "missing")
if [ "$LOKI_ENABLED" = "missing" ]; then
    info "Installing Loki Docker logging driver..."
    docker plugin install grafana/loki-docker-driver:latest \
        --alias loki --grant-all-permissions 2>/dev/null && ok "Loki driver installed" || \
        warn "Loki driver install failed — run:  bash scripts/setup-loki-driver.sh"
elif [ "$LOKI_ENABLED" = "false" ]; then
    docker plugin enable loki 2>/dev/null && ok "Loki driver enabled" || \
        warn "Loki driver could not be enabled"
else
    ok "Loki Docker logging driver ready"
fi

# ── 5. Sibling repo check ─────────────────────────────────────────────────
echo ""
info "Checking sibling repos..."
ALL_FOUND=true
REQUIRED="RealityEngine_Scala RealityEngine_Manager RealityEngine_Machines localAIStack localOpenClawStack"
OPTIONAL="RealityEngine_CPP RealityEngine_LSP"
for repo in $REQUIRED; do
    if [ -d "$CI_DIR/../$repo" ]; then
        ok "$repo"
    else
        warn "$repo — NOT FOUND at $(cd "$CI_DIR/.." && pwd)/$repo"
        ALL_FOUND=false
    fi
done
for repo in $OPTIONAL; do
    [ -d "$CI_DIR/../$repo" ] && ok "$repo  (optional)" || \
        info "$repo — not present (optional; needed only for --re-engine=cpp|lsp)"
done

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
chmod +x "$CI_DIR"/scripts/*.sh "$CI_DIR/startUniverse.sh" "$CI_DIR/stopUniverse.sh" 2>/dev/null || true
ok "Script permissions set"

echo ""
if [ "$ALL_FOUND" = true ]; then
    echo "════════════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Setup complete — run:  ./startUniverse.sh${NC}"
    echo "════════════════════════════════════════════════════════════════════"
else
    echo "════════════════════════════════════════════════════════════════════"
    echo -e "  ${YELLOW}Setup complete with warnings — clone missing repos and retry${NC}"
    echo "════════════════════════════════════════════════════════════════════"
fi
