#!/bin/bash

# Reality Engine - Cleanup Script
# Removes all containers, volumes, and networks (use with caution)

echo "=================================================="
echo "Reality Engine - Cleanup Script"
echo "=================================================="
echo ""
echo "WARNING: This will remove all containers, volumes, and networks."
echo "All data in Qdrant will be lost!"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Stopping and removing all containers..."
docker-compose down -v

echo ""
echo "Removing dangling images..."
docker image prune -f

echo ""
echo "=================================================="
echo "Cleanup Complete"
echo "=================================================="
echo ""
echo "To start fresh: ./scripts/start.sh"
echo ""
