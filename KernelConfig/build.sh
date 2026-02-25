#!/bin/bash
# PocketDev Linux Kernel Build Script
# Cross-compiles an ARM64 kernel optimized for container VMs
# Run this on a Mac with the ARM64 cross-compiler installed

set -e

KERNEL_VERSION="6.18.5"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
BUILD_DIR="/tmp/pocketdev-kernel-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../Resources"

echo "=== PocketDev Kernel Builder ==="
echo "Target: Linux ${KERNEL_VERSION} ARM64"
echo ""

# Install cross-compiler if needed (macOS)
if [[ "$(uname)" == "Darwin" ]]; then
    if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
        echo "Installing ARM64 cross-compiler..."
        brew install aarch64-elf-gcc || {
            echo "ERROR: Install cross-compiler: brew install aarch64-elf-gcc"
            exit 1
        }
    fi
    CROSS_COMPILE="aarch64-linux-gnu-"
else
    # On Linux ARM64, no cross-compiler needed
    CROSS_COMPILE=""
fi

# Download kernel source
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [ ! -d "linux-${KERNEL_VERSION}" ]; then
    echo "Downloading Linux ${KERNEL_VERSION}..."
    curl -LO "${KERNEL_URL}"
    tar xf "linux-${KERNEL_VERSION}.tar.xz"
fi

cd "linux-${KERNEL_VERSION}"

# Copy our config
cp "${SCRIPT_DIR}/config-arm64" .config

# Update config with defaults for any new options
make ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

# Build
echo "Building kernel..."
NPROC=$(( $(nproc 2>/dev/null || sysctl -n hw.ncpu) - 1 ))
make ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" -j${NPROC}

# Copy output
mkdir -p "${OUTPUT_DIR}"
cp arch/arm64/boot/Image "${OUTPUT_DIR}/vmlinux"

echo ""
echo "=== Build Complete ==="
echo "Kernel: ${OUTPUT_DIR}/vmlinux"
echo "Size: $(du -h "${OUTPUT_DIR}/vmlinux" | cut -f1)"
