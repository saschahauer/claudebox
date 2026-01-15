# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**claudebox** is a containerized security sandbox for running Claude Code with `--dangerously-skip-permissions` safely. It uses Podman containers with sophisticated network isolation to prevent Claude from accessing unintended resources.

The container includes cross-compiler toolchains and build tools for embedded development, particularly for barebox bootloader development.

**Key security concept**: The sandbox provides three network isolation modes:
1. **Default (slirp4netns)**: Internet access with automatic local network isolation
2. **No-internet mode**: Complete network isolation
3. **Filtered mode (network namespace + iptables)**: TRUE network filtering at the IP level - only whitelisted hosts/ports accessible

## Common Commands

### Container Management
```bash
# Build the container image
./build-claude-container.sh

# Run Claude in the container (default: internet with local network isolation)
./claudebox

# Run with complete network isolation
./claudebox --no-internet

# Run with network filtering (requires setup first)
./claudebox --allow-hosts allowed-hosts.conf

# Start bash shell in container for testing
./claudebox --shell
```

### Network Namespace Management (for filtered mode)
```bash
# One-time setup: Create network namespace with iptables rules
sudo ./setup-claude-netns.sh allowed-hosts.conf

# Check status of network namespace
./status-claude-netns.sh

# Clean up network namespace
sudo ./cleanup-claude-netns.sh

# Install as systemd service (recommended for persistence)
sudo ./install-systemd-service.sh
sudo systemctl start claude-netns.service
sudo systemctl enable claude-netns.service  # Auto-start on boot
```

### Configuration
```bash
# Create allowed hosts configuration
cp allowed-hosts.conf.example allowed-hosts.conf
# Edit allowed-hosts.conf to add hosts/ports
```

## Architecture

### Container Build (Containerfile)
- **Base image**: debian:trixie-slim
- **Packages**: Includes build tools (gcc, python3, qemu, etc.) and cross-compiler toolchains for embedded development work, specifically prepared for barebox bootloader development
- **Claude installation**: Installed via official installer, then binary copied to /usr/local/bin/claude
- Why copy binary: /root is not accessible to non-root container users

### Run Script (claudebox)
**Mount strategy**:
- **Home directory**: `~/claude` on host → `~` in container (read-write)
  - This is where Claude's state, config, and data are stored
  - `.claude/` and `.claude.json` live inside this directory
- Current directory (`$(pwd)`): Mounted read-write at same absolute path (unless inside `~/claude`)
- `~/git/` directory: Mounted readonly (when exists, unless inside `~/claude`)
- **Special case**: When `$(pwd)` or `~/git/` are inside `~/claude`, they're already accessible via the home mount

**User mapping**:
- Uses `--userns=keep-id` to preserve host UID/GID
- Files created in container are owned by host user
- No root privileges needed

**Network modes**:
- Default: slirp4netns (user-mode networking, auto-isolates from local network)
- `--no-internet`: Complete isolation (`--network=none`)
- `--allow-hosts FILE`: Network namespace with iptables filtering (`--network=ns:/var/run/netns/claude-restricted`)

### Network Namespace Architecture (setup-claude-netns.sh)
**Purpose**: Provides TRUE network filtering at the IP level using iptables in a dedicated network namespace.

**Components**:
- **Network namespace**: `claude-restricted` - isolated network stack
- **Veth pair**: `veth-claude` (host) ↔ `veth-claude-ns` (namespace)
- **IP addresses**: Host 10.200.0.1, Namespace 10.200.0.2
- **NAT**: Host forwards packets from namespace to internet
- **iptables rules in namespace**:
  - Default policy: DROP all
  - ALLOW: Loopback, established connections, DNS (port 53)
  - ALLOW: Only whitelisted IPs/ports (resolved from allowed-hosts.conf)

**How allowed-hosts.conf works**:
- Format: `hostname:port` or `hostname:port1,port2` or just `hostname` (defaults to 80,443)
- Hostnames are resolved to IPs during setup using `dig`
- iptables rules allow only those specific IPs/ports
- Limitation: If IP addresses change, re-run setup

**Why this approach**:
- Previous DNS-based filtering was insufficient (Claude could resolve hostnames directly)
- Network namespace + iptables provides TRUE filtering for ALL protocols (HTTP, SSH, TCP, UDP, etc.)
- Filters at IP level, not just DNS level

### Supporting Scripts
- **cleanup-claude-netns.sh**: Removes network namespace, veth interfaces, and iptables rules
- **status-claude-netns.sh**: Shows namespace status, firewall rules, and connectivity tests
- **install-systemd-service.sh**: Installs systemd service for persistent network namespace
- **claude-netns.service**: Systemd unit that runs setup on start and cleanup on stop

## Important Implementation Details

### Path Handling in Scripts
All scripts use absolute paths because:
- Container mounts current directory at same absolute path
- Relative paths would break when run from different locations
- `realpath .` is used to get absolute path of current directory

### Podman vs Docker
This project uses Podman specifically because:
- Better rootless container support
- No daemon required
- Native user namespace mapping with `--userns=keep-id`

If porting to Docker, be aware of permission mapping differences.

### iptables Rule Ordering
In setup-claude-netns.sh, rule order matters:
1. Default policies (DROP)
2. Loopback (ACCEPT)
3. Established connections (ACCEPT)
4. DNS (ACCEPT port 53)
5. Whitelisted hosts/ports (ACCEPT specific IPs/ports)

This ensures DNS works for resolution but only whitelisted destinations are reachable.

### Security-Opt Label Disable
`--security-opt label=disable` is used in claudebox because:
- SELinux labels can cause permission issues with user namespace mapping
- This is safe within a container (SELinux still protects host)
- Required for proper file access in mounted directories

## Development Notes

### Testing Network Isolation
Use `--shell` mode to test without running Claude:
```bash
./claudebox --shell
# Inside container:
curl https://github.com      # Test internet
curl http://192.168.1.1      # Should fail (local network blocked)
ping 8.8.8.8                 # Test basic connectivity
```

For filtered mode:
```bash
# Test from namespace directly
sudo ip netns exec claude-restricted curl -v https://github.com
sudo ip netns exec claude-restricted iptables -L OUTPUT -n -v
```

### Modifying Allowed Hosts
After editing allowed-hosts.conf:
```bash
# Manual setup users
sudo ./cleanup-claude-netns.sh
sudo ./setup-claude-netns.sh allowed-hosts.conf

# Systemd users
sudo systemctl restart claude-netns.service
```

### Debugging Container Issues
```bash
# Check if image exists
podman images | grep claude-sandbox

# Inspect container mounts
podman run --rm claude-sandbox:latest mount | grep /home

# Check user mapping
podman unshare cat /proc/self/uid_map
```

## Limitations and Caveats

- **IPv6 not filtered**: Current iptables rules only filter IPv4; IPv6 is disabled in namespace
- **IP address changes**: Filtered mode requires re-running setup if host IPs change (DNS changes)
- **Readonly mounts don't prevent reading**: Files in `~/git/` can still be read by Claude
- **Container isolation, not VM**: This provides container-level isolation, not full virtualization
- **Same user context**: Container runs as host UID, not a separate security principal
