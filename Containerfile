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
    pipx \
    virtualenv \
    flex \
    vim \
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
    libssl-dev \
    libseccomp-dev \
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
    sudo \
    bison \
    && rm -rf /var/lib/apt/lists/*

ENV GCC_VERSION=15.2.0

# Manually install the kernel.org Crosstool based toolchains
RUN korg_crosstool_dl() { wget -nv -O - https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/${1}/${2}/${1}-gcc-${2}-nolibc-${3}.tar.xz | tar -C /opt -xJ ; } && \
    korg_crosstool_dl x86_64 ${GCC_VERSION} arm-linux-gnueabi && \
    korg_crosstool_dl x86_64 ${GCC_VERSION} aarch64-linux     && \
    korg_crosstool_dl x86_64 ${GCC_VERSION} mips-linux        && \
    korg_crosstool_dl x86_64 ${GCC_VERSION} or1k-linux        && \
    korg_crosstool_dl x86_64 ${GCC_VERSION} powerpc-linux     && \
    korg_crosstool_dl x86_64 ${GCC_VERSION} riscv64-linux

RUN tgz_checksum_dl() { set -e; wget -nv -O archive.tgz "$1"; \
                        echo "$2 archive.tgz" | sha256sum --check --status; tar -C /opt -xzf archive.tgz; rm archive.tgz; } && \
    tgz_checksum_dl https://github.com/kalray/build-scripts/releases/download/v5.2.0/gcc-kalray-kvx-ubuntu-22.04-v5.2.0.tar.gz \
                    f59964cac188f1e5a8f628d0abef68e3b6ceebdae18dff51625472329fe6ec40

RUN wget -nv "https://github.com/qemu/qemu/blob/v10.1.0/pc-bios/opensbi-riscv32-generic-fw_dynamic.bin?raw=true" -O /usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin

# Create our user/group
RUN useradd -m -U barebox
RUN echo barebox ALL=NOPASSWD: ALL > /etc/sudoers.d/barebox

# install labgrid
RUN pip3 install -q --no-cache-dir --break-system-packages \
    git+https://github.com/labgrid-project/labgrid.git@v25.0.1 && \
    ln -s $(which pytest) /usr/local/bin/labgrid-pytest

RUN pip3 install -q --no-cache-dir --break-system-packages \
    git+https://github.com/saschahauer/barebox-bringup.git@master

ENV CROSS_COMPILE_arm=/opt/gcc-${GCC_VERSION}-nolibc/arm-linux-gnueabi/bin/arm-linux-gnueabi-
ENV CROSS_COMPILE_arm64=/opt/gcc-${GCC_VERSION}-nolibc/aarch64-linux/bin/aarch64-linux-
ENV CROSS_COMPILE_mips=/opt/gcc-${GCC_VERSION}-nolibc/mips-linux/bin/mips-linux-
ENV CROSS_COMPILE_openrisc=/opt/gcc-${GCC_VERSION}-nolibc/or1k-linux/bin/or1k-linux-
ENV CROSS_COMPILE_powerpc=/opt/gcc-${GCC_VERSION}-nolibc/powerpc-linux/bin/powerpc-linux-
ENV CROSS_COMPILE_riscv=/opt/gcc-${GCC_VERSION}-nolibc/riscv64-linux/bin/riscv64-linux-
ENV CROSS_COMPILE_kvx=/opt/gcc-kalray-kvx-v5.2.0/bin/kvx-elf-

# Install Claude and set up PATH
# The installer puts claude in ~/.local/bin/claude (symlink to version in ~/.local/share/claude/versions/)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Copy binary to system location (not symlink, because /root is not accessible to non-root users)
# Follow the symlink and copy the actual binary
RUN cp "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude && \
    chmod 755 /usr/local/bin/claude

# Default command
CMD ["/usr/local/bin/claude"]
