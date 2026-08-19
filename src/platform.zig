const std = @import("std");
const devices = @import("virtual_devices");
pub const Ipa = u64;
pub const RAM_BASE: Ipa = 0x8000_0000; // 2 GiB
pub const MiB = 1024 * 1024;
pub const PAGE = 16 * 1024; // Apple Silicon = 16 KiB pages (hv_vm_map alignment unit)
// 64 MiB, matching the x86 side of this project. The guest is a probe, not an
// environment: a slim kernel (payloads/kernel.config, built by tools/build-kernel.sh)
// with a ~17 MiB footprint and a BusyBox initramfs leave most of this free. A
// guest that needs more is a reason to raise this, not evidence it is wrong.
pub const RAM_SIZE: usize = 64 * MiB; // 0x0400_0000

pub const SPI_BASE: u32 = 32;
pub const UART_SPI: u32 = 1;
pub const UART_INTID: u32 = SPI_BASE + UART_SPI;

pub const VIRTIO_SPI: u32 = 2;
pub const VIRTIO_INTID: u32 = SPI_BASE + VIRTIO_SPI;
pub const VIRTIO_SIZE = devices.VirtioBlk.MMIO_SIZE;

pub const VCONSOLE_SPI: u32 = 3;
pub const VCONSOLE_INTID: u32 = SPI_BASE + VCONSOLE_SPI;
pub const VCONSOLE_SIZE = devices.VirtioConsole.MMIO_SIZE;
// ---- Platform memory map — SINGLE SOURCE OF TRUTH -------------------------
// The device tree handed to the guest, the interrupt-controller config, and the
// loader/stage-2 map all derive from these constants. A disagreement between any
// two of those is a silent-hang bug: the guest addresses one thing, the host
// services another, and nothing reports a fault.

pub const nCPU = 1; // raising this needs a thread per vCPU and per-CPU GICR frames

/// An MMIO device hole. Every hole below is unmapped in stage-2, so a guest
/// access to one FAULTS out of the guest. What differs between the two groups is
/// only WHO is there to service that fault — see each group's comment.
pub const Region = struct { base: Ipa, size: usize, device: ?Device = null };

// ---- Holes Hypervisor.framework services ----------------------------------
// Unmapped exactly like the holes below: we hand hv_gic_create() nothing but an
// IPA, and there is no host memory behind these. Nor could there be — a store to
// GICD_ISPENDR must make an interrupt PENDING, which memory cannot do. So a GICD
// is trapped and modelled like any MMIO; the only question is by whom.
//
// The answer is Apple. A guest access here faults out of the guest just as a UART
// store does, but the framework sits underneath, recognises the address, services
// it in its own GICv3 model, and re-enters the guest — hv_vcpu_run never returns.
// The exit is invisible to us, which is what "in-HVF GIC" actually means.
//
// Corollary worth remembering at 2am: a data abort with a fault PA in here does
// NOT mean "missing device model". It means hv_gic_create() never ran or failed.
//
// Sizes and alignments are HVF's to dictate, and none of them exist at comptime —
// gic.checkGeometry() confirms these claims against the framework at startup.
pub const GICD_BASE: Ipa = 0x0800_0000; // GICv3 distributor
pub const GICD_SIZE: usize = 0x1_0000; // 64 KiB      == hv_gic_get_distributor_size()
pub const GICR_BASE: Ipa = 0x0808_0000; // GICv3 redistributors
pub const GICR_STRIDE: usize = 0x2_0000; // 128 KiB/CPU = 2 * 64 KiB frames (RD + SGI)

/// What the GUEST is told to walk: one redistributor per vCPU we actually create.
/// This is the GICR `reg` size in guest.dts, and the kernel stops early anyway —
/// it walks until the Last bit in GICR_TYPER. Scales with nCPU; GICD_SIZE doesn't.
pub const GICR_SIZE: usize = GICR_STRIDE * nCPU;

/// What HVF RESERVES at GICR_BASE, which is a different question and the one the
/// memory map cares about: room for every vCPU the FRAMEWORK supports (256 here
/// => 32 MiB), not the nCPU we chose to create. hv_gic_config.h is explicit —
/// "the redistributor region will contain redistributors for all vCPUs supported
/// by the virtual machine."
///
/// Sizing the map off GICR_SIZE (128 KiB) instead is a real bug that already bit:
/// it left VIRTIO_BASE sitting INSIDE the GIC's region, where HVF owns the
/// addresses and a virtio device would simply never be reached. The comptime
/// asserts below could not see it, because they check our claims against each
/// other and this is a claim about someone else's device — which is exactly why
/// gic.checkGeometry() re-checks it against the framework at startup.
pub const GICR_REGION_SIZE: usize = 0x200_0000; // 32 MiB; >= hv_gic_get_redistributor_region_size()

// ---- Holes vmm services ----------------------------------------------------
// Same stage-2 state as the GIC holes above — unmapped, and a guest access
// faults. HVF has no model for these addresses, so it hands the exit back:
// hv_vcpu_run returns a data abort and serviceDataAbort emulates it by hand.
pub const UART_BASE: Ipa = 0x1000_0000; // ns16550a
pub const UART_SIZE: usize = devices.Uart.UART_SIZE;

// virtio-mmio slot 0. NOT at QEMU virt's 0x0a00_0000, which is where this
// started: QEMU packs its redistributor region to end exactly at 0x0a00_0000,
// but HVF reserves 32 MiB from GICR_BASE and runs to 0x0a08_0000 — so the QEMU
// address lands inside the GIC. Moved clear of GICR_REGION_SIZE's end, still well
// below the UART, leaving 64 MiB of slot space.
pub const VIRTIO_BASE: Ipa = 0x0c00_0000;

// virtio-mmio slot 1, immediately above the block device's window.
pub const VCONSOLE_BASE: Ipa = VIRTIO_BASE + VIRTIO_SIZE;

// Poweroff register: a store here halts the machine. Not modelled on real
// hardware — it is the halt mechanism for hand-written test blobs, which have no
// firmware to call. A kernel guest powers off via PSCI and never touches this.
pub const POWEROFF_BASE: Ipa = 0x0010_0000;
pub const POWEROFF_SIZE: usize = 8; // one doubleword store; serviceDataAbort matches the base

// RAM: the only region hv_vm_map's; guest executes/reads/writes natively.

/// Holes the framework services. Split out from `emulated` to record who handles
/// a fault here — a distinction no assert can check, but the first thing to know
/// when a fault PA lands in one of these.
pub const hvf_owned = [_]Region{
    .{ .base = GICD_BASE, .size = GICD_SIZE },
    // GICR_REGION_SIZE, not GICR_SIZE: what must be kept clear is everything HVF
    // reserves, not the part this nCPU happens to use. See GICR_REGION_SIZE.
    .{ .base = GICR_BASE, .size = GICR_REGION_SIZE },
};

pub const Device = enum { uart, virtio, vconsole, poweroff };
/// Holes vmm services: every one of these must have a branch in serviceDataAbort.
pub const emulated = [_]Region{
    .{ .base = UART_BASE, .size = UART_SIZE, .device = .uart },
    .{ .base = VIRTIO_BASE, .size = VIRTIO_SIZE, .device = .virtio },
    .{ .base = VCONSOLE_BASE, .size = VCONSOLE_SIZE, .device = .vconsole },
    .{ .base = POWEROFF_BASE, .size = POWEROFF_SIZE, .device = .poweroff },
};

comptime {
    // The hvf_owned/emulated split records WHO services a fault, which is not
    // something an assert can see. What IS checkable is what both kinds share, and
    // it is unchanged: every hole must fall BELOW RAM (so a stray access can never
    // silently hit guest memory instead of faulting)...
    const all = hvf_owned ++ emulated;
    for (all) |h| std.debug.assert(h.base + h.size <= RAM_BASE);
    // ...and be disjoint from every other hole.
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| {
        std.debug.assert(a.base + a.size <= b.base or b.base + b.size <= a.base);
    };
}

comptime {
    // The redistributors we hand the guest must fit inside what HVF reserves for
    // them. Raising nCPU past what the region holds is the way this breaks.
    std.debug.assert(GICR_SIZE <= GICR_REGION_SIZE);
}

comptime {

    // stage-2 mapping unit
    std.debug.assert(RAM_BASE % PAGE == 0);
    std.debug.assert(RAM_SIZE % PAGE == 0);
}
