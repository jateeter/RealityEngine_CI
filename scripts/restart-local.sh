#!/bin/bash

# Reality Engine - Local Development Restart Script
# Restarts all locally running services with validation

echo "=================================================="
echo "Reality Engine - Restarting Local Services"
echo "=================================================="
echo ""

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Check if running from project root
if [ ! -f "package.json" ]; then
    echo "Error: Must run from project root directory"
    echo "Usage: ./scripts/restart-local.sh"
    exit 1
fi

# Stop all services
print_info "Phase 1: Stopping all services..."
echo ""
./scripts/stop-local.sh

if [ $? -ne 0 ]; then
    echo ""
    echo "Warning: Stop script reported issues, but continuing..."
fi

echo ""
echo "=================================================="
print_info "Phase 2: Waiting for graceful shutdown..."
echo "=================================================="
echo ""
sleep 5

# Verify critical ports are free before starting
print_info "Verifying ports are free..."
PORTS_IN_USE=""
if lsof -ti:3000 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 3000"
fi
if lsof -ti:3001 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 3001"
fi
if lsof -ti:3004 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 3004"
fi
if lsof -ti:3005 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 3005"
fi
if lsof -ti:5173 > /dev/null 2>&1; then
    PORTS_IN_USE="$PORTS_IN_USE 5173"
fi

if [ -n "$PORTS_IN_USE" ]; then
    echo ""
    echo "Error: Ports still in use:$PORTS_IN_USE"
    echo "Waiting additional 3 seconds for ports to be released..."
    sleep 3

    # Check again
    PORTS_IN_USE=""
    if lsof -ti:3000 > /dev/null 2>&1; then
        PORTS_IN_USE="$PORTS_IN_USE 3000"
    fi
    if lsof -ti:3001 > /dev/null 2>&1; then
        PORTS_IN_USE="$PORTS_IN_USE 3001"
    fi
    if lsof -ti:3004 > /dev/null 2>&1; then
        PORTS_IN_USE="$PORTS_IN_USE 3004"
    fi
    if lsof -ti:3005 > /dev/null 2>&1; then
        PORTS_IN_USE="$PORTS_IN_USE 3005"
    fi
    if lsof -ti:5173 > /dev/null 2>&1; then
        PORTS_IN_USE="$PORTS_IN_USE 5173"
    fi

    if [ -n "$PORTS_IN_USE" ]; then
        echo ""
        echo "Error: Ports still in use after waiting:$PORTS_IN_USE"
        echo "Cannot safely restart. Please run:"
        echo "  ./scripts/stop-local.sh"
        echo "Then wait 10 seconds and try again."
        exit 1
    fi
fi

print_success "All ports are free"
print_success "Ready to restart"
echo ""

# Start all services
echo "=================================================="
print_info "Phase 3: Starting all services..."
echo "=================================================="
echo ""
./scripts/start-local.sh

if [ $? -eq 0 ]; then
    echo ""
    echo "=================================================="
    echo "✨ Restart Complete! ✨"
    echo "=================================================="
    echo ""
    echo "All services restarted and validated successfully"
    echo "Open: http://localhost:5173"
    echo ""
else
    echo ""
    echo "=================================================="
    echo "⚠️  Restart Failed"
    echo "=================================================="
    echo ""
    echo "Some services failed to start. Check logs:"
    echo "  - Backend:         tail -f logs/api.log"
    echo "  - Viz Backend:     tail -f logs/viz-backend.log"
    echo "  - Viz Frontend:    tail -f logs/viz-frontend.log"
    echo ""
    exit 1
fi
