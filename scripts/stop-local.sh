#!/bin/bash

# Reality Engine - Local Development Stop Script
# Stops all locally running services gracefully

echo "=================================================="
echo "Reality Engine - Stopping Local Services"
echo "=================================================="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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

# Function to stop process gracefully
stop_process() {
    local pid=$1
    local name=$2
    local wait_time=${3:-10}

    if ps -p $pid > /dev/null 2>&1; then
        print_info "Stopping $name (PID: $pid)..."
        kill $pid

        # Wait for graceful shutdown
        local count=0
        while ps -p $pid > /dev/null 2>&1 && [ $count -lt $wait_time ]; do
            sleep 1
            count=$((count + 1))
        done

        # Force kill if still running
        if ps -p $pid > /dev/null 2>&1; then
            print_info "Force killing $name..."
            kill -9 $pid 2>/dev/null || true
        fi

        print_success "$name stopped"
        return 0
    else
        print_info "$name was not running"
        return 1
    fi
}

STOPPED_COUNT=0

# Stop Visualizer Frontend
if [ -f .viz-frontend.pid ]; then
    VIZ_FRONTEND_PID=$(cat .viz-frontend.pid)
    if stop_process $VIZ_FRONTEND_PID "Visualizer Frontend" 5; then
        STOPPED_COUNT=$((STOPPED_COUNT + 1))
    fi
    rm .viz-frontend.pid
else
    print_info "Visualizer Frontend PID file not found"
fi

echo ""

# Stop Visualizer Backend
if [ -f .viz-backend.pid ]; then
    VIZ_BACKEND_PID=$(cat .viz-backend.pid)
    if stop_process $VIZ_BACKEND_PID "Visualizer Backend" 10; then
        STOPPED_COUNT=$((STOPPED_COUNT + 1))
    fi
    rm .viz-backend.pid
else
    print_info "Visualizer Backend PID file not found"
fi

echo ""

# Stop Reality Engine Backend
if [ -f .api.pid ]; then
    API_PID=$(cat .api.pid)
    if stop_process $API_PID "Reality Engine Backend" 10; then
        STOPPED_COUNT=$((STOPPED_COUNT + 1))
    fi
    rm .api.pid
else
    print_info "Reality Engine Backend PID file not found"
fi

echo ""

# Stop Qdrant (if managed by docker-compose)
print_info "Stopping Qdrant..."
if command -v docker &> /dev/null && docker info > /dev/null 2>&1; then
    if docker ps --filter "name=reality-engine-qdrant" --format "{{.Names}}" | grep -q "reality-engine-qdrant"; then
        docker stop reality-engine-qdrant > /dev/null 2>&1
        print_success "Qdrant stopped"
        STOPPED_COUNT=$((STOPPED_COUNT + 1))
    else
        print_info "Qdrant container not found"
    fi
else
    print_info "Docker not available, skipping Qdrant"
fi

echo ""

# Clean up any stray processes on known ports
print_info "Checking for stray processes..."

CLEANED=0

# Port 3000 (Backend) - Be more careful here
if lsof -ti:3000 > /dev/null 2>&1; then
    # Check if it's a Node process before killing
    PORT_PROCESS=$(lsof -i :3000 | grep LISTEN | awk '{print $1}')

    if [ "$PORT_PROCESS" = "node" ]; then
        print_info "Killing Node.js process on port 3000..."
        lsof -ti:3000 | xargs kill -9 2>/dev/null || true
        CLEANED=$((CLEANED + 1))
    else
        print_info "Port 3000 in use by: $PORT_PROCESS (skipping)"
        echo "  If this is Docker Desktop, restart it or change its port"
    fi
fi

# Port 3001 (Visualizer Backend)
if lsof -ti:3001 > /dev/null 2>&1; then
    print_info "Killing stray process on port 3001..."
    lsof -ti:3001 | xargs kill -9 2>/dev/null || true
    CLEANED=$((CLEANED + 1))
fi

# Port 5173 (Visualizer Frontend)
if lsof -ti:5173 > /dev/null 2>&1; then
    print_info "Killing stray process on port 5173..."
    lsof -ti:5173 | xargs kill -9 2>/dev/null || true
    CLEANED=$((CLEANED + 1))
fi

# Port 3004 (Perception Engine Backend)
if lsof -ti:3004 > /dev/null 2>&1; then
    print_info "Killing stray process on port 3004..."
    lsof -ti:3004 | xargs kill -9 2>/dev/null || true
    CLEANED=$((CLEANED + 1))
fi

# Port 3005 (Perception Engine Frontend)
if lsof -ti:3005 > /dev/null 2>&1; then
    print_info "Killing stray process on port 3005..."
    lsof -ti:3005 | xargs kill -9 2>/dev/null || true
    CLEANED=$((CLEANED + 1))
fi

if [ $CLEANED -gt 0 ]; then
    print_success "Cleaned up $CLEANED stray process(es)"

    # Give the OS time to release ports after force kill
    print_info "Waiting for ports to be released..."
    sleep 2

    # Verify ports are actually free now
    STILL_IN_USE=""
    if lsof -ti:3000 > /dev/null 2>&1; then
        STILL_IN_USE="$STILL_IN_USE 3000"
    fi
    if lsof -ti:3001 > /dev/null 2>&1; then
        STILL_IN_USE="$STILL_IN_USE 3001"
    fi
    if lsof -ti:3004 > /dev/null 2>&1; then
        STILL_IN_USE="$STILL_IN_USE 3004"
    fi
    if lsof -ti:3005 > /dev/null 2>&1; then
        STILL_IN_USE="$STILL_IN_USE 3005"
    fi
    if lsof -ti:5173 > /dev/null 2>&1; then
        STILL_IN_USE="$STILL_IN_USE 5173"
    fi

    if [ -n "$STILL_IN_USE" ]; then
        echo ""
        print_error "Warning: Ports still in use after cleanup:$STILL_IN_USE"
        echo "You may need to wait longer or manually kill processes"
    else
        print_success "All ports successfully released"
    fi
else
    print_info "No stray processes found"
fi

echo ""
echo "=================================================="
echo "All Services Stopped"
echo "=================================================="
echo ""
echo "Summary:"
echo "  - Stopped processes: $STOPPED_COUNT"
echo "  - Cleaned stray processes: $CLEANED"
echo ""
echo "To start again: ./scripts/start-local.sh"
echo ""
