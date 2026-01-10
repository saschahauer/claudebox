#!/bin/bash
# Install systemd service for Claude network namespace

set -e

SERVICE_FILE="claude-netns.service"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if service file exists
if [ ! -f "$SCRIPT_DIR/$SERVICE_FILE" ]; then
    log_error "Service file not found: $SCRIPT_DIR/$SERVICE_FILE"
    exit 1
fi

log_info "Installing systemd service..."

# Update paths in service file to use absolute paths
TEMP_SERVICE=$(mktemp)
sed "s|/home/sascha/claude|$SCRIPT_DIR|g" "$SCRIPT_DIR/$SERVICE_FILE" > "$TEMP_SERVICE"

# Copy service file
log_info "Copying service file to $SYSTEMD_DIR/"
cp "$TEMP_SERVICE" "$SYSTEMD_DIR/$SERVICE_FILE"
rm "$TEMP_SERVICE"

# Set proper permissions
chmod 644 "$SYSTEMD_DIR/$SERVICE_FILE"

# Reload systemd
log_info "Reloading systemd daemon..."
systemctl daemon-reload

log_info "Service installed successfully!"
echo ""
echo "Usage:"
echo "  Start:   sudo systemctl start claude-netns.service"
echo "  Stop:    sudo systemctl stop claude-netns.service"
echo "  Status:  sudo systemctl status claude-netns.service"
echo "  Enable:  sudo systemctl enable claude-netns.service  (start on boot)"
echo "  Disable: sudo systemctl disable claude-netns.service"
echo ""
echo "Before starting, edit $SCRIPT_DIR/allowed-hosts.conf with your allowed hosts"
echo ""
