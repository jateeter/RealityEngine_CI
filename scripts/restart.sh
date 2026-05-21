#!/bin/bash

# Reality Engine - Restart Script
# Restarts all services

echo "=================================================="
echo "Reality Engine - Restarting Services"
echo "=================================================="
echo ""

# Stop services
./scripts/stop.sh

echo ""
echo "Waiting 3 seconds before restart..."
sleep 3
echo ""

# Start services
./scripts/start.sh
