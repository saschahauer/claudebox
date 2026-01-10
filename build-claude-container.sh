#!/bin/bash
set -e

echo "Building Claude sandbox container..."
podman build -t claude-sandbox:latest -f Containerfile .

echo ""
echo "Container built successfully: claude-sandbox:latest"
echo "Run with: ./run-claude.sh [options] [claude-arguments]"
echo ""
echo "Options:"
echo "  --no-internet, -n           Disable all network access"
echo "  --allow-hosts FILE, -a FILE Use allowed hosts configuration"
echo "  --help, -h                  Show usage information"
