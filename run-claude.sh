#!/bin/bash
set -e

# Default values
NETWORK_MODE="default"
ALLOWED_HOSTS_FILE=""
CLAUDE_ARGS=()

# Usage function
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [CLAUDE_ARGUMENTS]

Run Claude Code in a sandboxed container with network isolation.

OPTIONS:
  --no-internet, -n           Disable all network access (--network=none)
  --allow-hosts FILE, -a FILE Load allowed hosts from configuration file
  --help, -h                  Show this help message

NETWORK MODES:
  Default (no flags):         Internet access with local network isolation (slirp4netns)
  --no-internet:              Complete network isolation
  --allow-hosts FILE:         TRUE network filtering via network namespace + iptables
                              Only hosts/ports listed in FILE will be accessible

SETUP (for --allow-hosts):
  1. Create allowed-hosts.conf with your hosts (see allowed-hosts.conf.example)
  2. Setup network namespace: sudo ./setup-claude-netns.sh allowed-hosts.conf
     OR use systemd: sudo systemctl start claude-netns.service
  3. Run: ./run-claude.sh --allow-hosts allowed-hosts.conf

EXAMPLES:
  ./run-claude.sh                                    # Default: internet, no local network
  ./run-claude.sh --no-internet                      # No network at all
  ./run-claude.sh --allow-hosts allowed-hosts.conf   # Filtered via iptables (requires setup)

  # Pass arguments to Claude:
  ./run-claude.sh "help me debug this code"
  ./run-claude.sh --no-internet "analyze this function"

SECURITY NOTES:
  - Container runs with --dangerously-skip-permissions (no permission prompts)
  - \$(pwd) is mounted read-write at the same path
  - ~/git/ is mounted readonly (if exists)
  - When \$(pwd) is inside ~/git/, it remains writable
  - Claude config (~/.claude) is persisted between runs
  - --allow-hosts mode uses iptables for TRUE network filtering at IP level

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-internet|-n)
            NETWORK_MODE="none"
            shift
            ;;
        --allow-hosts|-a)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: --allow-hosts requires a file argument"
                exit 1
            fi
            ALLOWED_HOSTS_FILE="$2"
            NETWORK_MODE="allowed-hosts"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            # All remaining arguments go to Claude
            CLAUDE_ARGS+=("$1")
            shift
            ;;
    esac
done

# Detect host environment
HOST_USER=$(whoami)
HOST_UID=$(id -u)
HOST_GID=$(id -g)
HOST_HOME=$HOME

# Calculate absolute paths
CURRENT_DIR=$(realpath .)
GIT_DIR=""
if [ -d "$HOME/git" ]; then
    GIT_DIR=$(realpath "$HOME/git")
fi

# Build mount arguments
MOUNTS="-v $CURRENT_DIR:$CURRENT_DIR:rw"

# Add git directory mount if it exists
if [ -n "$GIT_DIR" ]; then
    MOUNTS="$MOUNTS -v $GIT_DIR:$GIT_DIR:ro"
fi

# Mount Claude config and state directories
MOUNTS="$MOUNTS -v $HOST_HOME/.claude:$HOST_HOME/.claude"

# Mount Claude config file if it exists (read-write so Claude can update settings)
if [ -f "$HOST_HOME/.claude.json" ]; then
    MOUNTS="$MOUNTS -v $HOST_HOME/.claude.json:$HOST_HOME/.claude.json"
fi

# Build network arguments
NETWORK_ARGS=""
NETNS_NAME="claude-restricted"

case $NETWORK_MODE in
    none)
        NETWORK_ARGS="--network=none"
        echo "Network mode: No internet access"
        ;;
    allowed-hosts)
        if [ ! -f "$ALLOWED_HOSTS_FILE" ]; then
            echo "Error: Allowed hosts file not found: $ALLOWED_HOSTS_FILE"
            exit 1
        fi

        # Check if network namespace exists
        if ! sudo ip netns list | grep -q "^${NETNS_NAME}"; then
            echo "Error: Network namespace '$NETNS_NAME' not found"
            echo ""
            echo "Please setup the network namespace first:"
            echo "  sudo ./setup-claude-netns.sh $ALLOWED_HOSTS_FILE"
            echo ""
            echo "Or use systemd service:"
            echo "  sudo systemctl start claude-netns.service"
            exit 1
        fi

        # Use the restricted network namespace
        NETWORK_ARGS="--network=ns:/var/run/netns/$NETNS_NAME"
        echo "Network mode: Restricted network namespace with iptables filtering"
        echo "Allowed hosts: $ALLOWED_HOSTS_FILE"
        echo "Namespace: $NETNS_NAME"
        ;;
    default)
        # Use default slirp4netns (implicit for rootless podman)
        echo "Network mode: Internet access with local network isolation"
        ;;
esac

# Check if container image exists
if ! podman image exists claude-sandbox:latest; then
    echo "Error: Container image 'claude-sandbox:latest' not found"
    echo "Please build it first with: ./build-claude-container.sh"
    exit 1
fi

# Run the container
echo "Starting Claude in container..."
echo "Working directory: $CURRENT_DIR"
if [ -n "$GIT_DIR" ]; then
    echo "Git directory: $GIT_DIR (readonly)"
fi
echo ""

exec podman run \
    --rm \
    --interactive \
    --tty \
    --userns=keep-id \
    --user $HOST_UID:$HOST_GID \
    --security-opt label=disable \
    -e HOME=$HOST_HOME \
    -w "$CURRENT_DIR" \
    $MOUNTS \
    $NETWORK_ARGS \
    claude-sandbox:latest \
    /usr/local/bin/claude --dangerously-skip-permissions "${CLAUDE_ARGS[@]}"
