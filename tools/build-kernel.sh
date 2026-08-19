#!/bin/sh
# Build the arm64 Linux kernel Image for the vmm guest.
#
# Builds inside an arm64 Debian container: a Linux checkout has case-colliding
# filenames that corrupt on a case-insensitive macOS volume. The container is
# arm64-native on Apple Silicon, so no CROSS_COMPILE is needed.
#
# OUTPUT:  payloads/Image          the kernel binary
#          payloads/kernel.config  the resolved .config
#
# Source and objects persist in the docker volume $KVOL, so re-runs are
# incremental. Clean build: docker volume rm $KVOL
#
# Overridable via env:
#   KERNEL_TAG=v6.12        stable tag to build
#   JOBS=N                  parallelism
#   IMG=debian:stable-slim  build image
#   KVOL=vmm-kbuild         docker volume holding source and objects
#   PLATFORMS="A B"         SoC platforms to disable
#   DISABLE="A B C"         further CONFIG_ symbols to disable, applied after PLATFORMS
#   ENABLE="A B C"          CONFIG_ symbols to enable, applied after DISABLE
#   OUT=<dir>               where to write Image and kernel.config
set -eu
cd "$(dirname "$0")/.."

KERNEL_TAG="${KERNEL_TAG:-v6.12}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
IMG="${IMG:-debian:stable-slim}"
KVOL="${KVOL:-vmm-kbuild}"
OUT="${OUT:-$PWD/payloads}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

# SoC platforms disabled. Vendor drivers are `depends on ARCH_<vendor> ||
# COMPILE_TEST`, so disabling one platform drops its clock, pinctrl, PHY,
# regulator, MMC, PCI-host and SoC-glue drivers with it. Only top-level vendors
# are listed: ARCH_BCM2835 goes with ARCH_BCM, ARCH_LAYERSCAPE/MXC/S32 with
# ARCH_NXP, the Renesas R8A parts with ARCH_RENESAS.
#
# arm64 defconfig enables 44 of these; this VMM presents an 8250, a GICv3, the
# architectural timer, PSCI over HVC and two virtio-mmio windows.
PLATFORMS="${PLATFORMS-ARCH_ACTIONS ARCH_AIROHA ARCH_SUNXI ARCH_ALPINE ARCH_APPLE \
ARCH_BCM ARCH_BERLIN ARCH_EXYNOS ARCH_SPARX5 ARCH_K3 ARCH_LG1K ARCH_HISI \
ARCH_KEEMBAY ARCH_MEDIATEK ARCH_MESON ARCH_MVEBU ARCH_NXP ARCH_MA35 ARCH_NPCM \
ARCH_QCOM ARCH_REALTEK ARCH_RENESAS ARCH_ROCKCHIP ARCH_SEATTLE \
ARCH_INTEL_SOCFPGA ARCH_STM32 ARCH_SYNQUACER ARCH_TEGRA ARCH_TESLA_FSD \
ARCH_SPRD ARCH_THUNDER ARCH_THUNDER2 ARCH_UNIPHIER ARCH_VEXPRESS \
ARCH_VISCONTI ARCH_XGENE ARCH_ZYNQMP}"

# Symbols no ARCH_ cull reaches, since they depend on no platform.
#
#   PCI, ACPI, EFI
#       The guest is handed a DTB and entered per the arm64 boot protocol, so
#       none of the three is reached. (The x86 side of this project keeps PCI
#       and ACPI: it enumerates through the DSDT.)
#   MODULES, COMPAT
#       Nothing loads a module; userspace is arm64.
#   BTRFS_FS ... IPV6 (last group)
#       defconfig marks these =m. With MODULES=n a tristate falls back to its
#       built-in default rather than disappearing, so they must be named or they
#       end up IN the image. EXT4_FS and JBD2 are kept for /dev/vda.
#   INET6_ESP, INET6_AH, CRYPTO_SEQIV, CRYPTO_ECHAINIV, CRYPTO_DRBG_MENU,
#   CRYPTO_JITTERENTROPY
#       One selection chain. Each carries its own prompt, so disabling the tail
#       alone lets olddefconfig re-select it from the top; every entry point has
#       to be named.
#   the rest
#       Hardware this VMM does not present, and debug facilities. PRINTK_TIME is
#       kept: the console timestamps are how a boot is read.
DISABLE="${DISABLE-PCI ACPI EFI MODULES COMPAT \
DRM SOUND USB_SUPPORT ATA SCSI NVME_CORE MMC MTD MD I2C SPI INPUT HID \
NETDEVICES ETHERNET WLAN BT MEDIA_SUPPORT IIO PWM REGULATOR PHY_CAN_TRANSCEIVER \
HWMON THERMAL WATCHDOG RTC_CLASS CPU_FREQ DEVFREQ REMOTEPROC MAILBOX EXTCON \
NVMEM FIREWIRE STAGING GPIOLIB CRYPTO_HW SOUNDWIRE VIRTIO_INPUT \
BACKLIGHT_CLASS_DEVICE NEW_LEDS RFKILL WIRELESS HOTPLUG_PCI CRASH_DUMP KEXEC \
BLK_DEV_IO_TRACE FTRACE DEBUG_WX DEBUG_STACK_USAGE DEBUG_DEVRES \
SCHEDSTATS CGROUP_DEBUG PM_DEBUG RCU_TRACE RUNTIME_TESTING_MENU \
KALLSYMS_ALL KPROBES LOCALVERSION_AUTO MODULE_UNLOAD \
ISO9660_FS VFAT_FS MSDOS_FS NFS_V3 NET_9P NETFILTER \
NLS_ASCII NLS_CODEPAGE_437 NLS_ISO8859_1 NLS_UTF8 QFMT_V2 RPCSEC_GSS_KRB5 \
SERIAL_8250_EXTENDED SERIAL_NONSTANDARD SERIAL_8250_DEPRECATED_OPTIONS \
INTEGRITY LEGACY_TIOCSTI CACHESTAT_SYSCALL CGROUP_MISC CGROUP_RDMA \
BLK_CGROUP_IOLATENCY BLK_CGROUP_IOPRIO BLK_DEV_WRITE_MOUNTED \
CRYPTO_AUTHENC CRYPTO_CCM CRYPTO_CMAC CRYPTO_GCM CRYPTO_GHASH \
INET6_ESP INET6_AH CRYPTO_SEQIV CRYPTO_ECHAINIV CRYPTO_DRBG_MENU \
CRYPTO_JITTERENTROPY \
BTRFS_FS NFS_FS SUNRPC OVERLAY_FS FUSE_FS SQUASHFS CEPH_LIB \
KVM NUMA HIBERNATION AUDIT NET_SCHED BRIDGE VLAN_8021Q IPV6}"

command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }

mkdir -p "$OUT"

echo ">> building linux $KERNEL_TAG (arm64) with -j$JOBS in $IMG"
docker run --rm \
    -e KERNEL_TAG="$KERNEL_TAG" -e JOBS="$JOBS" \
    -e PLATFORMS="$PLATFORMS" -e DISABLE="$DISABLE" -e ENABLE="${ENABLE:-}" \
    -v "$KVOL:/build" \
    -v "$OUT:/out" \
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

        # What this VMM presents to the guest. Applied before the culls, so a
        # symbol named in both ends up disabled.
        for opt in \
            SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_OF_PLATFORM SERIAL_EARLYCON \
            BLK_DEV_INITRD DEVTMPFS DEVTMPFS_MOUNT \
            VIRTIO VIRTIO_MMIO VIRTIO_BLK VIRTIO_CONSOLE \
            ARM_GIC_V3 ARM_ARCH_TIMER ARM_PSCI_FW PRINTK_TIME ; do
            ./scripts/config -e "$opt"
        done

        for d in $PLATFORMS $DISABLE; do ./scripts/config -d "$d"; done
        for e in ${ENABLE:-}; do ./scripts/config -e "$e"; done

        make ARCH=arm64 olddefconfig

        # olddefconfig can re-resolve a symbol either way, and the build still
        # succeeds when it does. Check both directions.
        for opt in VIRTIO_MMIO VIRTIO_BLK VIRTIO_CONSOLE SERIAL_8250_CONSOLE \
                   BLK_DEV_INITRD ARM_GIC_V3 ARM_PSCI_FW ; do
            grep -q "^CONFIG_$opt=y" .config \
                || { echo "error: CONFIG_$opt did not survive olddefconfig" >&2; exit 1; }
        done
        for opt in PCI ACPI MODULES ; do
            if grep -q "^CONFIG_$opt=y" .config; then
                echo "error: CONFIG_$opt survived olddefconfig" >&2; exit 1
            fi
        done

        make ARCH=arm64 LOCALVERSION= -j"$JOBS" Image

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
