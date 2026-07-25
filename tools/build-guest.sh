#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
zig cc -target aarch64-freestanding-none -c src/guest.S -o /tmp/guest.o
zig objcopy -O binary /tmp/guest.o src/guest.bin
ls -l src/guest.bin
