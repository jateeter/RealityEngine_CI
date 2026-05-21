#!/bin/bash

# Reality Engine - Logs Viewer
# Shows logs from various services

SERVICE=${1:-all}
LINES=${2:-50}

echo "=================================================="
echo "Reality Engine - Logs Viewer"
echo "=================================================="
echo ""

case $SERVICE in
    api)
        echo "Showing Reality Engine API logs (last $LINES lines):"
        echo ""
        if [ -f logs/api.log ]; then
            tail -n $LINES logs/api.log
        else
            echo "No API logs found"
        fi
        ;;

    qdrant)
        echo "Showing Qdrant logs (last $LINES lines):"
        echo ""
        docker-compose logs --tail=$LINES qdrant
        ;;

    visualizer-backend|viz-backend)
        echo "Showing Visualizer Backend logs (last $LINES lines):"
        echo ""
        docker-compose logs --tail=$LINES visualizer-backend
        ;;

    visualizer-frontend|viz-frontend)
        echo "Showing Visualizer Frontend logs (last $LINES lines):"
        echo ""
        docker-compose logs --tail=$LINES visualizer-frontend
        ;;

    perception-backend|perception)
        echo "Showing Perception Engine Backend logs (last $LINES lines):"
        echo ""
        docker-compose logs --tail=$LINES perception-engine-backend
        ;;

    perception-frontend)
        echo "Showing Perception Engine Frontend logs (last $LINES lines):"
        echo ""
        docker-compose logs --tail=$LINES perception-engine-frontend
        ;;

    docker)
        echo "Showing all Docker service logs (last $LINES lines):"
        echo ""
        docker-compose logs --tail=$LINES
        ;;

    all)
        echo "=== Reality Engine API Logs ==="
        echo ""
        if [ -f logs/api.log ]; then
            tail -n 15 logs/api.log
        else
            echo "No API logs found"
        fi

        echo ""
        echo ""
        echo "=== Qdrant Logs ==="
        echo ""
        docker-compose logs --tail=15 qdrant

        echo ""
        echo ""
        echo "=== Visualizer Backend Logs ==="
        echo ""
        docker-compose logs --tail=15 visualizer-backend

        echo ""
        echo ""
        echo "=== Visualizer Frontend Logs ==="
        echo ""
        docker-compose logs --tail=15 visualizer-frontend

        echo ""
        echo ""
        echo "=== Perception Engine Backend Logs ==="
        echo ""
        docker-compose logs --tail=15 perception-engine-backend

        echo ""
        echo ""
        echo "=== Perception Engine Frontend Logs ==="
        echo ""
        docker-compose logs --tail=15 perception-engine-frontend
        ;;

    follow)
        echo "Following all logs (Ctrl+C to exit)..."
        echo ""
        if [ -f logs/api.log ]; then
            tail -f logs/api.log &
            API_TAIL_PID=$!
        fi
        docker-compose logs -f &
        DOCKER_TAIL_PID=$!

        trap "kill $API_TAIL_PID $DOCKER_TAIL_PID 2>/dev/null; exit 0" INT
        wait
        ;;

    *)
        echo "Usage: ./scripts/logs.sh [service] [lines]"
        echo ""
        echo "Services:"
        echo "  api                - Reality Engine API logs"
        echo "  qdrant             - Qdrant database logs"
        echo "  visualizer-backend  - Visualizer backend logs"
        echo "  visualizer-frontend - Visualizer frontend logs"
        echo "  perception-backend  - Perception Engine backend logs"
        echo "  perception-frontend - Perception Engine frontend logs"
        echo "  docker              - All Docker service logs"
        echo "  all                - All logs (default)"
        echo "  follow             - Follow logs in real-time"
        echo ""
        echo "Lines: Number of lines to show (default: 50)"
        echo ""
        echo "Examples:"
        echo "  ./scripts/logs.sh api 100"
        echo "  ./scripts/logs.sh visualizer-backend"
        echo "  ./scripts/logs.sh docker"
        echo "  ./scripts/logs.sh follow"
        ;;
esac

echo ""
