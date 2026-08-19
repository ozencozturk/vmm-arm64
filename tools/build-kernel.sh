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
# Overridable via env:
#   KERNEL_TAG=v6.12   which stable tag to build
#   JOBS=N             parallelism
#   IMG=debian:stable-slim  build image
#   KVOL=vmm-kbuild    docker volume holding source and objects
#   PLATFORMS="A B"    SoC platforms to turn off (see below)
#   DISABLE="A B C"    extra CONFIG_ symbols to turn off, applied after PLATFORMS
#   ENABLE="A B C"     extra CONFIG_ symbols to turn on, applied after DISABLE
#   OUT=<dir>          where to write Image and kernel.config; the default is the
#                      payloads directory the VMM boots from, so an experiment
#                      that must not replace the shipped guest points elsewhere
set -eu
cd "$(dirname "$0")/.."

KERNEL_TAG="${KERNEL_TAG:-v6.12}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
IMG="${IMG:-debian:stable-slim}"
KVOL="${KVOL:-vmm-kbuild}"
OUT="${OUT:-$PWD/payloads}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

# WHY A SLIM GUEST: arm64 defconfig is a single kernel meant to boot every arm64
# machine that exists, and it costs what that implies — a 45 MB Image, 1100-odd
# modules, and a boot that probes for hardware this VMM does not have. What this
# guest actually sees is a PL011-compatible 8250, a GICv3, the architectural
# timer, PSCI over HVC, and two virtio-mmio windows. Everything else initialises
# for a device that cannot exist.
#
# The lever is the SoC platform list, not the driver list. Vendor drivers are
# `depends on ARCH_<vendor> || COMPILE_TEST`, so turning a platform off drops its
# clock, pinctrl, PHY, regulator, MMC, PCI-host and SoC glue with it — one symbol
# each instead of hundreds. Only top-level vendors are named here; the sub-
# platforms (ARCH_BCM2835 under ARCH_BCM, ARCH_LAYERSCAPE/MXC/S32 under ARCH_NXP,
# the Renesas R8A parts under ARCH_RENESAS) go with their parent.
#
# Nothing here is a claim that a guest may never want these. It is a statement of
# what this VMM presents today: re-enable a platform the moment one is emulated.
PLATFORMS="${PLATFORMS-ARCH_ACTIONS ARCH_AIROHA ARCH_SUNXI ARCH_ALPINE ARCH_APPLE \
ARCH_BCM ARCH_BERLIN ARCH_EXYNOS ARCH_SPARX5 ARCH_K3 ARCH_LG1K ARCH_HISI \
ARCH_KEEMBAY ARCH_MEDIATEK ARCH_MESON ARCH_MVEBU ARCH_NXP ARCH_MA35 ARCH_NPCM \
ARCH_QCOM ARCH_REALTEK ARCH_RENESAS ARCH_ROCKCHIP ARCH_SEATTLE \
ARCH_INTEL_SOCFPGA ARCH_STM32 ARCH_SYNQUACER ARCH_TEGRA ARCH_TESLA_FSD \
ARCH_SPRD ARCH_THUNDER ARCH_THUNDER2 ARCH_UNIPHIER ARCH_VEXPRESS \
ARCH_VISCONTI ARCH_XGENE ARCH_ZYNQMP}"

# What the platform cull cannot reach: subsystems that are generic, so they do
# not depend on any ARCH_ symbol and survive every vendor going away.
#
# The first group is hardware this VMM does not present. PCI is the notable one
# and the notable difference from the x86 side of this project — there the guest
# enumerates through ACPI and needs a PCI bus behind it, here the guest is handed
# a device tree that names two virtio-mmio windows and nothing else. ACPI goes
# with it for the same reason: this VMM builds a DTB, and an arm64 kernel that
# finds no ACPI tables falls back to the device tree anyway, so the code is
# unreachable rather than merely unused. EFI likewise — the VMM loads the Image
# and jumps to it per the arm64 boot protocol, so the EFI stub is never entered.
#
# MODULES is the other structural one. Nothing loads a module in this guest and
# defconfig marks 1167 symbols =m; with MODULES off kconfig resolves those to n
# instead of building them. It does not shrink the Image — modules were never in
# it — but it removes the whole second build and the loader path with it.
#
# COMPAT is 32-bit ARM userspace, in a guest whose init is an arm64 busybox.
#
# The second group is debug and instrumentation facilities that cost boot time
# and report to nobody. PRINTK_TIME is deliberately kept: the console timestamps
# are how a boot is read.
#
# The third group mirrors the x86 guest's list, restricted to symbols an arm64
# kernel also knows, so the two guests differ by architecture and not by taste.
# INET6_ESP/INET6_AH are IPv6 IPsec in a guest with no network interface, and
# they are the root of a chain that ends at CRYPTO_JITTERENTROPY. Disabling the
# tail alone does nothing — olddefconfig re-selects it from the top — and cutting
# only INET6_ESP is not enough either, because SEQIV and ECHAINIV carry prompts
# and so survive their selector going away. Every entry point has to be named.
#
# The fourth group is what MODULES=n promotes rather than removes. defconfig
# marks these =m, and a tristate whose module option is gone resolves to its
# built-in default instead of vanishing — so cutting MODULES puts btrfs, NFS and
# overlayfs INTO the image, which is the opposite of the intent. They are named
# here for the same reason as everything else: this guest mounts one ext4 image
# on /dev/vda and runs its root from the initramfs, so EXT4 and JBD2 stay and the
# rest go. KVM is nested virtualisation in a guest that hosts nothing, NUMA is a
# second memory node that does not exist, and the networking group is a stack
# with no interface under it.
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

        # What this VMM actually presents to the guest (idempotent; olddefconfig
        # below then resolves dependencies). Applied BEFORE the culls, so a
        # symbol named in both ends up off — the cull is the later word.
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

        # A cull that olddefconfig quietly undid is the failure mode this whole
        # script exists to avoid, and it is invisible in a build that succeeds.
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
