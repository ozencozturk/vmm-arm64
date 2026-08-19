# vmm-arm64

A small, from-scratch **arm64 virtual machine monitor** for Apple Silicon, written
in [Zig](https://ziglang.org/). It runs on Apple's
[Hypervisor.framework](https://developer.apple.com/documentation/hypervisor) (HVF)
and boots a real Linux kernel into a BusyBox userspace.

The goal is a readable, minimal reference for how a VMM actually works: setting up
stage-2 memory, running a vCPU, decoding traps, emulating just enough platform
hardware for Linux to boot, and building the device tree the kernel needs.

## What it does

- Creates a VM and a single vCPU through HVF and maps guest RAM at stage 2.
- Loads an arm64 Linux `Image`, an initramfs, and a runtime-generated flattened
  device tree (FDT) into guest memory per the arm64 boot protocol.
- Emulates the platform the kernel probes for:
  - a **PL011 UART** for the console,
  - a **GICv3** interrupt controller and the architectural timer,
  - **PSCI** (over HVC) for power control — `poweroff` in the guest halts the VM,
  - a **virtio-blk** device backed by a raw disk image (`/dev/vda`),
  - a **virtio-console** on a second virtio-mmio window (`hvc0`).
- Decodes and services system-register traps (e.g. the OS-lock registers HVF traps
  unconditionally on cold boot) and MMIO data aborts.
- Builds the FDT itself, rather than shipping a precompiled blob.

The guest gets **64 MiB** of RAM and a purpose-built slim kernel — see
[Building the guest payloads](#building-the-guest-payloads).

## Requirements

- An **Apple Silicon** Mac (M1 or later) running macOS.
- **Zig** — at least the version pinned in `build.zig.zon`
  (`minimum_zig_version`); this project tracks a 0.17-dev toolchain.
- **Docker** — only to build the guest payloads (kernel, initramfs, disk). The
  build scripts compile inside an arm64 Debian container so a case-insensitive
  macOS filesystem doesn't corrupt the Linux source tree.

The VMM binary is ad-hoc codesigned with the `com.apple.security.hypervisor`
entitlement on every build (see `build.zig`). HVF only grants a VM to an entitled,
signed binary, so it must be run from a build (`zig build run`), never a bare
`zig run`.

## Building the guest payloads

The prebuilt guest artifacts are **not** committed (GPL guest images don't belong
in the repo). Generate them once with the scripts in `tools/`, which write into
`payloads/`:

```bash
tools/build-kernel.sh      # -> payloads/Image           (arm64 Linux kernel)
tools/build-initramfs.sh   # -> payloads/initramfs.cpio  (BusyBox rootfs)
tools/build-disk.sh        # -> payloads/disk.img         (ext4 virtio-blk backing store)
```

The kernel and BusyBox `.config` files used by those scripts are committed under
`payloads/` for reference.

`build-kernel.sh` does not build an arm64 `defconfig`. That config is a kernel
meant to boot every arm64 machine that exists — a 43 MB `Image`, 1100-odd modules,
and a boot spent probing for hardware this VMM does not have. The script starts
from it and then turns off every SoC platform, PCI, ACPI, EFI and modules, which
takes the `Image` to ~16 MB and its runtime footprint to ~17 MB. That is what
makes 64 MiB of guest RAM a comfortable fit rather than a tight one. The script's
comments say why each group goes, and `PLATFORMS=`/`DISABLE=`/`ENABLE=` override
any of it:

```bash
ENABLE="ARCH_APPLE" tools/build-kernel.sh   # put a platform back
```

Re-enable whatever a guest needs; the culls are a statement about what this VMM
currently emulates, not about what a guest may ever want.

## Running

```bash
zig build run
```

This compiles and signs the VMM, then boots the guest. Guest console output is
mirrored to the host. Run `poweroff` inside the guest shell to stop the VM.

## Testing

```bash
zig build test
```

The tests are pure logic — trap and register decoders, the FDT serializer, and the
device-servicing paths against fake vCPUs. They never call into HVF (the test binary
is unsigned, so any `hv_*` call would be denied), so they run anywhere Zig builds.

## Layout

| Path | What it is |
| --- | --- |
| `src/main.zig` | Entry point; sets up the machine and runs it. |
| `src/machine.zig` | The VM: RAM, vCPU loop, exit/trap dispatch, device wiring. |
| `src/hvf.zig` | Thin wrappers over Hypervisor.framework. |
| `src/vcpu.zig` | vCPU state and run/exit handling. |
| `src/gic.zig` | GICv3 setup and the architectural timer. |
| `src/device_tree.zig` | Builds the guest's device tree. |
| `src/boot_layout.zig`, `src/loader.zig` | Payload placement within RAM, and loading. |
| `src/platform.zig`, `src/bus.zig` | Memory map and MMIO bus. |
| `tools/` | Scripts that build the guest payloads. |

Everything reusable — the device models (UART, virtio-blk, virtio-console and the
virtio-mmio transport under them), the FDT serializer, the AArch64 decode tables,
PSCI, and the Linux boot protocol — lives in a separate package,
[virtual-platform](https://github.com/ozencozturk/virtual-platform), pulled in as
a Zig dependency and shared with this project's x86 VMM.

## License

[MIT](LICENSE). Note that the guest payloads you build with the `tools/` scripts
(the Linux kernel and BusyBox) are covered by their own licenses (GPL), not this one.

## Acknowledgements

Parts of this project were developed with assistance from AI coding tools
(Claude). All code was reviewed and is maintained by the author.
