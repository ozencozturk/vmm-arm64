#!/bin/sh
# Build a virtio-blk backing disk for the vmm guest.
#
# Produces a raw ext4 image the vmm mmaps and hands to devices.Virtio as its
# `disk: []u8`. The guest sees it as /dev/vda; capacity is disk.len/512, so the
# file size IS the reported disk size (keep it a multiple of 512 — any MiB is).
#
# The filesystem is populated with mke2fs -d, which copies a directory tree into
# a fresh image at format time WITHOUT mounting it — so this needs no loop device
# and no root, and runs unprivileged inside the container. ext4 because the kernel
# has CONFIG_EXT4_FS=y built in (no module to load); it is read-write, so the
# guest can write and the writes persist back through the host mmap (MAP_SHARED).
#
# OUTPUT:  payloads/disk.img   (raw ext4, label "vmmdisk", holds /hello.txt)
#
# Verify from the guest: at the shell,
#   mount /dev/vda /mnt && cat /mnt/hello.txt
#
# Overridable via env:  SIZE=64M  LABEL=vmmdisk  IMG=debian:stable-slim
set -eu
cd "$(dirname "$0")/.."

SIZE="${SIZE:-64M}"
LABEL="${LABEL:-vmmdisk}"
IMG="${IMG:-debian:stable-slim}"
OUT="payloads"
DISK="disk.img"

command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }

mkdir -p "$OUT"

echo ">> building $OUT/$DISK ($SIZE ext4, label '$LABEL') in $IMG"
docker run --rm \
    -e SIZE="$SIZE" -e LABEL="$LABEL" -e DISK="$DISK" \
    -v "$PWD/$OUT:/out" \
    "$IMG" bash -euc '
        export DEBIAN_FRONTEND=noninteractive
        printf '\''Acquire::Retries "5";\nAcquire::http::Timeout "30";\n'\'' > /etc/apt/apt.conf.d/99retry
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends e2fsprogs >/dev/null

        # the content tree that lands at the root of the filesystem
        root=/root/diskroot
        rm -rf "$root" && mkdir -p "$root"
        printf "hello from vmm virtio-blk\n" > "$root/hello.txt"

        # a sparse file of the exact requested size, then format-and-populate it
        # in one shot. -F: non-interactive (target is a file, not a block device).
        truncate -s "$SIZE" "/out/$DISK"
        mke2fs -q -t ext4 -F -L "$LABEL" -d "$root" "/out/$DISK"

        echo "-- dumpe2fs header --"
        dumpe2fs -h "/out/$DISK" 2>/dev/null | grep -E "Filesystem volume name|Block count|Block size|Filesystem features" || true
        echo "-- root listing (via debugfs, no mount) --"
        debugfs -R "ls -l /" "/out/$DISK" 2>/dev/null
    '

echo ">> verifying size and ext4 superblock magic (0xEF53 @ offset 1080)"
bytes=$(wc -c < "$OUT/$DISK")
magic=$(dd if="$OUT/$DISK" bs=1 skip=1080 count=2 2>/dev/null | xxd -p)
if [ "$magic" = "53ef" ]; then
    echo "   ok: size=$bytes bytes, ext4 magic present ($magic = 0xEF53 LE)"
else
    echo "   error: bad ext4 magic '$magic' (expected 53ef) — not an ext4 image" >&2
    exit 1
fi

echo ">> done: $OUT/$DISK"
