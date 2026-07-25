const hvf = @import("hvf.zig");
const platform = @import("platform.zig");
const std = @import("std");

pub fn create() !void {
    try checkGeometry();

    const config = hvf.hv_gic_config_create() orelse return error.GicConfigCreateFailed;
    defer hvf.os_release(config);

    try hvf.check(hvf.hv_gic_config_set_distributor_base(config, platform.GICD_BASE));
    try hvf.check(hvf.hv_gic_config_set_redistributor_base(config, platform.GICR_BASE));

    try hvf.check(hvf.hv_gic_create(config));
}

fn checkGeometry() !void {
    var v: usize = undefined;
    try hvf.check(hvf.hv_gic_get_distributor_size(&v));
    if (v != platform.GICD_SIZE) {
        return error.GicdSizeMismatch;
    }

    try hvf.check(hvf.hv_gic_get_redistributor_size(&v));

    if (v != platform.GICR_STRIDE) {
        return error.GicrStrideMismatch;
    }

    // The invariant that keeps other devices out of the GIC: what we RESERVE in
    // the memory map must cover everything HVF actually reserves. Not an equality
    // check — a smaller region than we set aside is merely conservative and
    // harmless, whereas a larger one means HVF owns addresses our map hands to
    // some other device, and that device silently never gets reached.
    try hvf.check(hvf.hv_gic_get_redistributor_region_size(&v));
    if (v > platform.GICR_REGION_SIZE) {
        return error.GicrRegionLargerThanReserved;
    }

    // ...and the redistributors we describe to the guest must fit in HVF's region.
    if (platform.GICR_SIZE > v) {
        return error.GicrRegionTooSmall;
    }

    try hvf.check(hvf.hv_gic_get_distributor_base_alignment(&v));

    if (platform.GICD_BASE % v != 0) {
        return error.GicdBaseMisaligned;
    }

    try hvf.check(hvf.hv_gic_get_redistributor_base_alignment(&v));

    if (platform.GICR_BASE % v != 0) {
        return error.GicrBaseMisaligned;
    }

    var spi_base: u32 = undefined;
    var spi_count: u32 = undefined;
    try hvf.check(hvf.hv_gic_get_spi_interrupt_range(&spi_base, &spi_count));
    if (platform.UART_INTID < spi_base or platform.UART_INTID >= spi_base + spi_count) {
        return error.UartIntidOutOfSpiRange;
    }
    if (platform.VIRTIO_INTID < spi_base or platform.VIRTIO_INTID >= spi_base + spi_count) {
        return error.UartIntidOutOfSpiRange;
    }
}

/// Confirm HVF put this vCPU's redistributor where platform.zig promised it
/// would be — the address guest.dts hands the kernel as the GICR `reg` base.
///
/// Must run AFTER the vCPU exists and its MPIDR_EL1 affinity is set. That is not
/// an inconvenience, it is the point: hv_gic allocates a vCPU's redistributor
/// only once affinity is SET (a default of 0 is not the same as having set it),
/// so this doubles as the guard that setupVcpu still does that. Drop the MPIDR
/// write and this returns HV_BAD_ARGUMENT right here — instead of the guest
/// data-aborting at GICR_BASE+0xFFE8 (GICR_PIDR2, the first access
/// gic_populate_rdist makes) fifty log lines into the boot, with the distributor
/// working perfectly and everything looking fine. That cost a whole session once.
///
/// This cannot live in create(): that runs before any vCPU exists by
/// construction, which is exactly why checkGeometry() cannot catch this.
/// It is also the only test this file can have — every line here calls hv_*, so
/// the unsigned test binary can never reach it.
pub fn checkRedistributorBase(vcpu: hvf.hv_vcpu_t) !void {
    var base: hvf.hv_ipa_t = undefined;
    try hvf.check(hvf.hv_gic_get_redistributor_base(vcpu, &base));
    if (base != platform.GICR_BASE) return error.GicrBaseNotHonored;
}

/// One-shot dump of the geometry HVF reports. Nothing calls this — it is the
/// bring-up instrument, kept because Apple's geometry is not a contract: re-run
/// it whenever the host or macOS version changes, or when a GIC address stops
/// adding up.
pub fn dumpParameters() !void {
    var dist_size: usize = undefined;
    var dist_align: usize = undefined;
    var redist_size: usize = undefined;
    var region_size: usize = undefined;
    var redist_align: usize = undefined;
    var spi_base: u32 = undefined;
    var spi_count: u32 = undefined;
    var vtimer: u32 = undefined;
    var ptimer: u32 = undefined;
    try hvf.check(hvf.hv_gic_get_distributor_size(&dist_size));
    try hvf.check(hvf.hv_gic_get_distributor_base_alignment(&dist_align));
    try hvf.check(hvf.hv_gic_get_redistributor_size(&redist_size));
    try hvf.check(hvf.hv_gic_get_redistributor_region_size(&region_size));
    try hvf.check(hvf.hv_gic_get_redistributor_base_alignment(&redist_align));
    try hvf.check(hvf.hv_gic_get_spi_interrupt_range(&spi_base, &spi_count));
    try hvf.check(hvf.hv_gic_get_intid(.el1_virtual_timer, &vtimer));
    try hvf.check(hvf.hv_gic_get_intid(.el1_physical_timer, &ptimer));
    std.debug.print(
        \\gic: distributor   size 0x{x} align 0x{x}
        \\gic: redistributor size 0x{x}/cpu, region 0x{x}, align 0x{x}
        \\gic: SPI range {}..{}
        \\gic: vtimer intid {}, phys-timer intid {}
        \\
    , .{ dist_size, dist_align, redist_size, region_size, redist_align, spi_base, spi_base + spi_count, vtimer, ptimer });
}

// Nothing calls dumpParameters now, and Zig only analyzes decls something calls —
// so a signature drift in it would compile fine right up until the day you reach
// for it, which is by definition a day you are already debugging something else.
// refAllDecls type-checks every decl without CALLING any, so no hv_* runs and the
// unsigned test binary stays clear of HV_DENIED. Note this only type-checks: it
// does NOT prove the externs link (verified: it doesn't) — that is hvf.zig's job.
test {
    std.testing.refAllDecls(@This());
}
