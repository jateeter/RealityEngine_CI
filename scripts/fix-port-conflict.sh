#!/bin/bash

# Reality Engine - Port Conflict Fixer
# Diagnoses and fixes port conflicts for all Reality Engine services

echo "=================================================="
echo "Reality Engine - Port Conflict Diagnostic & Fix"
echo "=================================================="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

print_header() {
    echo -e "${BLUE}▶${NC} $1"
}

CONFLICTS_FOUND=0
CONFLICTS_FIXED=0

# Function to diagnose and fix a port
fix_port() {
    local port=$1
    local service=$2
    local safe_to_kill=${3:-true}

    print_header "Checking port $port ($service)"

    if ! lsof -i :$port > /dev/null 2>&1; then
        print_success "Port $port is available"
        echo ""
        return 0
    fi

    CONFLICTS_FOUND=$((CONFLICTS_FOUND + 1))
    print_error "Port $port is in use"

    # Show what's using it
    echo ""
    echo "Process details:"
    lsof -i :$port | head -2
    echo ""

    # Get process name
    PROCESS_NAME=$(lsof -i :$port | grep LISTEN | awk '{print $1}' | head -1)
    PID=$(lsof -ti:$port | head -1)

    echo "Process: $PROCESS_NAME (PID: $PID)"
    echo ""

    # Handle different process types
    case "$PROCESS_NAME" in
        node)
            if [ "$safe_to_kill" = "true" ]; then
                print_info "This is a Node.js process (likely Reality Engine)"
                read -p "Kill this process? (y/n) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    kill -9 $PID 2>/dev/null && print_success "Process killed" || print_error "Failed to kill process"
                    CONFLICTS_FIXED=$((CONFLICTS_FIXED + 1))
                fi
            else
                print_info "Node.js process found, but marked as unsafe to auto-kill"
            fi
            ;;

        com.docke*)
            print_info "This is Docker Desktop"
            echo ""
            echo "Docker is using port $port. To fix:"
            echo "  1. Open Docker Desktop"
            echo "  2. Go to Settings → Resources → Network"
            echo "  3. Change the port or restart Docker"
            echo "  4. Or temporarily: docker restart"
            echo ""
            ;;

        *)
            print_info "Unknown process: $PROCESS_NAME"
            read -p "Kill this process? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                kill -9 $PID 2>/dev/null && print_success "Process killed" || print_error "Failed to kill process"
                CONFLICTS_FIXED=$((CONFLICTS_FIXED + 1))
            fi
            ;;
    esac

    echo ""
}

# Check all Reality Engine ports
fix_port 3000 "Reality Engine Backend" true
fix_port 3001 "Visualizer Backend" true
fix_port 3004 "Perception Engine Backend" true
fix_port 3005 "Perception Engine Frontend" true
fix_port 5173 "Visualizer Frontend (Vite)" true
fix_port 6333 "Qdrant Vector DB" false

# Summary
echo "=================================================="
echo "Summary"
echo "=================================================="
echo ""
echo "Conflicts found: $CONFLICTS_FOUND"
echo "Conflicts fixed: $CONFLICTS_FIXED"
echo ""

if [ $CONFLICTS_FOUND -eq 0 ]; then
    print_success "All ports are available!"
    echo ""
    echo "Ready to start: ./scripts/start-local.sh"
elif [ $CONFLICTS_FIXED -gt 0 ]; then
    print_success "Fixed $CONFLICTS_FIXED conflict(s)"
    echo ""
    echo "Verify with: ./scripts/validate.sh"
    echo "Then start:  ./scripts/start-local.sh"
else
    print_info "Some conflicts remain"
    echo ""
    echo "Manual intervention may be required"
    echo "See suggestions above for each port"
fi
echo ""
