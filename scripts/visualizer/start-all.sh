#!/bin/bash

# Start All Services Script for Reality Engine Visualizer
# This script starts the Reality Engine, Visualizer Backend, and Frontend

set -e

echo "================================================"
echo "Starting Reality Engine Visualization Stack"
echo "================================================"
echo ""

# Check if Reality Engine is already running
if lsof -Pi :3000 -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "✓ Reality Engine already running on port 3000"
else
  echo "Starting Reality Engine on port 3000..."
  cd /Users/johnt/workspace/idahoApp/realityEngine
  npm run dev > /dev/null 2>&1 &
  REALITY_PID=$!
  echo "✓ Reality Engine started (PID: $REALITY_PID)"
  sleep 3
fi

# Check if Visualizer Backend is already running
if lsof -Pi :3001 -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "✓ Visualizer Backend already running on port 3001"
else
  echo "Starting Visualizer Backend on port 3001..."
  cd /Users/johnt/workspace/idahoApp/realityEngine/visualizer/backend
  npm run dev > /dev/null 2>&1 &
  BACKEND_PID=$!
  echo "✓ Visualizer Backend started (PID: $BACKEND_PID)"
  sleep 2
fi

# Check if Frontend is already running
if lsof -Pi :5173 -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "✓ Frontend already running on port 5173"
else
  echo "Starting Visualizer Frontend on port 5173..."
  cd /Users/johnt/workspace/idahoApp/realityEngine/visualizer/frontend
  npm run dev > /dev/null 2>&1 &
  FRONTEND_PID=$!
  echo "✓ Visualizer Frontend started (PID: $FRONTEND_PID)"
  sleep 2
fi

echo ""
echo "================================================"
echo "All services started successfully!"
echo "================================================"
echo ""
echo "Services:"
echo "  Reality Engine:        http://localhost:3000"
echo "  Visualizer Backend:    http://localhost:3001"
echo "  Visualizer Frontend:   http://localhost:5173"
echo ""
echo "Open http://localhost:5173 in your browser to view the visualizer"
echo ""
echo "To stop all services, run: ./visualizer/stop-all.sh"
echo "or use Ctrl+C to stop this script"
echo ""

# Wait for user interrupt
trap 'echo ""; echo "Shutting down..."; exit 0' INT TERM
wait
