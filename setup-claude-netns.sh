#!/bin/bash
# Setup script for Claude network namespace with iptables filtering
# Requires root/sudo privileges

set -e

NETNS_NAME="claude-restricted"
VETH_HOST="veth-claude"
VETH_NS="veth-claude-ns"
HOST_IP="10.200.0.1"
NS_IP="10.200.0.2"
SUBNET="10.200.0.0/24"
ALLOWED_HOSTS_FILE="${1:-}"

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

# Check required commands
for cmd in ip iptables dig; do
    if ! command -v $cmd &> /dev/null; then
        log_error "Required command '$cmd' not found. Please install it."
        exit 1
    fi
done

log_info "Setting up network namespace: $NETNS_NAME"

# Clean up existing namespace if it exists
if ip netns list | grep -q "^${NETNS_NAME}"; then
    log_warn "Namespace $NETNS_NAME already exists, cleaning up..."
    ip netns del $NETNS_NAME || true
fi

# Remove existing veth if it exists
if ip link show $VETH_HOST &> /dev/null; then
    log_warn "Removing existing veth interface $VETH_HOST"
    ip link del $VETH_HOST || true
fi

# Create network namespace
log_info "Creating network namespace..."
ip netns add $NETNS_NAME

# Create veth pair
log_info "Creating veth pair..."
ip link add $VETH_HOST type veth peer name $VETH_NS

# Move one end to namespace
ip link set $VETH_NS netns $NETNS_NAME

# Configure host side
log_info "Configuring host side interface..."
ip addr add ${HOST_IP}/24 dev $VETH_HOST
ip link set $VETH_HOST up

# Configure namespace side
log_info "Configuring namespace interface..."
ip netns exec $NETNS_NAME ip addr add ${NS_IP}/24 dev $VETH_NS
ip netns exec $NETNS_NAME ip link set $VETH_NS up
ip netns exec $NETNS_NAME ip link set lo up

# Add default route in namespace
ip netns exec $NETNS_NAME ip route add default via $HOST_IP

# Enable IP forwarding on host
log_info "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# Setup NAT on host
log_info "Setting up NAT..."
# Get default interface
DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$DEFAULT_IF" ]; then
    log_error "Could not determine default network interface"
    exit 1
fi
log_info "Default interface: $DEFAULT_IF"

# Add NAT rule (MASQUERADE for the namespace subnet)
iptables -t nat -C POSTROUTING -s $SUBNET -o $DEFAULT_IF -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s $SUBNET -o $DEFAULT_IF -j MASQUERADE

# Allow forwarding from namespace
iptables -C FORWARD -i $VETH_HOST -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i $VETH_HOST -j ACCEPT
iptables -C FORWARD -o $VETH_HOST -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -o $VETH_HOST -j ACCEPT

# Setup iptables in namespace
log_info "Configuring iptables in namespace..."

# Default policies: DROP everything
ip netns exec $NETNS_NAME iptables -P INPUT DROP
ip netns exec $NETNS_NAME iptables -P OUTPUT DROP
ip netns exec $NETNS_NAME iptables -P FORWARD DROP

# Allow loopback
ip netns exec $NETNS_NAME iptables -A INPUT -i lo -j ACCEPT
ip netns exec $NETNS_NAME iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
ip netns exec $NETNS_NAME iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
ip netns exec $NETNS_NAME iptables -A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# Allow DNS (required for hostname resolution)
log_info "Allowing DNS queries (UDP/TCP port 53)..."
ip netns exec $NETNS_NAME iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
ip netns exec $NETNS_NAME iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Process allowed hosts file if provided
if [ -n "$ALLOWED_HOSTS_FILE" ] && [ -f "$ALLOWED_HOSTS_FILE" ]; then
    log_info "Processing allowed hosts from: $ALLOWED_HOSTS_FILE"

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse host:port or just host
        if [[ "$line" =~ ^([^:]+):(.+)$ ]]; then
            HOST="${BASH_REMATCH[1]}"
            PORTS="${BASH_REMATCH[2]}"
        else
            HOST="$line"
            PORTS="80,443"  # Default ports for bare hostname
        fi

        log_info "Processing: $HOST (ports: $PORTS)"

        # Check if it's already an IP
        if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            IPS="$HOST"
        else
            # Resolve hostname to IPs (both A and AAAA records)
            IPS=$(dig +short "$HOST" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

            if [ -z "$IPS" ]; then
                log_warn "Could not resolve $HOST, skipping..."
                continue
            fi
        fi

        # Add iptables rule for each IP and port combination
        for IP in $IPS; do
            # Split ports by comma
            IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
            for PORT in "${PORT_ARRAY[@]}"; do
                PORT=$(echo "$PORT" | xargs)  # Trim whitespace
                log_info "  Allowing $HOST ($IP:$PORT)"

                # Detect protocol (usually TCP for most services, but allow both)
                ip netns exec $NETNS_NAME iptables -A OUTPUT -d "$IP" -p tcp --dport "$PORT" -j ACCEPT

                # For some ports, also allow UDP (like DNS-over-HTTPS uses 443/udp sometimes)
                if [ "$PORT" = "443" ] || [ "$PORT" = "53" ]; then
                    ip netns exec $NETNS_NAME iptables -A OUTPUT -d "$IP" -p udp --dport "$PORT" -j ACCEPT
                fi
            done
        done

    done < "$ALLOWED_HOSTS_FILE"
else
    log_warn "No allowed hosts file provided or file not found"
    log_warn "Only DNS will be allowed. Provide a file as first argument to allow specific hosts."
fi

# Log final rules for verification
log_info "Final iptables rules in namespace:"
ip netns exec $NETNS_NAME iptables -L OUTPUT -n -v --line-numbers | head -n 20

log_info ""
log_info "Network namespace setup complete!"
log_info ""
log_info "Namespace: $NETNS_NAME"
log_info "Namespace IP: $NS_IP"
log_info "Gateway IP: $HOST_IP"
log_info ""
log_info "Test the namespace:"
log_info "  sudo ip netns exec $NETNS_NAME ping -c 1 8.8.8.8  (should fail if no rules)"
log_info "  sudo ip netns exec $NETNS_NAME curl https://api.anthropic.com  (should work if allowed)"
log_info ""
log_info "Run Claude in namespace:"
log_info "  ./claudebox --allow-hosts allowed-hosts.conf"
