#!/bin/bash
# Cleanup script for Claude network namespace
# Requires root/sudo privileges

set -e

NETNS_NAME="claude-restricted"
VETH_HOST="veth-claude"
SUBNET="10.200.0.0/24"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

log_info "Cleaning up network namespace: $NETNS_NAME"

# Remove network namespace
if ip netns list | grep -q "^${NETNS_NAME}"; then
    log_info "Removing namespace $NETNS_NAME..."
    ip netns del $NETNS_NAME
else
    log_warn "Namespace $NETNS_NAME not found"
fi

# Remove veth interface (should be auto-removed with namespace, but just in case)
if ip link show $VETH_HOST &> /dev/null; then
    log_info "Removing veth interface $VETH_HOST..."
    ip link del $VETH_HOST || true
fi

# Clean up iptables rules
log_info "Cleaning up iptables rules..."

# Get default interface
DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -n1 || true)

if [ -n "$DEFAULT_IF" ]; then
    # Remove NAT rule
    iptables -t nat -D POSTROUTING -s $SUBNET -o $DEFAULT_IF -j MASQUERADE 2>/dev/null || true

    # Remove forward rules
    iptables -D FORWARD -i $VETH_HOST -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o $VETH_HOST -j ACCEPT 2>/dev/null || true
fi

log_info "Cleanup complete!"
