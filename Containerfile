FROM debian:trixie-slim

# Install dependencies for Claude installer
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    iputils-ping \
    net-tools \
    git \
    python3 \
    python3-pip \
    virtualenv \
    flex \
    gawk \
    lz4 \
    util-linux \
    wget \
    curl \
    lzop \
    libtool \
    build-essential \
    coreutils \
    device-tree-compiler \
    u-boot-tools \
    yamllint \
    pkg-config \
    qemu-system-arm \
    qemu-system-misc \
    qemu-system-mips \
    qemu-system-x86 \
    qemu-system-common \
    imagemagick \
    yq \
    openssl \
    gcc-multilib \
    bash \
    bash-completion \
    && rm -rf /var/lib/apt/lists/*

# Install Claude and set up PATH
# The installer puts claude in ~/.local/bin/claude (symlink to version in ~/.local/share/claude/versions/)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Copy binary to system location (not symlink, because /root is not accessible to non-root users)
# Follow the symlink and copy the actual binary
RUN cp "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude && \
    chmod 755 /usr/local/bin/claude

# Default command
CMD ["/usr/local/bin/claude"]
