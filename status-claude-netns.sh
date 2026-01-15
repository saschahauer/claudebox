#!/bin/bash
# Status script for Claude network namespace
# Can run as regular user or root

NETNS_NAME="claude-restricted"
VETH_HOST="veth-claude"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_section() {
    echo -e "\n${BLUE}===${NC} $1 ${BLUE}===${NC}"
}

echo "Claude Network Namespace Status"
echo "================================"

# Check if namespace exists
log_section "Network Namespace"
if sudo ip netns list | grep -q "^${NETNS_NAME}"; then
    log_info "Namespace '$NETNS_NAME' exists"

    # Get namespace details
    echo "  Interfaces in namespace:"
    sudo ip netns exec $NETNS_NAME ip addr show | grep -E '^[0-9]+:' | sed 's/^/    /'

    echo "  Routes in namespace:"
    sudo ip netns exec $NETNS_NAME ip route | sed 's/^/    /'
else
    log_error "Namespace '$NETNS_NAME' not found"
    echo "  Run: sudo ./setup-claude-netns.sh allowed-hosts.conf"
    echo "  Or:  sudo systemctl start claude-netns.service"
fi

# Check veth interface on host
log_section "Host Network Interface"
if ip link show $VETH_HOST &> /dev/null; then
    log_info "Veth interface '$VETH_HOST' exists"
    ip addr show $VETH_HOST | grep inet | sed 's/^/    /'
else
    log_warn "Veth interface '$VETH_HOST' not found"
fi

# Check iptables rules in namespace
log_section "Firewall Rules (OUTPUT chain)"
if sudo ip netns list | grep -q "^${NETNS_NAME}"; then
    echo "  Filtering rules for outgoing connections:"
    sudo ip netns exec $NETNS_NAME iptables -L OUTPUT -n -v --line-numbers | sed 's/^/    /'
else
    log_warn "Cannot check rules - namespace not found"
fi

# Check systemd service status
log_section "Systemd Service"
if systemctl list-unit-files | grep -q claude-netns.service; then
    if systemctl is-active --quiet claude-netns.service; then
        log_info "Service 'claude-netns.service' is active"
    else
        log_warn "Service 'claude-netns.service' is inactive"
        echo "  Run: sudo systemctl start claude-netns.service"
    fi

    if systemctl is-enabled --quiet claude-netns.service; then
        echo "  Service is enabled (starts on boot)"
    else
        echo "  Service is disabled (does not start on boot)"
        echo "  Enable: sudo systemctl enable claude-netns.service"
    fi
else
    log_warn "Service file not installed"
    echo "  Install: sudo cp claude-netns.service /etc/systemd/system/"
    echo "           sudo systemctl daemon-reload"
fi

# Check if container image exists
log_section "Container Image"
if podman image exists claude-sandbox:latest; then
    log_info "Container image 'claude-sandbox:latest' exists"
    IMAGE_INFO=$(podman images claude-sandbox:latest --format "{{.Size}} ({{.Created}})")
    echo "  Size: $IMAGE_INFO"
else
    log_warn "Container image 'claude-sandbox:latest' not found"
    echo "  Build: ./build-claude-container.sh"
fi

# Test connectivity from namespace
if sudo ip netns list | grep -q "^${NETNS_NAME}"; then
    log_section "Connectivity Test"
    echo "  Testing DNS resolution..."
    if sudo ip netns exec $NETNS_NAME host github.com &> /dev/null; then
        log_info "DNS resolution works"
    else
        log_warn "DNS resolution failed (might be blocked or unavailable)"
    fi

    echo ""
    echo "  Note: Actual connectivity depends on iptables rules"
    echo "  Test specific host: sudo ip netns exec $NETNS_NAME curl -v https://example.com"
fi

log_section "Summary"
if sudo ip netns list | grep -q "^${NETNS_NAME}"; then
    echo "  Status: ${GREEN}Ready to use${NC}"
    echo "  Run: ./claudebox --allow-hosts allowed-hosts.conf"
else
    echo "  Status: ${RED}Not configured${NC}"
    echo "  Setup required before using --allow-hosts mode"
fi

echo ""
