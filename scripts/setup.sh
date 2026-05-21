#!/bin/bash

# Reality Engine - Initial Setup Script
# This script prepares the environment for deployment

set -e

echo "=================================================="
echo "Reality Engine - Initial Setup"
echo "=================================================="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Check prerequisites
echo "Checking prerequisites..."
echo ""

# Check Node.js
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    NODE_MAJOR=$(echo $NODE_VERSION | cut -d'.' -f1 | sed 's/v//')
    print_success "Node.js installed: $NODE_VERSION"

    if [ "$NODE_MAJOR" -lt 25 ]; then
        print_error "Node.js version 25.4+ required (found: $NODE_VERSION)"
        echo "  Please install Node.js 25.4+ from https://nodejs.org/"
        exit 1
    fi
else
    print_error "Node.js is not installed"
    echo "  Please install Node.js 22+ from https://nodejs.org/"
    exit 1
fi

# Check npm
if command -v npm &> /dev/null; then
    NPM_VERSION=$(npm --version)
    print_success "npm installed: $NPM_VERSION"
else
    print_error "npm is not installed"
    exit 1
fi

# Check Docker
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version)
    print_success "Docker installed: $DOCKER_VERSION"
else
    print_error "Docker is not installed"
    echo "  Please install Docker from https://docs.docker.com/get-docker/"
    exit 1
fi

# Check Docker Compose
if command -v docker-compose &> /dev/null; then
    COMPOSE_VERSION=$(docker-compose --version)
    print_success "Docker Compose installed: $COMPOSE_VERSION"
else
    print_error "Docker Compose is not installed"
    echo "  Please install Docker Compose from https://docs.docker.com/compose/install/"
    exit 1
fi

# Check if Docker daemon is running
if docker info &> /dev/null; then
    print_success "Docker daemon is running"
else
    print_error "Docker daemon is not running"
    echo "  Please start Docker and try again"
    exit 1
fi

echo ""
echo "All prerequisites satisfied!"
echo ""

# Create .env file if it doesn't exist
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        print_info "Creating .env file from template..."
        cp .env.example .env
        print_success ".env file created"
        echo "  You can customize settings in .env file"
    else
        print_info "No .env.example found, creating minimal .env file..."
        cat > .env << EOF
# Reality Engine Configuration
NODE_ENV=production
PORT=3000
QDRANT_URL=http://qdrant:6333
VECTOR_DIMENSION=128
EOF
        print_success ".env file created with defaults"
        echo "  You can customize settings in .env file"
    fi
else
    print_success ".env file already exists"
fi

# Install dependencies
echo ""
print_info "Installing npm dependencies..."
npm install

if [ $? -eq 0 ]; then
    print_success "Dependencies installed successfully"
else
    print_error "Failed to install dependencies"
    exit 1
fi

# Build TypeScript
echo ""
print_info "Building TypeScript code..."
npm run build

if [ $? -eq 0 ]; then
    print_success "Build completed successfully"
else
    print_error "Build failed"
    exit 1
fi

# Create necessary directories
echo ""
print_info "Creating directories..."
mkdir -p logs
mkdir -p data
print_success "Directories created"

# Set permissions
echo ""
print_info "Setting permissions..."
chmod +x scripts/*.sh
print_success "Permissions set"

echo ""
echo "=================================================="
echo "Setup Complete!"
echo "=================================================="
echo ""
echo "Next steps:"
echo "  1. Review and customize .env file if needed"
echo "  2. Start the system: ./scripts/start.sh"
echo "  3. Check status: ./scripts/status.sh"
echo "  4. View logs: ./scripts/logs.sh"
echo ""
echo "For more information, see DEPLOYMENT.md"
echo ""
