#!/bin/bash

# Reality Engine - Validation Script
# Comprehensive health check for all services and functionality

echo "=================================================="
echo "Reality Engine - System Validation"
echo "=================================================="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

print_test() {
    echo -e "${BLUE}▶${NC} Testing: $1"
}

PASSED=0
FAILED=0
WARNINGS=0

# Test 1: Check Qdrant
print_test "Qdrant Vector Database"
if curl -s -f http://localhost:6333/ > /dev/null 2>&1; then
    RESPONSE=$(curl -s http://localhost:6333/)
    print_success "Qdrant is running and healthy"
    echo "  Response: $RESPONSE"
    PASSED=$((PASSED + 1))
else
    print_error "Qdrant is not responding"
    echo "  Expected: http://localhost:6333/"
    echo "  Fix: docker-compose up -d qdrant"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 2: Check Reality Engine Backend
print_test "Reality Engine Backend API"
if curl -s -f http://localhost:3000/api/health > /dev/null 2>&1; then
    print_success "Backend API is running"

    # Check if PID file exists
    if [ -f .api.pid ]; then
        PID=$(cat .api.pid)
        if ps -p $PID > /dev/null 2>&1; then
            print_success "Backend process is running (PID: $PID)"
        else
            print_error "Backend PID file exists but process is dead"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
    PASSED=$((PASSED + 1))
else
    print_error "Backend API is not responding"
    echo "  Expected: http://localhost:3000/api/health"
    echo "  Check logs: tail -f logs/api.log"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 3: Check Machine JSON Files Access
print_test "Machine JSON Files API"
if RESPONSE=$(curl -s http://localhost:3000/api/machines/json/list 2>&1); then
    if echo "$RESPONSE" | grep -q '"machines"'; then
        MACHINE_COUNT=$(echo "$RESPONSE" | grep -o '"filename"' | wc -l | tr -d ' ')
        print_success "Machine JSON API is working"
        print_success "Found $MACHINE_COUNT machine JSON files"

        # List the machines
        if [ "$MACHINE_COUNT" -gt 0 ]; then
            echo "  Available machines:"
            echo "$RESPONSE" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g' | while read -r name; do
                echo "    - $name"
            done
        fi

        PASSED=$((PASSED + 1))
    else
        print_error "Machine JSON API returned unexpected response"
        echo "  Response: $RESPONSE"
        FAILED=$((FAILED + 1))
    fi
else
    print_error "Machine JSON API is not accessible"
    echo "  Error: $RESPONSE"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 4: Verify examples/machines directory
print_test "Machine JSON Files Directory"
if [ -d "examples/machines" ]; then
    FILE_COUNT=$(ls examples/machines/*.json 2>/dev/null | wc -l | tr -d ' ')
    print_success "Directory exists: examples/machines/"
    print_success "Found $FILE_COUNT JSON files on disk"

    if [ "$FILE_COUNT" -gt 0 ]; then
        echo "  Files:"
        ls -1 examples/machines/*.json | while read -r file; do
            basename "$file"
            echo "    - $(basename "$file")"
        done
    fi

    PASSED=$((PASSED + 1))
else
    print_error "Directory not found: examples/machines/"
    echo "  This directory should contain machine JSON definitions"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 5: Check Visualizer Backend
print_test "Visualizer Backend"
if curl -s -f http://localhost:3001/health > /dev/null 2>&1; then
    print_success "Visualizer backend is running"

    # Check if PID file exists
    if [ -f .viz-backend.pid ]; then
        PID=$(cat .viz-backend.pid)
        if ps -p $PID > /dev/null 2>&1; then
            print_success "Visualizer backend process is running (PID: $PID)"
        else
            print_error "Visualizer backend PID file exists but process is dead"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
    PASSED=$((PASSED + 1))
else
    print_error "Visualizer backend is not responding"
    echo "  Expected: http://localhost:3001/health"
    echo "  Check logs: tail -f logs/viz-backend.log"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 6: Check Visualizer Frontend
print_test "Visualizer Frontend"
if lsof -Pi :5173 -sTCP:LISTEN -t >/dev/null 2>&1; then
    print_success "Visualizer frontend is running on port 5173"

    # Check if PID file exists
    if [ -f .viz-frontend.pid ]; then
        PID=$(cat .viz-frontend.pid)
        if ps -p $PID > /dev/null 2>&1; then
            print_success "Visualizer frontend process is running (PID: $PID)"
        else
            print_error "Visualizer frontend PID file exists but process is dead"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
    PASSED=$((PASSED + 1))
else
    print_error "Visualizer frontend is not running"
    echo "  Expected port: 5173"
    echo "  Check logs: tail -f logs/viz-frontend.log"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 7: Test Visualizer Proxy to Backend
print_test "Visualizer Proxy to Reality Engine"
if curl -s -f http://localhost:3001/api/machines/json/list > /dev/null 2>&1; then
    print_success "Visualizer can proxy requests to Reality Engine"
    PASSED=$((PASSED + 1))
else
    print_error "Visualizer proxy is not working"
    echo "  This means the frontend cannot communicate with the backend"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 8: Check for required npm packages
print_test "Node Dependencies"
if [ -d "node_modules" ]; then
    print_success "Main project dependencies installed"
else
    print_error "Main project dependencies not installed"
    echo "  Run: npm install"
    FAILED=$((FAILED + 1))
fi

if [ -d "visualizer/backend/node_modules" ]; then
    print_success "Visualizer backend dependencies installed"
else
    print_error "Visualizer backend dependencies not installed"
    echo "  Run: cd visualizer/backend && npm install"
    FAILED=$((FAILED + 1))
fi

if [ -d "visualizer/frontend/node_modules" ]; then
    print_success "Visualizer frontend dependencies installed"
else
    print_error "Visualizer frontend dependencies not installed"
    echo "  Run: cd visualizer/frontend && npm install"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 9: Check for build artifacts
print_test "Build Artifacts"
if [ -d "dist" ]; then
    print_success "Main project is built (dist/ exists)"
else
    print_error "Main project is not built"
    echo "  Run: npm run build"
    FAILED=$((FAILED + 1))
fi

if [ -d "visualizer/backend/dist" ]; then
    print_success "Visualizer backend is built"
else
    print_error "Visualizer backend is not built"
    echo "  Run: cd visualizer/backend && npm run build"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 10: Check Perception Engine Backend
print_test "Perception Engine Backend"
if curl -s -f http://localhost:3004/api/health > /dev/null 2>&1; then
    print_success "Perception Engine Backend is running"
    PASSED=$((PASSED + 1))
else
    print_error "Perception Engine Backend is not responding"
    echo "  Expected: http://localhost:3004/api/health"
    echo "  Fix: docker-compose up -d perception-engine-backend"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 11: Check /api/perceive endpoint
print_test "Reality Engine /api/perceive Endpoint"
# Build a 256-element zero vector for the test
ZERO_VEC=$(printf '0.0,%.0s' {1..255})0.0
PERCEIVE_RESPONSE=$(curl -s -X POST http://localhost:3000/api/perceive \
    -H "Content-Type: application/json" \
    -d "{\"vector\": [$ZERO_VEC]}" 2>/dev/null)
if echo "$PERCEIVE_RESPONSE" | grep -q '"success"'; then
    print_success "/api/perceive endpoint is working"
    PASSED=$((PASSED + 1))
else
    print_error "/api/perceive endpoint not responding correctly"
    echo "  Expected JSON with 'success' field"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 12: Check Docker
print_test "Docker Environment"
if command -v docker &> /dev/null; then
    print_success "Docker is installed"

    if docker info > /dev/null 2>&1; then
        print_success "Docker daemon is running"
    else
        print_error "Docker daemon is not running"
        echo "  Start Docker Desktop"
        FAILED=$((FAILED + 1))
    fi
else
    print_error "Docker is not installed"
    echo "  Install from: https://www.docker.com/products/docker-desktop"
    FAILED=$((FAILED + 1))
fi
echo ""

# Summary
echo "=================================================="
echo "Validation Summary"
echo "=================================================="
echo ""
echo -e "${GREEN}Passed:${NC}   $PASSED tests"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed:${NC}   $FAILED tests"
fi
if [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}Warnings:${NC} $WARNINGS issues"
fi
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All critical tests passed!${NC}"
    echo ""
    echo "System is operational. Services available at:"
    echo "  - Reality Engine:         http://localhost:3000"
    echo "  - Visualizer:             http://localhost:5173"
    echo "  - Qdrant:                 http://localhost:6333"
    echo "  - Perception Engine:      http://localhost:3004"
    echo "  - Perception Engine UI:   http://localhost:3005"
    echo ""
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    echo ""
    echo "Fix the issues above and run validation again"
    echo ""
    echo "Quick fixes:"
    echo "  - Start services:    ./scripts/start-local.sh"
    echo "  - Restart services:  ./scripts/restart-local.sh"
    echo "  - View logs:         tail -f logs/*.log"
    echo ""
    exit 1
fi
