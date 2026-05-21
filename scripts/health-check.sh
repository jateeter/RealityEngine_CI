#!/bin/bash

# Reality Engine - Health Check Script
# Performs detailed health checks on all components

echo "=================================================="
echo "Reality Engine - Health Check"
echo "=================================================="
echo ""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load environment variables
if [ -f .env ]; then
    source .env
fi

PORT=${PORT:-3000}
QDRANT_URL=${QDRANT_URL:-http://localhost:6333}

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check_pass() {
    echo -e "${GREEN}✓ PASS${NC} - $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

check_fail() {
    echo -e "${RED}✗ FAIL${NC} - $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_warn() {
    echo -e "${YELLOW}⚠ WARN${NC} - $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

echo "Running health checks..."
echo ""

# 1. Check Docker
echo "[1/14] Docker Daemon"
if docker info > /dev/null 2>&1; then
    check_pass "Docker is running"
else
    check_fail "Docker is not running"
fi
echo ""

# 2. Check Qdrant Container
echo "[2/14] Qdrant Container"
if docker-compose ps qdrant 2>/dev/null | grep -q "Up"; then
    check_pass "Qdrant container is running"
else
    check_fail "Qdrant container is not running"
fi
echo ""

# 3. Check Qdrant HTTP
echo "[3/14] Qdrant HTTP Endpoint"
if curl -s -o /dev/null -w "%{http_code}" $QDRANT_URL/health | grep -q "200"; then
    check_pass "Qdrant HTTP endpoint responding"
else
    check_fail "Qdrant HTTP endpoint not responding"
fi
echo ""

# 4. Check Qdrant Collections
echo "[4/14] Qdrant Collections"
COLLECTIONS=$(curl -s $QDRANT_URL/collections 2>/dev/null)
if [ $? -eq 0 ]; then
    check_pass "Qdrant collections accessible"
    COLLECTION_COUNT=$(echo "$COLLECTIONS" | grep -o '"name"' | wc -l | tr -d ' ')
    echo "       Found $COLLECTION_COUNT collection(s)"
else
    check_fail "Cannot access Qdrant collections"
fi
echo ""

# 5. Check API Process
echo "[5/14] Reality Engine API Process"
if [ -f .api.pid ]; then
    API_PID=$(cat .api.pid)
    if ps -p $API_PID > /dev/null 2>&1; then
        check_pass "API process is running (PID: $API_PID)"
    else
        check_fail "API process is not running (stale PID)"
    fi
else
    check_fail "API PID file not found"
fi
echo ""

# 6. Check API HTTP
echo "[6/14] API HTTP Endpoint"
HEALTH_RESPONSE=$(curl -s http://localhost:$PORT/api/health 2>/dev/null)
if [ $? -eq 0 ]; then
    check_pass "API HTTP endpoint responding"
    echo "       Response: $HEALTH_RESPONSE"
else
    check_fail "API HTTP endpoint not responding"
fi
echo ""

# 7. Check API Config
echo "[7/14] API Configuration"
CONFIG=$(curl -s http://localhost:$PORT/api/config 2>/dev/null)
if [ $? -eq 0 ]; then
    check_pass "API configuration accessible"
    echo "$CONFIG" | grep -o '"vectorDimension":[0-9]*' | sed 's/^/       /'
    echo "$CONFIG" | grep -o '"matchThreshold":[0-9.]*' | sed 's/^/       /'
else
    check_fail "Cannot access API configuration"
fi
echo ""

# 8. Check Engine Stats
echo "[8/14] Engine Statistics"
STATS=$(curl -s http://localhost:$PORT/api/engine/stats 2>/dev/null)
if [ $? -eq 0 ]; then
    check_pass "Engine statistics accessible"
    echo "$STATS" | grep -o '"totalSequences":[0-9]*' | sed 's/^/       /'
    echo "$STATS" | grep -o '"totalVectors":[0-9]*' | sed 's/^/       /'
else
    check_fail "Cannot access engine statistics"
fi
echo ""

# 9. Check Disk Space
echo "[9/14] Disk Space"
DISK_USAGE=$(df -h . | awk 'NR==2 {print $5}' | sed 's/%//')
if [ $DISK_USAGE -lt 90 ]; then
    check_pass "Disk space available (${DISK_USAGE}% used)"
elif [ $DISK_USAGE -lt 95 ]; then
    check_warn "Disk space getting low (${DISK_USAGE}% used)"
else
    check_fail "Disk space critical (${DISK_USAGE}% used)"
fi
echo ""

# 10. Check Visualizer Backend
echo "[10/14] Visualizer Backend"
if docker-compose ps visualizer-backend 2>/dev/null | grep -q "Up"; then
    check_pass "Visualizer Backend container is running"
    if curl -s http://localhost:3001/health > /dev/null 2>&1; then
        check_pass "Visualizer Backend endpoint responding"
    else
        check_warn "Visualizer Backend endpoint not responding"
    fi
else
    check_warn "Visualizer Backend container is not running"
fi
echo ""

# 11. Check Visualizer Frontend
echo "[11/14] Visualizer Frontend"
if docker-compose ps visualizer-frontend 2>/dev/null | grep -q "Up"; then
    check_pass "Visualizer Frontend container is running"
else
    check_warn "Visualizer Frontend container is not running"
fi
echo ""

# 12. Check Perception Engine Backend
echo "[12/14] Perception Engine Backend"
if docker-compose ps perception-engine-backend 2>/dev/null | grep -q "Up"; then
    check_pass "Perception Engine Backend container is running"
    if curl -s http://localhost:3004/api/health > /dev/null 2>&1; then
        check_pass "Perception Engine Backend endpoint responding"
    else
        check_warn "Perception Engine Backend endpoint not responding"
    fi
else
    check_warn "Perception Engine Backend container is not running"
fi
echo ""

# 13. Check Perception Engine Frontend
echo "[13/14] Perception Engine Frontend"
if docker-compose ps perception-engine-frontend 2>/dev/null | grep -q "Up"; then
    check_pass "Perception Engine Frontend container is running"
else
    check_warn "Perception Engine Frontend container is not running"
fi
echo ""

# 14. Check Memory
echo "[14/14] Memory Usage"
if [ -f .api.pid ]; then
    API_PID=$(cat .api.pid)
    if ps -p $API_PID > /dev/null 2>&1; then
        MEM_USAGE=$(ps -o rss= -p $API_PID | awk '{print $1/1024}')
        if (( $(echo "$MEM_USAGE < 500" | bc -l) )); then
            check_pass "Memory usage normal (${MEM_USAGE}MB)"
        elif (( $(echo "$MEM_USAGE < 1000" | bc -l) )); then
            check_warn "Memory usage elevated (${MEM_USAGE}MB)"
        else
            check_fail "Memory usage high (${MEM_USAGE}MB)"
        fi
    else
        check_warn "Cannot check memory (API not running)"
    fi
else
    check_warn "Cannot check memory (no PID file)"
fi
echo ""

# Summary
echo "=================================================="
echo "Health Check Summary"
echo "=================================================="
echo ""
echo -e "Passed:   ${GREEN}$PASS_COUNT${NC}"
echo -e "Warnings: ${YELLOW}$WARN_COUNT${NC}"
echo -e "Failed:   ${RED}$FAIL_COUNT${NC}"
echo ""

if [ $FAIL_COUNT -eq 0 ] && [ $WARN_COUNT -eq 0 ]; then
    echo -e "Overall Status: ${GREEN}HEALTHY${NC}"
    exit 0
elif [ $FAIL_COUNT -eq 0 ]; then
    echo -e "Overall Status: ${YELLOW}HEALTHY WITH WARNINGS${NC}"
    exit 0
else
    echo -e "Overall Status: ${RED}UNHEALTHY${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check logs: ./scripts/logs.sh"
    echo "  - Restart services: ./scripts/restart.sh"
    echo "  - Review DEPLOYMENT.md for detailed guidance"
    exit 1
fi
