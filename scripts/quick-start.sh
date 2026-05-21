#!/bin/bash

# Reality Engine Quick Start Script

set -e

echo "======================================"
echo "Reality Engine - Quick Start"
echo "======================================"
echo ""

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Error: Docker is not running. Please start Docker and try again."
    exit 1
fi

echo "✓ Docker is running"

# Check if .env exists
if [ ! -f .env ]; then
    echo "📝 Creating .env file from .env.example..."
    cp .env.example .env
    echo "✓ .env file created"
else
    echo "✓ .env file exists"
fi

# Install dependencies
echo ""
echo "📦 Installing dependencies..."
npm install

# Start Docker services
echo ""
echo "🐳 Starting Docker services..."
docker-compose up -d

# Wait for Qdrant to be ready
echo ""
echo "⏳ Waiting for Qdrant to be ready..."
sleep 5

MAX_RETRIES=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s http://localhost:6333/health > /dev/null; then
        echo "✓ Qdrant is ready"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "   Waiting... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Error: Qdrant failed to start"
    exit 1
fi

# Build the application
echo ""
echo "🔨 Building application..."
npm run build

# Start the application
echo ""
echo "🚀 Starting Reality Engine..."
npm start &
APP_PID=$!

# Wait for app to be ready
echo ""
echo "⏳ Waiting for Reality Engine to be ready..."
sleep 5

MAX_RETRIES=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s http://localhost:3000/api/health > /dev/null; then
        echo "✓ Reality Engine is ready"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "   Waiting... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Error: Reality Engine failed to start"
    kill $APP_PID 2>/dev/null || true
    exit 1
fi

# Success message
echo ""
echo "======================================"
echo "✓ Reality Engine is running!"
echo "======================================"
echo ""
echo "📍 Services:"
echo "   - Reality Engine API:         http://localhost:3000"
echo "   - Qdrant Dashboard:           http://localhost:6333/dashboard"
echo "   - Visualizer Backend:         http://localhost:3001"
echo "   - Visualizer Frontend:        http://localhost:5173"
echo "   - Perception Engine Backend:  http://localhost:3004"
echo "   - Perception Engine Frontend: http://localhost:3005"
echo ""
echo "🎯 Quick Start:"
echo "   1. Open Visualizer:           http://localhost:5173"
echo "   2. Load a machine from the list and explore perceptual sequences"
echo "   3. Open Perception Engine UI: http://localhost:3005"
echo "   4. Add sources and push reality vectors"
echo ""
echo "🔍 API Endpoints:"
echo "   - Health:       GET  http://localhost:3000/api/health"
echo "   - Perceive:     POST http://localhost:3000/api/perceive"
echo "   - Process:      POST http://localhost:3000/api/engine/process"
echo ""
echo "📖 Documentation: See README.md and DEMO_STATUS.md"
echo ""
echo "To stop the services:"
echo "   ./scripts/stop.sh"
echo ""
