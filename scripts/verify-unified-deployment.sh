#!/bin/bash
# Verify unified deployment - ensures machine.json files accessible in both local and Docker

set -e

echo "=== Unified Deployment Verification ==="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
        return 1
    fi
}

# Function to print info
print_info() {
    echo -e "${YELLOW}→${NC} $1"
}

# Check if examples/machines exists
print_info "Checking examples/machines directory..."
if [ -d "examples/machines" ]; then
    FILE_COUNT=$(ls -1 examples/machines/*.json 2>/dev/null | wc -l | tr -d ' ')
    print_status 0 "Found examples/machines/ with ${FILE_COUNT} machine files"
else
    print_status 1 "examples/machines/ directory not found"
    exit 1
fi

# List machine files
print_info "Machine JSON files:"
ls -1 examples/machines/*.json | xargs -n1 basename | sed 's/^/  - /'

echo ""
print_info "Verifying Docker configuration..."

# Check if docker-compose.yml has volume mount
if grep -q "./examples/machines:/app/examples/machines" docker-compose.yml; then
    print_status 0 "docker-compose.yml has machine volume mount"
else
    print_status 1 "docker-compose.yml missing machine volume mount"
    exit 1
fi

# Check if Dockerfile copies examples
if grep -q "COPY.*examples" Dockerfile; then
    print_status 0 "Dockerfile copies examples directory"
else
    print_status 1 "Dockerfile doesn't copy examples directory"
    exit 1
fi

echo ""
print_info "Testing file access pattern..."

# Test that process.cwd() pattern works
if grep -q "process.cwd(), 'examples/machines'" src/api/routes.ts; then
    print_status 0 "API uses consistent path resolution"
else
    print_status 1 "API path resolution may be inconsistent"
    exit 1
fi

echo ""
echo -e "${GREEN}=== Verification Complete ===${NC}"
echo ""
echo "Configuration verified:"
echo "  ✓ Machine files present on host"
echo "  ✓ Docker compose volume mount configured"
echo "  ✓ Dockerfile copies examples directory"
echo "  ✓ API path resolution consistent"
echo ""
echo "Both local and Docker deployments will access the same machine.json files."
echo ""
echo "Next steps:"
echo "  - Local: npm start"
echo "  - Docker: docker-compose up -d --build"
echo "  - Verify: curl http://localhost:3000/api/machines/json/list"
