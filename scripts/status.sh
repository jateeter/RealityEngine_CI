#!/bin/bash

# Reality Engine - Status Check Script
# Shows status of all services

echo "=================================================="
echo "Reality Engine - Service Status"
echo "=================================================="
echo ""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load environment variables
if [ -f .env ]; then
    source .env
fi

PORT=${PORT:-3000}

# Check Qdrant
echo "Qdrant Vector Database:"
if docker-compose ps qdrant 2>/dev/null | grep -q "Up"; then
    echo -e "  Status: ${GREEN}RUNNING${NC}"

    if curl -s http://localhost:6333/health > /dev/null 2>&1; then
        echo -e "  Health: ${GREEN}HEALTHY${NC}"
        echo "  URL:    http://localhost:6333"
        echo "  UI:     http://localhost:6333/dashboard"
    else
        echo -e "  Health: ${RED}UNHEALTHY${NC}"
    fi
else
    echo -e "  Status: ${RED}STOPPED${NC}"
fi

echo ""

# Check Reality Engine API
echo "Reality Engine API:"
if [ -f .api.pid ]; then
    API_PID=$(cat .api.pid)

    if ps -p $API_PID > /dev/null 2>&1; then
        echo -e "  Status: ${GREEN}RUNNING${NC}"
        echo "  PID:    $API_PID"

        if curl -s http://localhost:$PORT/api/health > /dev/null 2>&1; then
            echo -e "  Health: ${GREEN}HEALTHY${NC}"
            echo "  URL:    http://localhost:$PORT"

            # Get engine stats
            STATS=$(curl -s http://localhost:$PORT/api/engine/stats)
            if [ $? -eq 0 ]; then
                echo ""
                echo "  Engine Statistics:"
                echo "$STATS" | grep -o '"totalSequences":[0-9]*' | sed 's/"totalSequences":/    Sequences: /'
                echo "$STATS" | grep -o '"totalVectors":[0-9]*' | sed 's/"totalVectors":/    Vectors:   /'
                echo "$STATS" | grep -o '"totalActiveVectors":[0-9]*' | sed 's/"totalActiveVectors":/    Active:    /'
            fi
        else
            echo -e "  Health: ${RED}UNHEALTHY${NC}"
        fi
    else
        echo -e "  Status: ${RED}STOPPED${NC} (stale PID file)"
        rm .api.pid
    fi
else
    echo -e "  Status: ${RED}STOPPED${NC}"
fi

echo ""

# Check Visualizer Backend
echo "Visualizer Backend:"
if docker-compose ps visualizer-backend 2>/dev/null | grep -q "Up"; then
    echo -e "  Status: ${GREEN}RUNNING${NC}"

    if curl -s http://localhost:3001/health > /dev/null 2>&1; then
        echo -e "  Health: ${GREEN}HEALTHY${NC}"
        echo "  URL:    http://localhost:3001"
    else
        echo -e "  Health: ${RED}UNHEALTHY${NC}"
    fi
else
    echo -e "  Status: ${RED}STOPPED${NC}"
fi

echo ""

# Check Visualizer Frontend
echo "Visualizer Frontend:"
if docker-compose ps visualizer-frontend 2>/dev/null | grep -q "Up"; then
    echo -e "  Status: ${GREEN}RUNNING${NC}"
    echo "  URL:    http://localhost:5173"
else
    echo -e "  Status: ${RED}STOPPED${NC}"
fi

echo ""

# Check Perception Engine Backend
echo "Perception Engine Backend:"
if docker-compose ps perception-engine-backend 2>/dev/null | grep -q "Up"; then
    echo -e "  Status: ${GREEN}RUNNING${NC}"

    if curl -s http://localhost:3004/api/health > /dev/null 2>&1; then
        echo -e "  Health: ${GREEN}HEALTHY${NC}"
        echo "  URL:    http://localhost:3004"
    else
        echo -e "  Health: ${RED}UNHEALTHY${NC}"
    fi
else
    echo -e "  Status: ${RED}STOPPED${NC}"
fi

echo ""

# Check Perception Engine Frontend
echo "Perception Engine Frontend:"
if docker-compose ps perception-engine-frontend 2>/dev/null | grep -q "Up"; then
    echo -e "  Status: ${GREEN}RUNNING${NC}"
    echo "  URL:    http://localhost:3005"
else
    echo -e "  Status: ${RED}STOPPED${NC}"
fi

echo ""

# Check Docker
echo "Docker:"
if docker info > /dev/null 2>&1; then
    echo -e "  Status: ${GREEN}RUNNING${NC}"
else
    echo -e "  Status: ${RED}NOT RUNNING${NC}"
fi

echo ""
echo "=================================================="

# Overall status
QDRANT_UP=$(docker-compose ps qdrant 2>/dev/null | grep -q "Up" && echo "1" || echo "0")
VISUALIZER_BACKEND_UP=$(docker-compose ps visualizer-backend 2>/dev/null | grep -q "Up" && echo "1" || echo "0")
VISUALIZER_FRONTEND_UP=$(docker-compose ps visualizer-frontend 2>/dev/null | grep -q "Up" && echo "1" || echo "0")
PERCEPTION_BACKEND_UP=$(docker-compose ps perception-engine-backend 2>/dev/null | grep -q "Up" && echo "1" || echo "0")
PERCEPTION_FRONTEND_UP=$(docker-compose ps perception-engine-frontend 2>/dev/null | grep -q "Up" && echo "1" || echo "0")
API_UP=$([ -f .api.pid ] && ps -p $(cat .api.pid) > /dev/null 2>&1 && echo "1" || echo "0")

if [ "$QDRANT_UP" = "1" ] && [ "$API_UP" = "1" ] && [ "$VISUALIZER_BACKEND_UP" = "1" ] && [ "$VISUALIZER_FRONTEND_UP" = "1" ] && [ "$PERCEPTION_BACKEND_UP" = "1" ] && [ "$PERCEPTION_FRONTEND_UP" = "1" ]; then
    echo -e "Overall: ${GREEN}ALL SERVICES RUNNING${NC}"
elif [ "$QDRANT_UP" = "1" ] && [ "$API_UP" = "1" ] && [ "$VISUALIZER_BACKEND_UP" = "1" ]; then
    echo -e "Overall: ${YELLOW}CORE SERVICES RUNNING, PERCEPTION ENGINE DOWN${NC}"
elif [ "$QDRANT_UP" = "1" ] && [ "$API_UP" = "1" ]; then
    echo -e "Overall: ${YELLOW}CORE SERVICES RUNNING, VISUALIZER/PERCEPTION DOWN${NC}"
else
    echo -e "Overall: ${RED}SOME SERVICES DOWN${NC}"
fi

echo "=================================================="
echo ""
