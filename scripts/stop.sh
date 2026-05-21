#!/bin/bash

# Reality Engine - Stop Script
# Stops all services gracefully

echo "=================================================="
echo "Reality Engine - Stopping Services"
echo "=================================================="
echo ""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Stop Reality Engine API
if [ -f .api.pid ]; then
    API_PID=$(cat .api.pid)
    print_info "Stopping Reality Engine API (PID: $API_PID)..."

    if ps -p $API_PID > /dev/null 2>&1; then
        kill $API_PID

        # Wait for graceful shutdown
        WAIT_COUNT=0
        while ps -p $API_PID > /dev/null 2>&1 && [ $WAIT_COUNT -lt 10 ]; do
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done

        # Force kill if still running
        if ps -p $API_PID > /dev/null 2>&1; then
            kill -9 $API_PID 2>/dev/null || true
        fi

        print_success "Reality Engine API stopped"
    else
        echo "Reality Engine API was not running"
    fi

    rm .api.pid
else
    echo "Reality Engine API is not running (no .api.pid file found)"
fi

echo ""

# Stop and remove Docker services
# NOTE: docker-compose down WITHOUT -v intentionally preserves named volumes:
#   perception_sources_data  — perception engine sources
#   grafana_data             — Grafana dashboards/config
# NOTE: Qdrant is NOT a service in this stack — it is the unified localAIStack instance.
#   Stopping the RE does NOT stop Qdrant.  Use localAIStack's stop.sh to stop Qdrant.
print_info "Stopping and removing Docker services (TLS proxy, Reality Engine, Visualizer, Perception Engine)..."
docker-compose down

if [ $? -eq 0 ]; then
    print_success "All Docker services stopped and removed"
else
    echo "Warning: Failed to stop some Docker services"
fi

# Clear Docker build cache (best-effort, 30s timeout each)
print_info "Clearing Docker build cache..."
timeout 30 docker builder prune -f > /dev/null 2>&1 || true
timeout 30 docker image prune -f > /dev/null 2>&1 || true
print_success "Docker cache cleared"

echo ""
echo "=================================================="
echo "All Services Stopped"
echo "=================================================="
echo ""
echo "Containers and build cache cleared. Persistent data preserved:"
echo "  - Perception sources: volume perception_sources_data"
echo "  - Grafana dashboards:  volume grafana_data"
echo "  - Qdrant vector store: managed by localAIStack (./volumes/qdrant)"
echo "    Run 'cd ../localAIStack && ./scripts/stop.sh' to also stop Qdrant."
echo ""
echo "To start again (restores perception sources): ./scripts/start.sh"
echo "To start fresh (clears perception sources):   ./scripts/start.sh --fresh"
echo ""
