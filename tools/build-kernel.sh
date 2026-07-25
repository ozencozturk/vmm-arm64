#!/bin/sh
# Build the arm64 Linux kernel Image for the vmm guest.
#
# WHY DOCKER: a Linux checkout has case-colliding filenames that corrupt on a
# default case-insensitive macOS (APFS) volume. We build inside an arm64 Debian
# container so the kernel tree lives on the container's case-sensitive fs and
# never touches the host — only the finished Image + .config are copied out.
# The container is arm64-native on Apple Silicon (no emulation), so the native
# gcc is already an arm64 compiler → no CROSS_COMPILE needed.
# (Debian, not Ubuntu: one multi-arch CDN mirror instead of ports.ubuntu.com.)
#
# OUTPUT:  payloads/Image          (the raw, 2 MiB-alignable kernel binary)
#          payloads/kernel.config  (the resolved .config, for reproducibility)
#
# Re-runs are incremental: the kernel source + object files persist in a Docker
# named volume ($KVOL). Delete it to start clean: docker volume rm $KVOL
#
# Overridable via env:  KERNEL_TAG=v6.12  JOBS=8  IMG=debian:stable-slim
set -eu
cd "$(dirname "$0")/.."

KERNEL_TAG="${KERNEL_TAG:-v6.12}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
IMG="${IMG:-debian:stable-slim}"
KVOL="${KVOL:-vmm-kbuild}"
OUT="payloads"

command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }

mkdir -p "$OUT"

echo ">> building linux $KERNEL_TAG (arm64) with -j$JOBS in $IMG"
docker run --rm \
    -e KERNEL_TAG="$KERNEL_TAG" -e JOBS="$JOBS" \
    -v "$KVOL:/build" \
    -v "$PWD/$OUT:/out" \
    "$IMG" bash -euc '
        export DEBIAN_FRONTEND=noninteractive
        printf '\''Acquire::Retries "5";\nAcquire::http::Timeout "30";\n'\'' > /etc/apt/apt.conf.d/99retry
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            ca-certificates git build-essential bc bison flex libssl-dev libelf-dev cpio kmod \
            >/dev/null

        cd /build
        if [ ! -d linux/.git ]; then
            git clone --depth 1 --branch "$KERNEL_TAG" \
                https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux
        else
            git -C linux fetch --depth 1 origin "$KERNEL_TAG"
            git -C linux checkout -q FETCH_HEAD
        fi
        cd linux

        make ARCH=arm64 defconfig

        # enable everything the vmm platform depends on (idempotent; olddefconfig
        # then resolves dependencies).
        for opt in \
            SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_OF_PLATFORM SERIAL_EARLYCON \
            BLK_DEV_INITRD DEVTMPFS DEVTMPFS_MOUNT \
            VIRTIO VIRTIO_MMIO VIRTIO_BLK \
            ARM_GIC_V3 ARM_ARCH_TIMER ARM_PSCI_FW ; do
            ./scripts/config -e "$opt"
        done
        make ARCH=arm64 olddefconfig

        make ARCH=arm64 -j"$JOBS" Image

        cp -v arch/arm64/boot/Image /out/Image
        cp -v .config               /out/kernel.config
    '

echo ">> verifying Image header magic (ARM\\x64 at offset 0x38)"
magic=$(xxd -s 0x38 -l 4 -p "$OUT/Image")
if [ "$magic" = "41524d64" ]; then
    echo "   ok: magic=$magic  size=$(wc -c < "$OUT/Image") bytes"
else
    echo "   error: bad magic '$magic' (expected 41524d64) — not a valid arm64 Image" >&2
    exit 1
fi

echo ">> done: $OUT/Image, $OUT/kernel.config"
