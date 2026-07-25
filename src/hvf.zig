//! hvf.zig — hand-declared FFI to Apple's Hypervisor.framework (arm64).
//!
//! Why hand-declared and not @cImport / translate-c:
//!   - On this Zig (0.17-dev) the `@cImport` builtin has been REMOVED from the
//!     language entirely.
//!   - Even the `zig translate-c` CLI cannot parse the HVF umbrella header: it
//!     aborts on `uint64_t values[_Nonnull 8]` in hv_vcpu_config.h
//!     ("nullability specifier cannot be applied to non-pointer type").
//!   So the auto-path is not "churny" here, it's unavailable. The surface we
//!   need is ~11 functions; we declare them by hand.
//!
//! Every constant, signature, and struct layout below is transcribed from the
//! SDK headers on THIS machine and verified — never recalled, never guessed:
//!   $(xcrun --show-sdk-path)/System/Library/Frameworks/Hypervisor.framework/Headers/
//!     hv_vm.h  hv_vcpu.h  hv_vcpu_types.h  hv_vm_types.h  hv_types.h  hv_error.h
//! The comptime asserts at the bottom turn any layout mistake into a build
//! failure instead of a runtime guest crash.

const std = @import("std");

// --- Scalar typedefs -------------------------------------------------------
// hv_error.h:   typedef mach_error_t hv_return_t;   (mach_error_t == int)
pub const hv_return_t = c_int;
// hv_vcpu_types.h: typedef uint64_t hv_vcpu_t;
pub const hv_vcpu_t = u64;
// hv_vm_types.h:   typedef uint64_t hv_ipa_t;
pub const hv_ipa_t = u64; // intermediate physical address
// hv_vm_types.h:   typedef uint64_t hv_memory_flags_t;
pub const hv_memory_flags_t = u64;
// hv_vcpu_types.h: typedef uint64_t hv_exception_syndrome_t;  (ESR_ELx)
pub const hv_exception_syndrome_t = u64;
// hv_vcpu_types.h: typedef uint64_t hv_exception_address_t;   (FAR_ELx)
pub const hv_exception_address_t = u64;

// Opaque OS-object config handles. We never inspect their fields; passing null
// selects the default configuration. hv_vm.h / hv_vcpu.h / hv_vcpu_types.h.
pub const hv_vm_config_t = ?*anyopaque;
pub const hv_vcpu_config_t = ?*anyopaque;

// --- Memory protection flags (hv_types.h) ----------------------------------
pub const HV_MEMORY_READ: hv_memory_flags_t = 1 << 0;
pub const HV_MEMORY_WRITE: hv_memory_flags_t = 1 << 1;
pub const HV_MEMORY_EXEC: hv_memory_flags_t = 1 << 2;

// --- hv_exit_reason_t (hv_vcpu_types.h: OS_ENUM(..., uint32_t, ...)) --------
// Non-exhaustive (`_`) so an unexpected value from HVF is representable rather
// than illegal behavior on cast; the exit switch can then log and bail on it.
pub const hv_exit_reason_t = enum(u32) {
    canceled = 0,
    exception = 1,
    vtimer_activated = 2,
    unknown = 3,
    _,
};

// --- hv_reg_t (hv_vcpu_types.h: OS_ENUM(..., uint32_t, ...)) ----------------
// FP is an alias of X29 and LR an alias of X30 in the header (they do not
// consume enum values), so PC lands at 31. Exposed as decls below.
pub const hv_reg_t = enum(u32) {
    x0 = 0,
    x1 = 1,
    x2 = 2,
    x3 = 3,
    x4 = 4,
    x5 = 5,
    x6 = 6,
    x7 = 7,
    x8 = 8,
    x9 = 9,
    x10 = 10,
    x11 = 11,
    x12 = 12,
    x13 = 13,
    x14 = 14,
    x15 = 15,
    x16 = 16,
    x17 = 17,
    x18 = 18,
    x19 = 19,
    x20 = 20,
    x21 = 21,
    x22 = 22,
    x23 = 23,
    x24 = 24,
    x25 = 25,
    x26 = 26,
    x27 = 27,
    x28 = 28,
    x29 = 29,
    x30 = 30,
    pc = 31,
    fpcr = 32,
    fpsr = 33,
    cpsr = 34,

    pub const fp: hv_reg_t = .x29; // HV_REG_FP = HV_REG_X29
    pub const lr: hv_reg_t = .x30; // HV_REG_LR = HV_REG_X30
};

// --- hv_sys_reg_t (hv_vcpu_types.h: OS_ENUM(..., uint16_t, ...)) ------------
// The full header enum is ~150 entries. We mirror a verified subset and mark the
// enum non-exhaustive, so any other encoded reg id from the header can still be
// passed via @enumFromInt without extending this list. All values below are
// copied from the header.
pub const hv_sys_reg_t = enum(u16) {
    MIDR_EL1 = 0xc000,
    MPIDR_EL1 = 0xc005,
    SCTLR_EL1 = 0xc080,
    CPACR_EL1 = 0xc082,
    TTBR0_EL1 = 0xc100,
    TTBR1_EL1 = 0xc101,
    TCR_EL1 = 0xc102,
    SPSR_EL1 = 0xc200,
    ELR_EL1 = 0xc201,
    SP_EL0 = 0xc208,
    ESR_EL1 = 0xc290,
    FAR_EL1 = 0xc300,
    MAIR_EL1 = 0xc510,
    VBAR_EL1 = 0xc600,
    SP_EL1 = 0xe208,
    _,
};

// --- GIC types (hv_gic_types.h / hv_vcpu_types.h) ---------------------------
// hv_gic_types.h: typedef struct hv_gic_config_s *hv_gic_config_t;
// Unlike the config handles above, this one is NOT nullable-means-default: it is
// an os_object, created retained by hv_gic_config_create and released with
// os_release (declared below) — never freed.
pub const hv_gic_config_t = ?*anyopaque;

// hv_gic_types.h: OS_ENUM(hv_gic_intid, uint16_t, ...)
// Interrupts RESERVED BY THE FRAMEWORK. That word is why vmm never injects the
// vtimer PPI itself: HVF's GIC owns intid 27 and wires the timer to it
// internally. (maintenance/el2_physical_timer exist only when EL2 is enabled.)
pub const hv_gic_intid_t = enum(u16) {
    performance_monitor = 23,
    maintenance = 25,
    el2_physical_timer = 26,
    el1_virtual_timer = 27,
    el1_physical_timer = 30,
    _,
};

// hv_vcpu_types.h: OS_ENUM(hv_interrupt_type, uint32_t, ...)
pub const hv_interrupt_type_t = enum(u32) {
    irq = 0,
    fiq = 1,
    _,
};

// --- Exit structs (hv_vcpu_types.h) ----------------------------------------
// extern struct reproduces the C layout, including the 4 bytes of padding the
// compiler inserts after `reason` to 8-align `exception`. Verified below.
pub const hv_vcpu_exit_exception_t = extern struct {
    syndrome: hv_exception_syndrome_t,
    virtual_address: hv_exception_address_t,
    physical_address: hv_ipa_t,
};

pub const hv_vcpu_exit_t = extern struct {
    reason: hv_exit_reason_t,
    exception: hv_vcpu_exit_exception_t,
};

// --- Externs ---------------------------------------------------------------
// hv_vm.h
pub extern "c" fn hv_vm_create(config: hv_vm_config_t) hv_return_t;
pub extern "c" fn hv_vm_destroy() hv_return_t;
pub extern "c" fn hv_vm_map(addr: *anyopaque, ipa: hv_ipa_t, size: usize, flags: hv_memory_flags_t) hv_return_t;
pub extern "c" fn hv_vm_unmap(ipa: hv_ipa_t, size: usize) hv_return_t;
// hv_vcpu.h
// create: (hv_vcpu_t *vcpu, hv_vcpu_exit_t * _Nullable * _Nonnull exit, hv_vcpu_config_t _Nullable config)
pub extern "c" fn hv_vcpu_create(vcpu: *hv_vcpu_t, exit: *?*hv_vcpu_exit_t, config: hv_vcpu_config_t) hv_return_t;
pub extern "c" fn hv_vcpu_destroy(vcpu: hv_vcpu_t) hv_return_t;
pub extern "c" fn hv_vcpu_run(vcpu: hv_vcpu_t) hv_return_t;
pub extern "c" fn hv_vcpu_get_reg(vcpu: hv_vcpu_t, reg: hv_reg_t, value: *u64) hv_return_t;
pub extern "c" fn hv_vcpu_set_reg(vcpu: hv_vcpu_t, reg: hv_reg_t, value: u64) hv_return_t;
pub extern "c" fn hv_vcpu_get_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: *u64) hv_return_t;
pub extern "c" fn hv_vcpu_set_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: u64) hv_return_t;
// The vtimer/IRQ-injection pair. Declared but UNUSED: with the in-HVF GIC, HVF
// wires the vtimer to its reserved intid itself, so we expect no .vtimer exits
// and inject nothing. They are here so that, if that turns out to be wrong, the
// fix is a machine.zig change and not an FFI archaeology session.
// Note `kind:` — a parameter named `type` would shadow the primitive.
pub extern "c" fn hv_vcpu_set_pending_interrupt(vcpu: hv_vcpu_t, kind: hv_interrupt_type_t, pending: bool) hv_return_t;
pub extern "c" fn hv_vcpu_set_vtimer_mask(vcpu: hv_vcpu_t, vtimer_is_masked: bool) hv_return_t;

// hv_gic_config.h — build the config, then hand it to hv_gic_create.
pub extern "c" fn hv_gic_config_create() hv_gic_config_t;
pub extern "c" fn hv_gic_config_set_distributor_base(config: hv_gic_config_t, base: hv_ipa_t) hv_return_t;
pub extern "c" fn hv_gic_config_set_redistributor_base(config: hv_gic_config_t, base: hv_ipa_t) hv_return_t;

// hv_gic.h
// create: must run AFTER hv_vm_create and BEFORE any vCPU exists — it allocates
// the per-CPU GIC system-register state. There is no destroy counterpart;
// hv_vm_destroy reclaims the GIC.
pub extern "c" fn hv_gic_create(gic_config: hv_gic_config_t) hv_return_t;
pub extern "c" fn hv_gic_set_spi(intid: u32, level: bool) hv_return_t;
pub extern "c" fn hv_gic_reset() hv_return_t;
pub extern "c" fn hv_gic_get_redistributor_base(vcpu: hv_vcpu_t, base: *hv_ipa_t) hv_return_t;

// hv_gic_parameters.h — the geometry HVF will actually install. None of these
// exist at comptime, which is why platform.zig's claims get checked at startup.
pub extern "c" fn hv_gic_get_distributor_size(size: *usize) hv_return_t;
pub extern "c" fn hv_gic_get_distributor_base_alignment(alignment: *usize) hv_return_t;
pub extern "c" fn hv_gic_get_redistributor_size(size: *usize) hv_return_t;
pub extern "c" fn hv_gic_get_redistributor_region_size(size: *usize) hv_return_t;
pub extern "c" fn hv_gic_get_redistributor_base_alignment(alignment: *usize) hv_return_t;
pub extern "c" fn hv_gic_get_spi_interrupt_range(intid_base: *u32, intid_count: *u32) hv_return_t;
pub extern "c" fn hv_gic_get_intid(interrupt: hv_gic_intid_t, intid: *u32) hv_return_t;

// os/object.h: OS_EXPORT void os_release(void *object);
// A real exported C function on the non-ObjC path (which is what Zig links
// against); it is only an [obj release] macro under OS_OBJECT_USE_OBJC. Lives in
// libSystem, not Hypervisor.framework.
pub extern "c" fn os_release(object: *anyopaque) void;

// --- Zig-side error wrapper ------------------------------------------------
// hv_error.h values (err_common_hypervisor | n). HV_SUCCESS == 0.
pub const HV_SUCCESS: hv_return_t = 0;

pub const HvError = error{
    Error,
    Busy,
    BadArgument,
    NoResources,
    NoDevice,
    Denied,
    Fault,
    Unsupported,
    Unknown,
};

/// Human-readable name for an hv_return_t, for logging.
pub fn retName(ret: hv_return_t) []const u8 {
    return switch (@as(u32, @bitCast(ret))) {
        0x0 => "HV_SUCCESS",
        0xfae94001 => "HV_ERROR",
        0xfae94002 => "HV_BUSY",
        0xfae94003 => "HV_BAD_ARGUMENT",
        0xfae94005 => "HV_NO_RESOURCES",
        0xfae94006 => "HV_NO_DEVICE",
        0xfae94007 => "HV_DENIED",
        0xfae94008 => "HV_FAULT",
        0xfae9400f => "HV_UNSUPPORTED",
        else => "HV_UNKNOWN",
    };
}

/// Map an hv_return_t to a Zig error. Pure — no logging, no side effects.
pub fn toError(ret: hv_return_t) HvError!void {
    if (ret == HV_SUCCESS) return;
    return switch (@as(u32, @bitCast(ret))) {
        0xfae94001 => error.Error,
        0xfae94002 => error.Busy,
        0xfae94003 => error.BadArgument,
        0xfae94005 => error.NoResources,
        0xfae94006 => error.NoDevice,
        0xfae94007 => error.Denied,
        0xfae94008 => error.Fault,
        0xfae9400f => error.Unsupported,
        else => error.Unknown,
    };
}

/// toError, plus a log line naming the raw code — the error set alone cannot
/// carry it. This is what call sites use; the split exists because the mapping
/// is worth testing and the logging is not (a test that logs at .err fails the
/// build, so the two cannot be exercised together).
pub fn check(ret: hv_return_t) HvError!void {
    toError(ret) catch |e| {
        std.log.err("HVF call failed: {s} (0x{x:0>8})", .{ retName(ret), @as(u32, @bitCast(ret)) });
        return e;
    };
}

// --- tests -----------------------------------------------------------------
// check/retName touch no hv_* call, so unlike the rest of this file they run
// fine in the unsigned test binary.

const testing = std.testing;

// Every documented hv_error.h code, with the name and error it must decode to.
// retName and toError switch over these independently, so walking one table
// against both also catches the two drifting apart.
const documented = [_]struct { code: u32, name: []const u8, err: HvError }{
    .{ .code = 0xfae94001, .name = "HV_ERROR", .err = error.Error },
    .{ .code = 0xfae94002, .name = "HV_BUSY", .err = error.Busy },
    .{ .code = 0xfae94003, .name = "HV_BAD_ARGUMENT", .err = error.BadArgument },
    .{ .code = 0xfae94005, .name = "HV_NO_RESOURCES", .err = error.NoResources },
    .{ .code = 0xfae94006, .name = "HV_NO_DEVICE", .err = error.NoDevice },
    .{ .code = 0xfae94007, .name = "HV_DENIED", .err = error.Denied },
    .{ .code = 0xfae94008, .name = "HV_FAULT", .err = error.Fault },
    .{ .code = 0xfae9400f, .name = "HV_UNSUPPORTED", .err = error.Unsupported },
};

// Every extern here is a symbol name typed by hand from a header, and an extern
// nothing CALLS is an extern the linker never has to resolve — so `zig build`
// stays green over a misspelled one until the day it is first used. Most of the
// GIC surface is uncalled today, which is exactly when a transcription typo is
// cheapest to catch and hardest to notice.
//
// refAllDecls is NOT enough here (verified: a deliberately misspelled extern
// still builds clean under it) — discarding a function reference folds away
// before it becomes a relocation. Taking each function's ADDRESS is what forces
// the linker to actually find the symbol, since a pointer to it cannot exist
// otherwise. Still never CALLS anything, so the unsigned test binary stays clear
// of HV_DENIED.
test "every declared extern resolves at link time" {
    var sink: usize = 0;
    inline for (comptime std.meta.declarations(@This())) |name| {
        const decl = @field(@This(), name);
        if (@typeInfo(@TypeOf(decl)) == .@"fn") sink +%= @intFromPtr(&decl);
    }
    try testing.expect(sink != 0); // the addresses are link-time, not comptime
}

test "toError: HV_SUCCESS is not an error" {
    try toError(HV_SUCCESS);
}

test "toError: every documented code maps to its own error" {
    for (documented) |d| try testing.expectError(d.err, toError(@bitCast(d.code)));
}

test "toError: an undocumented code is reported, not misread as success" {
    try testing.expectError(error.Unknown, toError(@bitCast(@as(u32, 0xfae940ff))));
}

// check's happy path only: its failure path logs at .err, which fails the test
// build by design. The mapping it delegates to is covered by the toError tests.
test "check: HV_SUCCESS is not an error" {
    try check(HV_SUCCESS);
}

test "retName: names every documented code" {
    try testing.expectEqualStrings("HV_SUCCESS", retName(HV_SUCCESS));
    for (documented) |d| try testing.expectEqualStrings(d.name, retName(@bitCast(d.code)));
    try testing.expectEqualStrings("HV_UNKNOWN", retName(@bitCast(@as(u32, 0xfae940ff))));
}

// --- Layout verification ---------------------------------------------------
// These structs are transcribed by hand from C headers, so a mistake in any
// field type or order is invisible until the guest corrupts itself. Asserting
// the layout at build time turns that into a compile error instead.
comptime {
    // Exit exception: three u64s, tightly packed.
    std.debug.assert(@sizeOf(hv_vcpu_exit_exception_t) == 24);
    std.debug.assert(@offsetOf(hv_vcpu_exit_exception_t, "syndrome") == 0);
    std.debug.assert(@offsetOf(hv_vcpu_exit_exception_t, "virtual_address") == 8);
    std.debug.assert(@offsetOf(hv_vcpu_exit_exception_t, "physical_address") == 16);

    // Exit: u32 reason + 4 pad + 24-byte exception at offset 8 => 32 total.
    std.debug.assert(@sizeOf(hv_vcpu_exit_t) == 32);
    std.debug.assert(@offsetOf(hv_vcpu_exit_t, "reason") == 0);
    std.debug.assert(@offsetOf(hv_vcpu_exit_t, "exception") == 8);

    // Enum backing widths match the header's OS_ENUM tag types.
    std.debug.assert(@sizeOf(hv_exit_reason_t) == 4);
    std.debug.assert(@sizeOf(hv_reg_t) == 4);
    std.debug.assert(@sizeOf(hv_sys_reg_t) == 2);

    // Spot-check a couple of transcribed enum values against the header.
    std.debug.assert(@intFromEnum(hv_reg_t.cpsr) == 34);
    std.debug.assert(@intFromEnum(hv_reg_t.pc) == 31);
    std.debug.assert(hv_reg_t.fp == .x29 and hv_reg_t.lr == .x30);
    std.debug.assert(@intFromEnum(hv_sys_reg_t.SCTLR_EL1) == 0xc080);

    // GIC enum widths match the header's OS_ENUM tag types.
    std.debug.assert(@sizeOf(hv_gic_intid_t) == 2);
    std.debug.assert(@sizeOf(hv_interrupt_type_t) == 4);

    // The one intid the whole timer story hangs on: DT PPI 11 == intid 27, and
    // an off-by-16 between those two numbering schemes compiles, loads, and hangs.
    std.debug.assert(@intFromEnum(hv_gic_intid_t.el1_virtual_timer) == 27);
}
