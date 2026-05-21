#!/bin/bash

# Reality Engine - Local Development Start Script
# Starts all services locally (non-Docker) with validation

set -e

echo "=================================================="
echo "Reality Engine - Starting Local Services"
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

print_step() {
    echo -e "${BLUE}▶${NC} $1"
}

# Check if running from project root
if [ ! -f "package.json" ]; then
    print_error "Error: Must run from project root directory"
    echo "Usage: ./scripts/start-local.sh"
    exit 1
fi

# Check if Docker containers are running and stop them
print_info "Checking for running Docker containers..."

# First check if docker is available
if ! command -v docker &> /dev/null; then
    print_info "Docker not available, skipping container check"
elif ! docker info > /dev/null 2>&1; then
    print_info "Docker daemon not running, skipping container check"
else
    # Check for running containers
    RUNNING_CONTAINERS=$(docker ps --format "{{.Names}}" 2>/dev/null | grep "reality-engine" || true)

    if [ -n "$RUNNING_CONTAINERS" ]; then
        print_info "Found running Docker containers:"
        echo "$RUNNING_CONTAINERS" | while read name; do
            echo "  - $name"
        done
        print_info "Stopping Docker containers to free ports..."
        docker-compose down
        if [ $? -eq 0 ]; then
            print_success "Docker containers stopped"
        else
            print_error "Failed to stop Docker containers"
            echo "Manually stop with: docker-compose down"
            exit 1
        fi
        echo ""
        sleep 3
    else
        print_success "No conflicting Docker containers found"
    fi
fi
echo ""

# Double-check: Verify critical ports are free
print_info "Verifying ports are available..."
PORTS_IN_USE=""

if lsof -i :3000 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 3000"
fi
if lsof -i :3001 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 3001"
fi
if lsof -i :5173 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 5173"
fi
if lsof -i :3004 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 3004"
fi
if lsof -i :3005 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 3005"
fi

if [ -n "$PORTS_IN_USE" ]; then
    print_error "Ports still in use:$PORTS_IN_USE"
    echo ""
    echo "Run diagnostic: ./scripts/fix-port-conflict.sh"
    echo "Or force cleanup: ./scripts/stop-local.sh"
    exit 1
else
    print_success "All required ports are available"
fi
echo ""

# Function to check if port is in use
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to wait for service to be ready
wait_for_service() {
    local url=$1
    local name=$2
    local max_retries=${3:-30}
    local retry_count=0

    print_info "Waiting for $name to be ready..."

    while [ $retry_count -lt $max_retries ]; do
        if curl -s -f "$url" > /dev/null 2>&1; then
            print_success "$name is ready"
            return 0
        fi
        retry_count=$((retry_count + 1))
        echo -n "."
        sleep 2
    done

    echo ""
    print_error "$name failed to start (timeout)"
    return 1
}

# Create necessary directories
print_step "Step 1: Creating necessary directories"
mkdir -p logs
mkdir -p qdrant_storage
print_success "Directories created"
echo ""

# MQTT bridge env passthrough — the PE backend (perception-engine/backend)
# reads MQTT_BROKER_URL + MQTT_MAPPINGS_FILE at boot to enable the MQTT
# ingest path.  When MQTT_BROKER_URL is unset the bridge stays disabled
# and the PE behaves as a pure HTTP-driven engine.  Export here so child
# processes inherit unchanged.
export MQTT_BROKER_URL="${MQTT_BROKER_URL:-}"
export MQTT_BROKER_PORT="${MQTT_BROKER_PORT:-1883}"
export MQTT_CLIENT_ID="${MQTT_CLIENT_ID:-reality-engine-pe-ai}"
export MQTT_USERNAME="${MQTT_USERNAME:-}"
export MQTT_PASSWORD="${MQTT_PASSWORD:-}"
export MQTT_KEEPALIVE="${MQTT_KEEPALIVE:-60}"
export MQTT_MAPPINGS_FILE="${MQTT_MAPPINGS_FILE:-}"
export MQTT_MAPPINGS_JSON="${MQTT_MAPPINGS_JSON:-}"
export MQTT_ALLOW_REGION_OVERLAP="${MQTT_ALLOW_REGION_OVERLAP:-0}"
if [ -n "$MQTT_BROKER_URL" ]; then
    print_info "MQTT bridge: ${MQTT_BROKER_URL}${MQTT_MAPPINGS_FILE:+ + $MQTT_MAPPINGS_FILE}"
fi


# Check if built
print_step "Step 2: Checking if project is built"
if [ ! -d "dist" ]; then
    print_info "Project not built. Building..."
    npm run build
    if [ $? -ne 0 ]; then
        print_error "Build failed"
        exit 1
    fi
    print_success "Build complete"
else
    print_success "Project already built"
fi
echo ""

# Step 3: Check/Start Qdrant
print_step "Step 3: Starting Qdrant Vector Database"

if check_port 6333; then
    print_info "Qdrant already running on port 6333"
else
    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH"
        echo "Install Docker Desktop from: https://www.docker.com/products/docker-desktop"
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker info > /dev/null 2>&1; then
        print_error "Docker daemon is not running"
        echo "Start Docker Desktop and try again"
        exit 1
    fi

    print_info "Starting Qdrant via Docker..."
    docker-compose up -d qdrant

    if [ $? -ne 0 ]; then
        print_error "Failed to start Qdrant"
        exit 1
    fi

    # Ensure ONLY Qdrant is running (stop any other containers that may have started)
    print_info "Ensuring only Qdrant container is running..."
    docker stop reality-engine-app 2>/dev/null || true
    docker stop reality-engine-visualizer-backend 2>/dev/null || true
    docker stop reality-engine-visualizer-frontend 2>/dev/null || true
    docker stop reality-engine-perception-backend 2>/dev/null || true
    docker stop reality-engine-perception-frontend 2>/dev/null || true
    docker rm reality-engine-app 2>/dev/null || true
    docker rm reality-engine-visualizer-backend 2>/dev/null || true
    docker rm reality-engine-visualizer-frontend 2>/dev/null || true
    docker rm reality-engine-perception-backend 2>/dev/null || true
    docker rm reality-engine-perception-frontend 2>/dev/null || true
    print_success "Only Qdrant is running in Docker"
fi

# Wait for Qdrant to be ready
if ! wait_for_service "http://localhost:6333/" "Qdrant" 30; then
    print_error "Qdrant health check failed"
    echo "Check logs: docker logs reality-engine-qdrant"
    exit 1
fi
echo ""

# Step 4: Start Reality Engine Backend
print_step "Step 4: Starting Reality Engine Backend"

# Clean up stale PID file first
if [ -f .api.pid ]; then
    OLD_PID=$(cat .api.pid)
    if ps -p $OLD_PID > /dev/null 2>&1; then
        print_success "Reality Engine Backend already running (PID: $OLD_PID)"
        echo ""
        # Skip to next step
    else
        print_info "Removing stale PID file..."
        rm .api.pid
    fi
fi

# Only start if not already running
if [ ! -f .api.pid ]; then
    # Check if port 3000 is available
    if check_port 3000; then
        print_error "Port 3000 already in use"

        # Show what's using the port
        echo ""
        echo "Process using port 3000:"
        lsof -i :3000 | grep LISTEN || echo "  (Could not identify process)"
        echo ""

        # Provide helpful guidance
        echo "Common causes:"
        echo "  1. Docker Desktop using port 3000"
        echo "     Fix: Restart Docker Desktop or change its port in preferences"
        echo ""
        echo "  2. Previous Reality Engine instance still running"
        echo "     Fix: ./scripts/stop-local.sh"
        echo ""
        echo "  3. Another application using port 3000"
        echo "     Fix: lsof -ti:3000 | xargs kill -9"
        echo ""
        exit 1
    fi

    print_info "Starting backend (npm start)..."
    nohup npm start > logs/api.log 2>&1 &
    API_PID=$!
    echo $API_PID > .api.pid
    print_success "Backend started (PID: $API_PID)"

    # Wait for backend to be ready
    if ! wait_for_service "http://localhost:3000/api/health" "Reality Engine Backend" 40; then
        print_error "Backend failed to start"
        echo "Check logs: tail -f logs/api.log"
        kill $API_PID 2>/dev/null || true
        rm .api.pid
        exit 1
    fi
fi
echo ""

# Step 5: Validate Machine JSON Files
print_step "Step 5: Validating Machine JSON Files Access"

MACHINE_COUNT=$(curl -s http://localhost:3000/api/machines/json/list | grep -o '"filename"' | wc -l | tr -d ' ')

if [ "$MACHINE_COUNT" -eq "0" ]; then
    print_error "No machine JSON files found"
    echo "Expected files in: examples/machines/"
    echo "Check backend logs for path resolution issues"
    exit 1
else
    print_success "Found $MACHINE_COUNT machine JSON files"
fi
echo ""

# Step 6: Start Visualizer Backend
print_step "Step 6: Starting Visualizer Backend"

# Check if visualizer backend is built
if [ ! -d "visualizer/backend/dist" ]; then
    print_info "Visualizer backend not built. Building..."
    cd visualizer/backend
    npm run build
    cd ../..
    print_success "Visualizer backend built"
fi

if [ -f .viz-backend.pid ]; then
    OLD_PID=$(cat .viz-backend.pid)
    if ps -p $OLD_PID > /dev/null 2>&1; then
        print_info "Visualizer Backend already running (PID: $OLD_PID)"
    else
        rm .viz-backend.pid
        print_info "Stale PID file removed, starting fresh..."
    fi
fi

if [ ! -f .viz-backend.pid ]; then
    # Check if port 3001 is available
    if check_port 3001; then
        print_error "Port 3001 already in use"
        echo "Stop the process using: lsof -ti:3001 | xargs kill -9"
        exit 1
    fi

    print_info "Starting visualizer backend..."
    cd visualizer/backend
    nohup npm start > ../../logs/viz-backend.log 2>&1 &
    VIZ_BACKEND_PID=$!
    cd ../..
    echo $VIZ_BACKEND_PID > .viz-backend.pid
    print_success "Visualizer backend started (PID: $VIZ_BACKEND_PID)"

    # Wait for visualizer backend to be ready
    if ! wait_for_service "http://localhost:3001/health" "Visualizer Backend" 30; then
        print_error "Visualizer backend failed to start"
        echo "Check logs: tail -f logs/viz-backend.log"
        kill $VIZ_BACKEND_PID 2>/dev/null || true
        rm .viz-backend.pid
        exit 1
    fi
fi
echo ""

# Step 7: Start Visualizer Frontend
print_step "Step 7: Starting Visualizer Frontend"

# Check if visualizer frontend is built for production
# For dev mode, we'll use npm run dev

if [ -f .viz-frontend.pid ]; then
    OLD_PID=$(cat .viz-frontend.pid)
    if ps -p $OLD_PID > /dev/null 2>&1; then
        print_info "Visualizer Frontend already running (PID: $OLD_PID)"
    else
        rm .viz-frontend.pid
        print_info "Stale PID file removed, starting fresh..."
    fi
fi

if [ ! -f .viz-frontend.pid ]; then
    # Check if port 5173 is available
    if check_port 5173; then
        print_error "Port 5173 already in use"
        echo "Stop the process using: lsof -ti:5173 | xargs kill -9"
        exit 1
    fi

    print_info "Starting visualizer frontend (dev mode)..."
    cd visualizer/frontend
    nohup npm run dev > ../../logs/viz-frontend.log 2>&1 &
    VIZ_FRONTEND_PID=$!
    cd ../..
    echo $VIZ_FRONTEND_PID > .viz-frontend.pid
    print_success "Visualizer frontend started (PID: $VIZ_FRONTEND_PID)"

    # Wait for visualizer frontend to be ready
    print_info "Waiting for frontend dev server..."
    sleep 8
    if ! check_port 5173; then
        print_error "Visualizer frontend failed to start"
        echo "Check logs: tail -f logs/viz-frontend.log"
        kill $VIZ_FRONTEND_PID 2>/dev/null || true
        rm .viz-frontend.pid
        exit 1
    fi
    print_success "Visualizer frontend ready"
fi
echo ""

# Step 8: Validate All Services
print_step "Step 8: Validating All Services"

VALIDATION_FAILED=0

# Test Qdrant
if curl -s -f http://localhost:6333/ > /dev/null 2>&1; then
    print_success "Qdrant: OK"
else
    print_error "Qdrant: FAILED"
    VALIDATION_FAILED=1
fi

# Test Reality Engine Backend
if curl -s -f http://localhost:3000/api/health > /dev/null 2>&1; then
    print_success "Reality Engine Backend: OK"
else
    print_error "Reality Engine Backend: FAILED"
    VALIDATION_FAILED=1
fi

# Test Machine JSON Endpoint
RESPONSE=$(curl -s http://localhost:3000/api/machines/json/list)
if echo "$RESPONSE" | grep -q '"machines"'; then
    print_success "Machine JSON API: OK"
else
    print_error "Machine JSON API: FAILED"
    VALIDATION_FAILED=1
fi

# Test Visualizer Backend
if curl -s -f http://localhost:3001/health > /dev/null 2>&1; then
    print_success "Visualizer Backend: OK"
else
    print_error "Visualizer Backend: FAILED"
    VALIDATION_FAILED=1
fi

# Test Visualizer Frontend
if check_port 5173; then
    print_success "Visualizer Frontend: OK"
else
    print_error "Visualizer Frontend: FAILED"
    VALIDATION_FAILED=1
fi

if [ $VALIDATION_FAILED -eq 1 ]; then
    echo ""
    print_error "Some services failed validation"
    echo "Check logs in: logs/"
    exit 1
fi

echo ""
echo ""
echo "=================================================="
echo "✨ Reality Engine Started Successfully! ✨"
echo "=================================================="
echo ""
echo "📊 Services Status:"
echo "  ✓ Qdrant Vector DB:      http://localhost:6333"
echo "  ✓ Qdrant Dashboard:      http://localhost:6333/dashboard"
echo "  ✓ Reality Engine API:    http://localhost:3000"
echo "  ✓ API Health Check:      http://localhost:3000/api/health"
echo "  ✓ Visualizer Backend:    http://localhost:3001"
echo "  ✓ Visualizer Frontend:   http://localhost:5173"
echo ""
echo "📁 Machine JSON Files: $MACHINE_COUNT available"
echo ""
echo "🚀 Quick Start:"
echo "  1. Open: http://localhost:5173"
echo "  2. Click 'Machine Files' (purple button) to browse machines"
echo "  3. Load a machine and start exploring!"
echo ""
echo "📝 Process IDs:"
if [ -f .api.pid ]; then
    echo "  Backend:   $(cat .api.pid)"
fi
if [ -f .viz-backend.pid ]; then
    echo "  Viz Backend: $(cat .viz-backend.pid)"
fi
if [ -f .viz-frontend.pid ]; then
    echo "  Viz Frontend: $(cat .viz-frontend.pid)"
fi
echo ""
echo "📋 Useful Commands:"
echo "  Status:   ./scripts/status.sh"
echo "  Logs:     tail -f logs/*.log"
echo "  Stop:     ./scripts/stop-local.sh"
echo "  Restart:  ./scripts/restart-local.sh"
echo ""
