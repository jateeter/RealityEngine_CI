#!/bin/bash

# E2E Testing Script for Docker Deployment
# Runs Playwright tests against the full Docker stack

set -e

echo "🧪 Reality Engine E2E Test Suite"
echo "=================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if Docker is running
echo "📋 Pre-flight checks..."
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}❌ Docker is not running${NC}"
    echo "Please start Docker Desktop and try again"
    exit 1
fi
echo -e "${GREEN}✓ Docker is running${NC}"

# Check if Playwright is installed
if ! npx playwright --version > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Playwright not found. Installing...${NC}"
    npm install --save-dev @playwright/test
    npx playwright install
fi
echo -e "${GREEN}✓ Playwright is installed${NC}"

echo ""
echo "🚀 Starting Docker services..."
docker-compose up -d

echo ""
echo "⏳ Waiting for services to be healthy..."
sleep 10

# Check service health
check_service() {
    local name=$1
    local url=$2
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if curl -f -s -o /dev/null "$url" 2>/dev/null; then
            echo -e "${GREEN}✓ $name is ready${NC}"
            return 0
        fi
        echo -n "."
        sleep 1
        attempt=$((attempt + 1))
    done

    echo -e "${RED}❌ $name failed to start${NC}"
    return 1
}

check_service "Qdrant" "http://localhost:6333/"
check_service "Reality Engine" "http://localhost:3000/api/engine/stats"
check_service "Visualizer Backend" "http://localhost:3001/health"
check_service "Visualizer Frontend" "http://localhost:5173/"

echo ""
echo "✅ All services are healthy!"
echo ""
echo "🧪 Running E2E tests..."
echo ""

# Run Playwright tests
TEST_EXIT_CODE=0
npx playwright test "$@" || TEST_EXIT_CODE=$?

echo ""
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✅ All E2E tests passed!${NC}"
else
    echo -e "${RED}❌ Some E2E tests failed${NC}"
    echo ""
    echo "📊 View the test report:"
    echo "   npx playwright show-report e2e-report"
fi

echo ""
echo "📝 Test artifacts:"
echo "   - HTML Report: e2e-report/index.html"
echo "   - JSON Results: e2e-results.json"
echo "   - Screenshots: test-results/"
echo ""

# Optionally stop services
if [ "$CI" = "true" ] || [ "$STOP_SERVICES" = "true" ]; then
    echo "🛑 Stopping Docker services..."
    docker-compose down
else
    echo "💡 Services are still running. Stop with: docker-compose down"
fi

echo ""
exit $TEST_EXIT_CODE
