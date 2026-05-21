#!/bin/bash

# Reality Engine - Docker Status Check
# Shows detailed status of all Docker resources

echo "=================================================="
echo "Reality Engine - Docker Status"
echo "=================================================="
echo ""

echo "=== Containers ==="
docker ps -a --filter "name=reality-engine-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

echo "=== Networks ==="
docker network ls | grep reality || echo "No reality networks found"
echo ""

echo "=== Volumes ==="
docker volume ls | grep reality || echo "No reality volumes found"
echo ""

echo "=== Images ==="
docker images | grep -E "(realityengine|reality-engine|qdrant)" || echo "No reality-engine images found"
echo ""

echo "=== Quick Actions ==="
echo "Stop all:    ./scripts/stop.sh"
echo "Cleanup:     ./scripts/cleanup.sh"
echo "Start:       ./scripts/start.sh"
echo "Logs:        docker-compose logs -f"
echo ""
