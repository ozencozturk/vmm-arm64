#!/bin/sh
# Build the busybox initramfs.cpio for the vmm guest.
#
# Builds a statically-linked arm64 busybox inside an arm64 Debian container
# (native on Apple Silicon, no emulation; Debian's one multi-arch CDN mirror
# avoids the flaky ports.ubuntu.com host), assembles a minimal rootfs around it,
# and packs it as an UNCOMPRESSED newc cpio — the exact format the kernel's
# initramfs unpacker reads. Uncompressed on purpose: one less variable while
# chasing the first /init. Add gzip later if size ever matters.
#
# OUTPUT:  payloads/initramfs.cpio   (newc, root-owned, /init + busybox + sh)
#          payloads/busybox.config   (the resolved .config, for reproducibility)
#
# Re-runs are incremental via a Docker named volume ($BVOL).
# Overridable via env:  BUSYBOX_TAG=1_36_1  JOBS=8  IMG=debian:stable-slim
set -eu
cd "$(dirname "$0")/.."

BUSYBOX_TAG="${BUSYBOX_TAG:-1_36_1}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
IMG="${IMG:-debian:stable-slim}"
BVOL="${BVOL:-vmm-bbbuild}"
OUT="payloads"

command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }

mkdir -p "$OUT"

echo ">> building busybox $BUSYBOX_TAG (arm64, static) with -j$JOBS in $IMG"
docker run --rm \
    -e BUSYBOX_TAG="$BUSYBOX_TAG" -e JOBS="$JOBS" \
    -v "$BVOL:/build" \
    -v "$PWD/$OUT:/out" \
    "$IMG" bash -euc '
        export DEBIAN_FRONTEND=noninteractive
        printf '\''Acquire::Retries "5";\nAcquire::http::Timeout "30";\n'\'' > /etc/apt/apt.conf.d/99retry
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            ca-certificates git build-essential libc6-dev cpio \
            >/dev/null

        cd /build
        if [ ! -d busybox/.git ]; then
            git clone --depth 1 --branch "$BUSYBOX_TAG" \
                https://git.busybox.net/busybox busybox
        fi
        cd busybox

        make defconfig
        # static link, and drop the tc applet (its build breaks against modern
        # kernel headers — a well-known busybox issue).
        sed -i -e "s/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/" \
               -e "s/^CONFIG_TC=y/# CONFIG_TC is not set/" .config
        yes "" | make oldconfig >/dev/null

        make -j"$JOBS"
        make CONFIG_PREFIX=_install install   # → _install/{bin,sbin,usr}/ applet tree
        cp .config /out/busybox.config

        # assemble the rootfs: applet tree + mount points + /init
        rm -rf /root/rootfs && mkdir -p /root/rootfs
        cp -a _install/. /root/rootfs/
        mkdir -p /root/rootfs/proc /root/rootfs/sys /root/rootfs/dev
        cat > /root/rootfs/init <<'"'"'INIT'"'"'
#!/bin/sh
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev
echo "== vmm guest userspace up =="
exec /bin/sh
INIT
        chmod 0755 /root/rootfs/init

        # pack as newc cpio (root-owned: uid/gid 0 inside the container).
        ( cd /root/rootfs && find . -print0 | sort -z \
            | cpio --null --create --format=newc --owner=0:0 ) > /out/initramfs.cpio 2>/dev/null
    '

echo ">> verifying newc magic (070701) and listing contents"
magic=$(head -c 6 "$OUT/initramfs.cpio")
if [ "$magic" = "070701" ]; then
    echo "   ok: magic=$magic  size=$(wc -c < "$OUT/initramfs.cpio") bytes"
    cpio -itv < "$OUT/initramfs.cpio" 2>/dev/null | head -20
else
    echo "   error: bad magic '$magic' (expected 070701) — not a newc cpio" >&2
    exit 1
fi

echo ">> done: $OUT/initramfs.cpio, $OUT/busybox.config"
