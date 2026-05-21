#!/bin/bash

# Stop All Services Script for Reality Engine Visualizer

echo "Stopping Reality Engine Visualization Stack..."
echo ""

# Stop Reality Engine (port 3000)
if lsof -Pi :3000 -sTCP:LISTEN -t >/dev/null 2>&1; then
  PID=$(lsof -Pi :3000 -sTCP:LISTEN -t)
  kill $PID 2>/dev/null
  echo "✓ Stopped Reality Engine (PID: $PID)"
else
  echo "- Reality Engine not running"
fi

# Stop Visualizer Backend (port 3001)
if lsof -Pi :3001 -sTCP:LISTEN -t >/dev/null 2>&1; then
  PID=$(lsof -Pi :3001 -sTCP:LISTEN -t)
  kill $PID 2>/dev/null
  echo "✓ Stopped Visualizer Backend (PID: $PID)"
else
  echo "- Visualizer Backend not running"
fi

# Stop Frontend (port 5173)
if lsof -Pi :5173 -sTCP:LISTEN -t >/dev/null 2>&1; then
  PID=$(lsof -Pi :5173 -sTCP:LISTEN -t)
  kill $PID 2>/dev/null
  echo "✓ Stopped Visualizer Frontend (PID: $PID)"
else
  echo "- Visualizer Frontend not running"
fi

echo ""
echo "All services stopped."
