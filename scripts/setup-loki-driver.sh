#!/bin/bash

# Setup Loki Docker Driver
# This script installs and configures the Loki Docker logging plugin

set -e

echo "========================================="
echo "Loki Docker Driver Setup"
echo "========================================="
echo ""

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Error: Docker is not running"
    echo "Please start Docker and try again"
    exit 1
fi

echo "✓ Docker is running"
echo ""

# Check if Loki plugin is already installed (by alias or full name)
if docker plugin ls | grep -q "loki"; then
    echo "✓ Loki Docker driver plugin is already installed"

    # Check if it's enabled
    if docker plugin ls | grep "loki" | grep -q "true"; then
        echo "✓ Loki Docker driver plugin is enabled"
    else
        echo "⚠ Loki Docker driver plugin is disabled, enabling..."
        docker plugin enable loki
        echo "✓ Loki Docker driver plugin enabled"
    fi
else
    echo "📦 Installing Loki Docker driver plugin..."

    # Install the plugin
    docker plugin install grafana/loki-docker-driver:latest \
        --alias loki \
        --grant-all-permissions

    if [ $? -eq 0 ]; then
        echo "✓ Loki Docker driver plugin installed successfully"
    else
        echo "❌ Failed to install Loki Docker driver plugin"
        exit 1
    fi
fi

echo ""
echo "========================================="
echo "Verifying Installation"
echo "========================================="
echo ""

# Verify the plugin is enabled
if docker plugin ls | grep "loki" | grep -q "true"; then
    echo "✓ Loki plugin verification passed"
    echo ""
    echo "Plugin Details:"
    docker plugin ls | grep "loki"
else
    echo "❌ Loki plugin verification failed"
    exit 1
fi

echo ""
echo "========================================="
echo "Setup Complete!"
echo "========================================="
echo ""
echo "The Loki Docker driver is now installed and ready to use."
echo ""
echo "Next steps:"
echo "1. Start the services: docker-compose up -d"
echo "2. Access Grafana: http://localhost:3002"
echo "3. View logs in the 'Reality Engine Overview' dashboard"
echo ""
echo "Note: You may need to restart Docker daemon if you configured"
echo "      /etc/docker/daemon.json for system-wide Loki logging."
echo ""
