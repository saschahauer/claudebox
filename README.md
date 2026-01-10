# Claude Code Sandbox Container

A containerized environment for running Claude Code with `--dangerously-skip-permissions` safely using Podman.

## Features

- **Isolated environment**: Run Claude Code in a Debian Trixie container
- **Network isolation modes**:
  - Internet access with local network isolation (default)
  - Complete network isolation (--no-internet)
  - **TRUE network filtering** via network namespace + iptables (--allow-hosts)
- **Smart mounting**:
  - Current directory mounted read-write at the same path
  - ~/git/ mounted readonly (when it exists)
  - Special handling: $(pwd) stays writable even when inside ~/git/
- **Permission safety**: Runs with `--dangerously-skip-permissions` inside container
- **State persistence**: Claude configuration and state preserved between runs

## Prerequisites

- Podman installed (tested with 5.4.2)
- Debian-based system (or similar)
- User namespace mappings configured for rootless containers
- For `--allow-hosts` mode: iptables, iproute2, dnsutils (usually pre-installed)

### Installing Dependencies

On Debian/Ubuntu:
```bash
sudo apt-get update
sudo apt-get install -y podman iptables iproute2 dnsutils
```

Verify installation:
```bash
podman --version
iptables --version
ip netns list  # Should work without errors
```

## Quick Start

1. **Build the container**:
   ```bash
   ./build-claude-container.sh
   ```

2. **Run Claude in the container**:
   ```bash
   ./run-claude.sh
   ```

3. **Chat with Claude** - you're now running in an isolated environment!

## Usage

### Basic Usage

```bash
# Run with default settings (internet access, no local network)
./run-claude.sh

# Pass arguments to Claude
./run-claude.sh "help me debug this code"
```

### Network Modes

#### Default: Internet with Local Network Isolation
```bash
./run-claude.sh
```
- Full internet access via user-mode networking (slirp4netns)
- No access to local network (192.168.x.x, 10.x.x.x, etc.)
- Good for general development work
- No setup required

#### No Internet
```bash
./run-claude.sh --no-internet
```
- Complete network isolation
- Use when working with sensitive code
- Claude can only access mounted files
- No setup required

#### Filtered Network Access (TRUE filtering via iptables)
This mode uses a **network namespace with iptables rules** to provide TRUE network filtering at the IP level.

**Setup (one-time)**:
```bash
# 1. Create allowed-hosts configuration
cp allowed-hosts.conf.example allowed-hosts.conf
# Edit to add your hosts and ports (e.g., github.com:443)

# 2. Option A: Manual setup
sudo ./setup-claude-netns.sh allowed-hosts.conf

# 2. Option B: Systemd service (recommended for persistence)
sudo ./install-systemd-service.sh
sudo systemctl start claude-netns.service
sudo systemctl enable claude-netns.service  # Optional: start on boot
```

**Usage**:
```bash
./run-claude.sh --allow-hosts allowed-hosts.conf
```

**How it works**:
- Creates a network namespace with restrictive iptables rules
- Resolves hostnames to IPs and whitelists only those IPs/ports
- Filters ALL protocols (HTTP, SSH, raw TCP, etc.)
- DNS (port 53) is allowed by default for name resolution
- Container runs in this isolated network namespace

**Configuration format** (`allowed-hosts.conf`):
```
# Format: hostname:port
github.com:443
github.com:22
api.anthropic.com:443

# Or just hostname (defaults to ports 80,443)
example.com
```

**Check status**:
```bash
./status-claude-netns.sh
```

**Stop/cleanup**:
```bash
# Manual
sudo ./cleanup-claude-netns.sh

# Systemd
sudo systemctl stop claude-netns.service
```

### Command-Line Options

```
--no-internet, -n           Disable all network access
--allow-hosts FILE, -a FILE Load allowed hosts from configuration file
--shell, -s                 Start bash shell instead of Claude (for testing)
--help, -h                  Show usage information
```

All other arguments are passed directly to Claude.

### Testing and Debugging

To test the container environment without running Claude:

```bash
./run-claude.sh --shell

# Inside the container shell, you can:
# - Test network connectivity: curl https://github.com
# - Check mounts: ls -la ~/git/
# - Verify environment: echo $HOME, whoami
# - Test file permissions: touch test.txt
```

## How It Works

### Container Setup

The container is based on Debian Trixie (slim) and includes:
- Claude Code CLI installed at `/usr/local/bin/claude`
- Minimal dependencies (curl, ca-certificates)
- No unnecessary packages

### Mount Strategy

The container uses a sophisticated mount strategy:

1. **Current directory** (`$(pwd)`): Mounted read-write at the same absolute path
   - Preserves script compatibility (absolute paths work)
   - Changes are immediately visible on host

2. **Git directory** (`~/git/`): Mounted readonly at the same path
   - Prevents accidental modifications to repositories
   - Read-only access to all your git projects

3. **Special case**: When `$(pwd)` is inside `~/git/`:
   - `~/git/` is mounted readonly
   - `$(pwd)` is mounted read-write on top
   - Result: Current project is writable, others are readonly

4. **Claude config**: `~/.claude/` mounted read-write
   - State persists between container runs
   - Settings and history preserved

### User Mapping

Uses `--userns=keep-id` to preserve your UID/GID:
- Files created in container owned by you on host
- Permissions match as if running directly on host
- No root privileges needed

### Network Isolation

Three modes available:

1. **slirp4netns** (default): User-mode networking that automatically isolates from local network
   - Good for general use
   - No setup required

2. **--network=none**: Complete isolation at the network stack level
   - No network access at all
   - No setup required

3. **Network namespace + iptables** (--allow-hosts): True network filtering
   - Creates isolated network namespace with custom iptables rules
   - Filters at IP level (works for all protocols: HTTP, SSH, TCP, UDP)
   - Requires sudo for setup
   - Hostnames resolved to IPs during setup
   - Only whitelisted IPs/ports are accessible

## Security Considerations

### What This Protects Against

✅ Accidental file modifications outside current directory
✅ Access to local network services (192.168.x.x, etc.) in all modes
✅ Permission prompts (runs with --dangerously-skip-permissions safely)
✅ System-wide changes (containerized environment)
✅ **Network access to non-whitelisted hosts** (in --allow-hosts mode with iptables)

### Network Security Levels

**Default mode** (slirp4netns):
- Isolates from local network
- Full internet access
- Good for general development

**No-internet mode**:
- Complete isolation
- Maximum security
- No network dependencies

**Filtered mode** (--allow-hosts with network namespace):
- **TRUE IP-level filtering** via iptables
- Only whitelisted IPs/ports accessible
- DNS resolution works (port 53 always allowed)
- Filters ALL protocols (HTTP, HTTPS, SSH, etc.)
- Requires root for setup (network namespace creation)

### Limitations

❌ **Readonly mounts don't prevent reading**: Files in `~/git/` are readonly but can still be read. Don't mount sensitive data you don't want Claude to see.

❌ **Not a VM**: This is container isolation, not full virtualization. For maximum security, use a VM.

❌ **Same user context**: Container runs as your UID, not a separate security principal.

❌ **DNS resolution in filtered mode**: Hostnames are resolved to IPs during setup. If IPs change, you need to re-run setup.

❌ **IPv6 filtering not implemented**: Current iptables rules only filter IPv4. IPv6 is disabled in the namespace.

### Best Practices

- **Maximum isolation**: Use `--no-internet` mode
- **Selective access**: Use `--allow-hosts` mode with minimal host list
- **Default mode**: OK for general work with non-sensitive code
- **Review mounts**: Check what directories are mounted before running
- **Update regularly**: Rebuild container periodically to get security updates
- **Update network rules**: Re-run setup if allowed hosts change
- **Limit exposure**: Only mount what you need

## Troubleshooting

### Container build fails

**Problem**: Error during `./build-claude-container.sh`

**Solutions**:
1. Check internet connection (needs to download Debian image and Claude installer)
2. Verify Podman is installed: `podman --version`
3. Check disk space: `df -h`
4. Try rebuilding: `podman rmi claude-sandbox:latest && ./build-claude-container.sh`

### Permission denied errors

**Problem**: Can't read/write files in container

**Solutions**:
1. Verify user namespace mappings: `podman unshare cat /proc/self/uid_map`
2. Check file permissions on host
3. Try running without SELinux labels: already done via `--security-opt label=disable`

### Network issues

**Problem**: No internet access in default mode

**Solutions**:
1. Check host network: `ping -c 1 8.8.8.8`
2. Verify Podman networking: `podman network ls`
3. Try explicit network: Add `--network=slirp4netns` to podman run command in script

**Problem**: Can't access local services

**Expected behavior**: Local network is isolated by design in all modes.

### Network namespace issues

**Problem**: "Network namespace 'claude-restricted' not found" when using --allow-hosts

**Solutions**:
1. Setup namespace: `sudo ./setup-claude-netns.sh allowed-hosts.conf`
2. Or use systemd: `sudo systemctl start claude-netns.service`
3. Check status: `./status-claude-netns.sh`
4. Verify namespace exists: `sudo ip netns list`

**Problem**: "Permission denied" when setting up network namespace

**Solution**: The setup script requires root privileges. Use `sudo ./setup-claude-netns.sh`

**Problem**: Connections fail in --allow-hosts mode even though host is listed

**Solutions**:
1. Check namespace status: `./status-claude-netns.sh`
2. Verify iptables rules: `sudo ip netns exec claude-restricted iptables -L OUTPUT -n -v`
3. Test from namespace: `sudo ip netns exec claude-restricted curl -v https://yourhost.com`
4. Check if hostname resolved: Host may have changed IP, re-run setup
5. Verify DNS works: `sudo ip netns exec claude-restricted nslookup github.com`

**Problem**: Systemd service fails to start

**Solutions**:
1. Check service status: `sudo systemctl status claude-netns.service`
2. View logs: `sudo journalctl -u claude-netns.service -n 50`
3. Verify allowed-hosts.conf exists and path is correct in service file
4. Check script permissions: Scripts should be executable (`chmod +x`)

### Claude not found in container

**Problem**: `/usr/local/bin/claude: not found`

**Solutions**:
1. Rebuild container: `./build-claude-container.sh`
2. Check if installer succeeded during build
3. Manually verify: `podman run --rm claude-sandbox:latest ls -la /usr/local/bin/claude`

### Path issues

**Problem**: Current directory not found in container

**Solutions**:
1. Use absolute paths (script should handle this automatically)
2. Verify mount: Check script output for "Working directory: ..."
3. Ensure you're running from a real directory (not a symlink)

### Container doesn't start

**Problem**: Error messages when running `./run-claude.sh`

**Solutions**:
1. Check image exists: `podman images | grep claude-sandbox`
2. If not, build it: `./build-claude-container.sh`
3. Check Podman is running: `podman info`
4. Review error messages and check logs

## Advanced Usage

### Custom Network Configuration

Edit `run-claude.sh` to add custom network settings:

```bash
# Example: Add custom DNS server
NETWORK_ARGS="$NETWORK_ARGS --dns=1.1.1.1"

# Example: Expose a port (use cautiously)
NETWORK_ARGS="$NETWORK_ARGS -p 8080:8080"
```

### Additional Mounts

Add more directories to the mount list in `run-claude.sh`:

```bash
# Example: Mount a data directory readonly
MOUNTS="$MOUNTS -v /path/to/data:/path/to/data:ro"

# Example: Mount a scratch directory
MOUNTS="$MOUNTS -v /tmp/scratch:/tmp/scratch:rw"
```

### Resource Limits

Add resource constraints to the podman run command:

```bash
# Limit memory to 4GB
--memory=4g

# Limit CPU to 2 cores
--cpus=2

# Limit disk I/O
--device-write-bps=/dev/sda:1mb
```

## Files

**Core files**:
- `Containerfile` - Container image definition (Debian Trixie + Claude)
- `build-claude-container.sh` - Builds the container image
- `run-claude.sh` - Runs Claude in the container with all options
- `allowed-hosts.conf.example` - Example configuration for allowed hosts

**Network namespace management**:
- `setup-claude-netns.sh` - Creates network namespace with iptables rules (requires sudo)
- `cleanup-claude-netns.sh` - Removes network namespace and cleans up (requires sudo)
- `status-claude-netns.sh` - Shows status of network namespace and firewall rules
- `claude-netns.service` - Systemd service unit file for persistent namespace
- `install-systemd-service.sh` - Installs systemd service (requires sudo)

**Documentation**:
- `README.md` - This file

## Architecture

### Default Mode (slirp4netns)
```
Host System (Debian Trixie)
│
├── Podman (rootless)
│   │
│   └── Claude Container (claude-sandbox:latest)
│       ├── Debian Trixie base
│       ├── Claude CLI (/usr/local/bin/claude)
│       │
│       ├── Mounts (from host):
│       │   ├── $(pwd) -> $(pwd) [rw]
│       │   ├── ~/git/ -> ~/git/ [ro]
│       │   ├── ~/.claude/ -> ~/.claude/ [rw]
│       │   └── ~/.claude.json -> ~/.claude.json [rw]
│       │
│       ├── Network: slirp4netns
│       │   └── User-mode networking (internet, no LAN access)
│       │
│       └── User context:
│           ├── UID: 1000 (mapped via --userns=keep-id)
│           ├── GID: 1000 (mapped)
│           └── HOME: /home/sascha (matches host)
```

### Filtered Mode (--allow-hosts with network namespace)
```
Host System (Debian Trixie)
│
├── Network Namespace: claude-restricted
│   ├── veth-claude-ns (10.200.0.2)
│   ├── Default route via 10.200.0.1
│   └── iptables rules:
│       ├── DROP all by default
│       ├── ALLOW DNS (port 53)
│       ├── ALLOW established connections
│       └── ALLOW whitelisted IPs/ports only
│
├── Host veth: veth-claude (10.200.0.1)
│   ├── NAT to internet
│   └── IP forwarding enabled
│
└── Podman (rootless)
    │
    └── Claude Container (claude-sandbox:latest)
        ├── Network: ns:/var/run/netns/claude-restricted
        ├── Mounts: (same as default mode)
        └── User context: (same as default mode)
```

## Contributing

This is a personal security tool. Feel free to fork and adapt to your needs.

Suggested improvements:
- IPv6 filtering support in network namespace
- Support for other base images (Alpine, Ubuntu, etc.)
- GPU support for local models
- Dynamic IP tracking (monitor DNS changes and update rules)
- Web UI for managing allowed hosts
- Integration with other container runtimes (docker, nerdctl)

## License

Use freely for personal or commercial purposes. No warranty provided.

## Changelog

### v2.0.0 (2026-01-10)
- **BREAKING**: Changed --allow-hosts to use network namespace with iptables (TRUE filtering)
- Added network namespace management scripts (setup, cleanup, status)
- Added systemd service for persistent network namespace
- Updated allowed-hosts.conf format to support host:port specifications
- Added comprehensive troubleshooting for network namespace setup
- Enhanced README with architecture diagrams and security considerations

### v1.0.0 (2026-01-10)
- Initial release
- Debian Trixie base
- Three network modes (default, no-internet, allowed-hosts with DNS only)
- Smart mount handling for $(pwd) and ~/git/
- User namespace mapping for correct permissions
