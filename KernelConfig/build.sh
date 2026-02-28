#!/bin/bash
# PocketDev Linux Kernel Build Script
# Cross-compiles an ARM64 kernel optimized for container VMs
#
# On macOS: uses Docker (reliable, reproducible)
# On Linux: uses native aarch64-linux-gnu cross-compiler

set -e

KERNEL_VERSION="6.18.5"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
OUTPUT_DIR="${PROJECT_DIR}/Resources"

echo "=== PocketDev Kernel Builder ==="
echo "Target: Linux ${KERNEL_VERSION} ARM64"
echo ""

mkdir -p "${OUTPUT_DIR}"

# Detect build method
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: use Docker
    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker is required on macOS."
        echo "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        echo "ERROR: Docker daemon is not running. Start Docker Desktop first."
        exit 1
    fi

    echo "Building kernel in Docker container..."
    docker build -t pocketdev-kernel-builder "${SCRIPT_DIR}"

    docker run --rm \
        -v "${PROJECT_DIR}:/project:delegated" \
        pocketdev-kernel-builder bash -c "
            set -e
            cd /tmp
            echo 'Downloading Linux ${KERNEL_VERSION}...'
            curl -LO '${KERNEL_URL}'
            tar xf 'linux-${KERNEL_VERSION}.tar.xz'
            cd 'linux-${KERNEL_VERSION}'

            cp /project/KernelConfig/config-arm64 .config
            make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
            echo 'Compiling kernel (this takes a few minutes)...'
            make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j\$(nproc) Image

            cp arch/arm64/boot/Image /project/Resources/vmlinux
            echo 'Kernel copied to Resources/vmlinux'
        "
else
    # Linux: use native cross-compiler or native build
    if [[ "$(uname -m)" == "aarch64" ]]; then
        CROSS_COMPILE=""
        echo "Building natively on ARM64 Linux..."
    else
        if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
            echo "ERROR: Install cross-compiler: sudo apt install gcc-aarch64-linux-gnu"
            exit 1
        fi
        CROSS_COMPILE="aarch64-linux-gnu-"
        echo "Cross-compiling on $(uname -m) Linux..."
    fi

    BUILD_DIR="/tmp/pocketdev-kernel-build"
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    if [ ! -d "linux-${KERNEL_VERSION}" ]; then
        echo "Downloading Linux ${KERNEL_VERSION}..."
        curl -LO "${KERNEL_URL}"
        tar xf "linux-${KERNEL_VERSION}.tar.xz"
    fi

    cd "linux-${KERNEL_VERSION}"
    cp "${SCRIPT_DIR}/config-arm64" .config
    make ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
    echo "Compiling kernel..."
    make ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" -j"$(nproc)" Image
    cp arch/arm64/boot/Image "${OUTPUT_DIR}/vmlinux"
fi

echo ""
echo "=== Build Complete ==="
echo "Kernel: ${OUTPUT_DIR}/vmlinux"
echo "Size: $(du -h "${OUTPUT_DIR}/vmlinux" | cut -f1)"
