#!/bin/bash

# Verify Reality Engine Startup
# Checks that all services are running and healthy

set -e

# Colors
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
    echo -e "${BLUE}→${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo "=================================================="
echo "Reality Engine Startup Verification"
echo "=================================================="
echo ""

# Step 1: Check Docker is running
print_info "Checking Docker..."
if ! docker info > /dev/null 2>&1; then
    print_error "Docker is not running"
    echo "Please start Docker Desktop and try again"
    exit 1
fi
print_success "Docker is running"
echo ""

# Step 2: Check containers
print_info "Checking Docker containers..."
EXPECTED_CONTAINERS=(
    "reality-engine-qdrant"
    "reality-engine-app"
    "reality-engine-visualizer-backend"
    "reality-engine-visualizer-frontend"
    "reality-engine-perception-backend"
    "reality-engine-perception-frontend"
)

MISSING_CONTAINERS=()
for container in "${EXPECTED_CONTAINERS[@]}"; do
    if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        print_success "Container running: $container"
    else
        print_error "Container not running: $container"
        MISSING_CONTAINERS+=("$container")
    fi
done

if [ ${#MISSING_CONTAINERS[@]} -gt 0 ]; then
    echo ""
    print_error "Missing containers: ${MISSING_CONTAINERS[*]}"
    echo "Run: ./scripts/start.sh"
    exit 1
fi
echo ""

# Step 3: Check service health
print_info "Checking service health endpoints..."

# Qdrant
if curl -s http://localhost:6333/ > /dev/null 2>&1; then
    print_success "Qdrant responsive on port 6333"
else
    print_error "Qdrant not responsive"
    echo "Check logs: docker logs reality-engine-qdrant"
    exit 1
fi

# Reality Engine API
if curl -s http://localhost:3000/api/health > /dev/null 2>&1; then
    print_success "Reality Engine API responsive on port 3000"
else
    print_error "Reality Engine API not responsive"
    echo "Check logs: docker logs reality-engine-app"
    exit 1
fi

# Visualizer Backend
if curl -s http://localhost:3001/health > /dev/null 2>&1; then
    print_success "Visualizer Backend responsive on port 3001"
else
    print_error "Visualizer Backend not responsive"
    echo "Check logs: docker logs reality-engine-visualizer-backend"
    exit 1
fi

# Visualizer Frontend
if curl -s http://localhost:5173/ > /dev/null 2>&1; then
    print_success "Visualizer Frontend responsive on port 5173"
else
    print_error "Visualizer Frontend not responsive"
    echo "Check logs: docker logs reality-engine-visualizer-frontend"
    exit 1
fi

# Perception Engine Backend
if curl -s http://localhost:3004/api/health > /dev/null 2>&1; then
    print_success "Perception Engine Backend responsive on port 3004"
else
    print_error "Perception Engine Backend not responsive"
    echo "Check logs: docker logs reality-engine-perception-backend"
    exit 1
fi

# Perception Engine Frontend
if curl -s http://localhost:3005/ > /dev/null 2>&1; then
    print_success "Perception Engine Frontend responsive on port 3005"
else
    print_error "Perception Engine Frontend not responsive"
    echo "Check logs: docker logs reality-engine-perception-frontend"
    exit 1
fi
echo ""

# Step 4: Check frontend build includes new components
print_info "Checking frontend build..."
FRONTEND_ASSETS=$(docker exec reality-engine-visualizer-frontend ls /usr/share/nginx/html/assets/ 2>/dev/null)
if echo "$FRONTEND_ASSETS" | grep -q "index.*\.css"; then
    CSS_FILE=$(echo "$FRONTEND_ASSETS" | grep "index.*\.css")
    CSS_SIZE=$(docker exec reality-engine-visualizer-frontend stat -f%z "/usr/share/nginx/html/assets/$CSS_FILE" 2>/dev/null || echo "0")

    if [ "$CSS_SIZE" -gt 15000 ]; then
        print_success "Frontend build includes new styles (CSS: ${CSS_SIZE} bytes)"
    else
        print_warning "Frontend CSS may be outdated (${CSS_SIZE} bytes, expected >15KB)"
        echo "Consider rebuilding: docker-compose build --no-cache visualizer-frontend"
    fi
else
    print_error "Frontend assets not found"
    exit 1
fi
echo ""

# Step 5: Check API has machines loaded
print_info "Checking loaded machines..."
MACHINES_RESPONSE=$(curl -s http://localhost:3000/api/machines)
MACHINE_COUNT=$(echo "$MACHINES_RESPONSE" | grep -o '"id"' | wc -l | tr -d ' ')

if [ "$MACHINE_COUNT" -gt 0 ]; then
    print_success "Machines loaded: $MACHINE_COUNT"
else
    print_warning "No machines loaded yet"
    echo "Machines will be loaded on first API startup"
fi
echo ""

# Step 6: Check for perceptual mappings
print_info "Checking perceptual space configuration..."
PERCEPTUAL_COUNT=$(echo "$MACHINES_RESPONSE" | grep -o '"perceptualMapping"' | wc -l | tr -d ' ')

if [ "$PERCEPTUAL_COUNT" -gt 0 ]; then
    print_success "Machines with perceptual mappings: $PERCEPTUAL_COUNT"
else
    print_warning "No perceptual mappings found"
    echo "Check that machine JSON files include perceptualMapping"
fi
echo ""

# Summary
echo "=================================================="
echo "Verification Complete!"
echo "=================================================="
echo ""
echo "All Services Running:"
echo "  ✓ Qdrant Vector DB:           http://localhost:6333"
echo "  ✓ Reality Engine API:         http://localhost:3000"
echo "  ✓ Visualizer Backend:         http://localhost:3001"
echo "  ✓ Visualizer Frontend:        http://localhost:5173"
echo "  ✓ Perception Engine Backend:  http://localhost:3004"
echo "  ✓ Perception Engine Frontend: http://localhost:3005"
echo ""
echo "To access the visualizer:"
echo "  1. Open: http://localhost:5173"
echo "  2. Load a machine (e.g., RSFlipFlop)"
echo "  3. Switch to 'Graph' view"
echo "  4. Scroll down to see Universal Input Vector Display"
echo "  5. Click 'Random Stream Generator' to generate test data"
echo ""
echo "To view logs:"
echo "  docker logs reality-engine-app"
echo "  docker logs reality-engine-visualizer-frontend"
echo ""
