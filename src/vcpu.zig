//! The vCPU seam. `Vcpu` is the *only* unit that touches Hypervisor.framework's
//! per-cpu API; all servicing logic in machine.zig is written against its shape
//! (run/getGpr/setGpr/advancePc/getPc) so a fake vCPU can stand in for tests.
//!
//! `zig build test` binaries are unsigned → any hv_* call returns HV_DENIED, so
//! this adapter is verified end-to-end by `zig build run`, not unit-tested.
//! Keep it thin. `Exit` is a NEUTRAL type (no HVF types) so the exit-servicing
//! logic — and, later, a recorded exit trace for deterministic replay — never
//! depends on Apple's structs.

const hvf = @import("hvf.zig");

/// Why the guest trapped back to the host. Neutral mirror of hv_exit_reason_t.
pub const Reason = enum { exception, vtimer, canceled, unknown };

/// A single vCPU exit, decoupled from hv_vcpu_exit_t.
pub const Exit = struct {
    reason: Reason,
    syndrome: u64 = 0, // ESR_ELx — valid on .exception
    physical_address: u64 = 0, // FAR — valid on .exception
};

/// Real vCPU: the thin Hypervisor.framework adapter.
pub const Vcpu = struct {
    id: hvf.hv_vcpu_t,
    exit: *hvf.hv_vcpu_exit_t,

    pub fn create() !Vcpu {
        var id: hvf.hv_vcpu_t = undefined;
        var exit_ptr: ?*hvf.hv_vcpu_exit_t = null;
        try hvf.check(hvf.hv_vcpu_create(&id, &exit_ptr, null));
        return .{ .id = id, .exit = exit_ptr.? };
    }

    pub fn deinit(self: *Vcpu) void {
        _ = hvf.hv_vcpu_destroy(self.id);
    }

    /// Set a named register (used for entry state: pc, cpsr).
    pub fn setReg(self: *Vcpu, reg: hvf.hv_reg_t, val: u64) !void {
        try hvf.check(hvf.hv_vcpu_set_reg(self.id, reg, val));
    }

    pub fn getPc(self: *Vcpu) !u64 {
        var pc: u64 = undefined;
        try hvf.check(hvf.hv_vcpu_get_reg(self.id, .pc, &pc));
        return pc;
    }

    /// Read a GPR by data-abort transfer-register number (SRT). 31 == XZR → 0,
    /// and must be handled here since hv_reg_t value 31 is PC, not a GPR.
    pub fn getGpr(self: *Vcpu, srt: u5) !u64 {
        if (srt == 31) return 0;
        var v: u64 = undefined;
        try hvf.check(hvf.hv_vcpu_get_reg(self.id, @enumFromInt(srt), &v));
        return v;
    }

    /// Write a GPR by SRT. 31 == XZR discards the write.
    pub fn setGpr(self: *Vcpu, srt: u5, val: u64) !void {
        if (srt == 31) return;
        try hvf.check(hvf.hv_vcpu_set_reg(self.id, @enumFromInt(srt), val));
    }
    pub fn setSysReg(self: *Vcpu, srt: hvf.hv_sys_reg_t, val: u64) !void {
        try hvf.check(hvf.hv_vcpu_set_sys_reg(self.id, srt, val));
    }

    pub fn advancePc(self: *Vcpu) !void {
        const pc = try self.getPc();
        try self.setReg(.pc, pc + 4);
    }

    /// Run until the next trap, returning a neutral Exit.
    pub fn run(self: *Vcpu) !Exit {
        try hvf.check(hvf.hv_vcpu_run(self.id));
        const e = self.exit;
        return switch (e.reason) {
            .exception => .{
                .reason = .exception,
                .syndrome = e.exception.syndrome,
                .physical_address = e.exception.physical_address,
            },
            .vtimer_activated => .{ .reason = .vtimer },
            .canceled => .{ .reason = .canceled },
            else => .{ .reason = .unknown },
        };
    }
};

/// Test double for the vCPU seam: a register file + a scripted exit queue.
/// Satisfies the same shape as `Vcpu`, so servicing logic runs against it
/// without Hypervisor.framework. This is also the shape a deterministic
/// exit-trace replay would take.
pub const FakeVcpu = struct {
    regs: [31]u64 = @splat(0), // x0..x30
    pc: u64 = 0,
    exits: []const Exit = &.{}, // scripted, popped in order by run()
    idx: usize = 0,

    pub fn run(self: *FakeVcpu) !Exit {
        if (self.idx >= self.exits.len) return error.NoMoreExits;
        defer self.idx += 1;
        return self.exits[self.idx];
    }
    pub fn getGpr(self: *FakeVcpu, srt: u5) !u64 {
        return if (srt == 31) 0 else self.regs[srt];
    }
    pub fn setGpr(self: *FakeVcpu, srt: u5, val: u64) !void {
        if (srt != 31) self.regs[srt] = val;
    }
    pub fn advancePc(self: *FakeVcpu) !void {
        self.pc += 4;
    }
    pub fn getPc(self: *FakeVcpu) !u64 {
        return self.pc;
    }
};
