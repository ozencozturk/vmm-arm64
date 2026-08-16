const std = @import("std");
const hvf = @import("hvf.zig");
const gic = @import("gic.zig");
const arm = @import("arm.zig");
const psci = @import("psci.zig");
const SysRegIss = arm.SysRegIss;
const devices = @import("devices");
const bus = @import("bus.zig");
const Vcpu = @import("vcpu.zig").Vcpu;
const Exit = @import("vcpu.zig").Exit;
const Pstate = arm.Pstate;
const Esr = arm.Esr;
const DataAbortIss = arm.DataAbortIss;
const boot = @import("linux_boot.zig");
const platform = @import("platform.zig");
const RAM_BASE = @import("platform.zig").RAM_BASE;
const PAGE = @import("platform.zig").PAGE;
const RAM_SIZE = @import("platform.zig").RAM_SIZE;
const POWEROFF_BASE = @import("platform.zig").POWEROFF_BASE;
const UART_BASE = @import("platform.zig").UART_BASE;

// virtio-mmio QueueNotify. The package's `Reg` enum is private, so the offset is
// restated here; vconsole.zig:37 is the source of truth.
const QUEUE_NOTIFY: usize = 0x050;

pub const Machine = struct {
    ram: []align(std.heap.page_size_min) u8,
    vcpu: Vcpu,
    uart: devices.Uart = .{},
    virtio: devices.Virtio = .{},
    vconsole: devices.VirtioConsole = .{},
    out: *std.Io.Writer, // where captured guest console TX is mirrored
    fault: ?Fault = null,
    uart_lock: std.atomic.Mutex = .unlocked,

    fn lockUart(self: *Machine) void {
        while (!self.uart_lock.tryLock()) std.atomic.spinLoopHint();
    }
    /// Allocate host-anonymous guest RAM and stage-2 map it at RAM_BASE (RWX).
    fn mapGuestRam() ![]align(std.heap.page_size_min) u8 {
        const ram = try std.posix.mmap(
            null,
            RAM_SIZE,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer std.posix.munmap(ram); // covers a hv_vm_map failure below
        std.debug.assert(@intFromPtr(ram.ptr) % PAGE == 0);
        try hvf.check(hvf.hv_vm_map(
            @ptrCast(ram.ptr),
            RAM_BASE,
            RAM_SIZE,
            hvf.HV_MEMORY_READ | hvf.HV_MEMORY_WRITE | hvf.HV_MEMORY_EXEC,
        ));
        return ram;
    }

    fn mapDisk(io: std.Io, dir: std.Io.Dir) ![]align(std.heap.page_size_min) u8 {
        const f = try dir.openFile(io, "payloads/disk.img", .{ .mode = .read_write });
        defer f.close(io);
        const size: usize = @intCast((try f.stat(io)).size);
        return std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, f.handle, 0);
    }

    /// Create a vCPU in the AArch64 reset/boot state: entry at `pc`, `x0` as the
    /// boot protocol requires (a device-tree pointer, or 0 for a guest that takes
    /// no argument), x1..x3 zeroed, EL1h with DAIF masked. The MMU is off at reset.
    fn setupVcpu(pc: hvf.hv_ipa_t, x0: u64) !Vcpu {
        var cpu = try Vcpu.create();
        errdefer cpu.deinit();
        try cpu.setGpr(0, x0);
        try cpu.setGpr(1, 0);
        try cpu.setGpr(2, 0);
        try cpu.setGpr(3, 0);
        try cpu.setReg(.pc, pc);
        try cpu.setReg(.cpsr, (Pstate{}).toBits());
        try cpu.setSysReg(.MPIDR_EL1, 0x8000_0000);
        return cpu;
    }

    pub fn init(io: std.Io, out: *std.Io.Writer) !Machine {
        try hvf.check(hvf.hv_vm_create(null));
        errdefer _ = hvf.hv_vm_destroy();

        try gic.create();
        const ram = try mapGuestRam();
        errdefer std.posix.munmap(ram);

        const dir: std.Io.Dir = .cwd();

        const disk = try mapDisk(io, dir);
        errdefer std.posix.munmap(disk);
        const p = try boot.loadPayloads(io, dir, ram);
        std.debug.print("loaded: Image {} B (image_size 0x{x}), initrd {} B, dtb {} B\n", .{ p.kernel_len, p.image_size, p.initrd_len, p.dtb_len });

        var cpu = try setupVcpu(boot.KERNEL_IPA, boot.DTB_IPA); // x0 = device tree
        errdefer cpu.deinit();

        // Only possible now the vCPU exists with its affinity set — see the fn.
        try gic.checkRedistributorBase(cpu.id);

        return .{
            .ram = ram,
            .vcpu = cpu,
            .out = out,
            .virtio = .{ .disk = disk },
            .vconsole = .{ .out = .{ .ctx = out, .write = &writeConsole } },
        };
    }

    /// Boot a raw hand-written blob at the base of RAM, for running small test
    /// programs natively without a kernel image or a device tree.
    pub fn initBlob(blob: []const u8, out: *std.Io.Writer) !Machine {
        try hvf.check(hvf.hv_vm_create(null));
        errdefer _ = hvf.hv_vm_destroy();
        const ram = try mapGuestRam();
        errdefer std.posix.munmap(ram);
        @memcpy(ram[0..blob.len], blob);

        var cpu = try setupVcpu(RAM_BASE, 0); // x0 unused for a bare blob
        errdefer cpu.deinit();
        return .{ .ram = ram, .vcpu = cpu, .out = out };
    }

    pub fn run(self: *Machine) !void {
        const irq = HvfIrq{};
        const tty: ?RawTty = RawTty.enable(0) catch null;
        defer if (tty) |t| t.restore();

        const t = try std.Thread.spawn(.{}, inputLoop, .{ self, irq });
        t.detach();
        const exits = try self.runOn(&self.vcpu, irq);
        std.debug.print("guest halted via poweroff after {} exits \n", .{exits});
    }
    fn syncVirtioIrq(self: *Machine, irq: anytype) void {
        irq.setVirtio(self.virtio.irqAsserted());
    }
    fn syncVconsoleIrq(self: *Machine, irq: anytype) void {
        irq.setVconsole(self.vconsole.irqAsserted());
    }
    // The exit/resume loop, generic over the vCPU seam so a fake can drive it.
    // Returns the exit count once the guest powers off.
    fn runOn(self: *Machine, cpu: anytype, irq: anytype) !u64 {
        var exits: u64 = 0;
        while (true) {
            const exit = try cpu.run();
            exits += 1;
            const stop = try self.handleExit(cpu, exit);
            lockUart(self);
            self.syncUartIrq(irq);
            self.vconsole.serviceRx(self.ram, RAM_BASE);
            self.uart_lock.unlock();
            self.syncVirtioIrq(irq);
            self.syncVconsoleIrq(irq);
            if (stop) {
                break;
            }
        }
        return exits;
    }

    // Exit dispatch — generic over the vCPU seam (`cpu: anytype`) so a fake vCPU
    // can drive it in tests without Hypervisor.framework. Returns true to stop.
    fn handleExit(self: *Machine, cpu: anytype, exit: Exit) !bool {
        if (exit.reason != .exception)
            return self.fail(cpu, exit, "unexpected exit reason");

        const esr = Esr.fromBits(exit.syndrome);
        return switch (esr.ec) {
            .data_abort_lower => self.serviceDataAbort(cpu, exit),
            .msr_mrs => self.serviceSysReg(cpu, exit),
            .hvc => psci.handle(cpu),
            else => self.fail(cpu, exit, "unexpected EC"),
        };
    }

    fn serviceSysReg(self: *Machine, cpu: anytype, exit: Exit) !bool {
        const esr = Esr.fromBits(exit.syndrome);
        const iss = SysRegIss.fromBits(esr.iss);

        switch (iss.id()) {
            .OSDLR_EL1, .OSLAR_EL1 => {
                if (iss.direction == .read) {
                    return self.fail(cpu, exit, "read of an OS-lock reg vmm models no state for");
                }
            },
            else => return self.fail(cpu, exit, "unhandled trap sys register"),
        }
        try cpu.advancePc();
        return false;
    }

    fn serviceUart(self: *Machine, cpu: anytype, offset: usize, iss: DataAbortIss) !void {
        if (iss.isWrite()) {
            {
                self.lockUart();
                defer self.uart_lock.unlock();
                try self.uart.store(offset, iss.size(), try cpu.getGpr(iss.srt));
            }
            self.drainUart();
        } else {
            self.lockUart();
            defer self.uart_lock.unlock();
            try cpu.setGpr(iss.srt, try self.uart.load(offset, iss.size()));
        }
    }
    fn serviceVconsole(self: *Machine, cpu: anytype, offset: usize, iss: DataAbortIss) !void {
        if (iss.isWrite()) {
            const value = try cpu.getGpr(iss.srt);
            try self.vconsole.store(offset, iss.size(), value);
            if (offset == QUEUE_NOTIFY) {
                self.lockUart();
                defer self.uart_lock.unlock();
                self.vconsole.notify(@truncate(value), self.ram, RAM_BASE);
            }
        } else {
            try cpu.setGpr(iss.srt, try self.vconsole.load(offset, iss.size()));
        }
    }
    fn serviceVirtio(self: *Machine, cpu: anytype, offset: usize, iss: DataAbortIss) !void {
        if (iss.isWrite()) {
            try self.virtio.store(offset, iss.size(), try cpu.getGpr(iss.srt));
            if (self.virtio.notify_pending) {
                self.virtio.process(self.ram, RAM_BASE);
                self.virtio.notify_pending = false;
            }
        } else {
            try cpu.setGpr(iss.srt, try self.virtio.load(offset, iss.size()));
        }
    }

    fn serviceDataAbort(self: *Machine, cpu: anytype, exit: Exit) !bool {
        const esr = Esr.fromBits(exit.syndrome);
        const iss = DataAbortIss.fromBits(esr.iss);
        // ISV=0: the CPU supplied no decoded transfer register or access size for
        // this abort (writeback addressing, DC ZVA, a stage-2 walk fault), so there
        // is nothing to emulate against. The guest can provoke this, so refuse it
        // like any other unserviceable access rather than asserting.
        if (iss.isv == 0) return self.fail(cpu, exit, "data abort without a valid syndrome");
        const pa = exit.physical_address;

        const target = bus.route(pa) orelse return self.fail(cpu, exit, "MMIO unmapped device");
        switch (target) {
            .poweroff => return true,
            .uart => |off| try self.serviceUart(cpu, off, iss),
            .virtio => |off| try self.serviceVirtio(cpu, off, iss),
            .vconsole => |off| try self.serviceVconsole(cpu, off, iss),
        }
        try cpu.advancePc();
        return false;
    }

    // Mirror captured UART TX bytes to `out`, then reset the device's capture
    // buffer so it never reaches its 64 KiB cap — past which UartBuffer.push
    // silently drops (fatal for a long interactive session).
    fn writeConsole(ctx: ?*anyopaque, bytes: []const u8) void {
        const w: *std.Io.Writer = @ptrCast(@alignCast(ctx.?));
        w.writeAll(bytes) catch {};
        w.flush() catch {};
    }

    fn drainUart(self: *Machine) void {
        const n = self.uart.tx_buffer.len;
        if (n == 0) return;
        self.out.writeAll(self.uart.tx_buffer.data[0..n]) catch {};
        self.out.flush() catch {};
        self.uart.tx_buffer.len = 0;
    }

    pub fn deinit(self: *Machine) void {
        self.vcpu.deinit(); // destroy the vCPU before tearing down the VM
        hvf.check(hvf.hv_vm_unmap(RAM_BASE, RAM_SIZE)) catch {};
        _ = hvf.hv_vm_destroy();
        std.posix.munmap(self.ram);
        std.posix.munmap(@alignCast(self.virtio.disk));
        self.* = undefined;
    }
    fn fail(self: *Machine, cpu: anytype, exit: Exit, msg: []const u8) !bool {
        self.fault = .{ .msg = msg, .pc = cpu.getPc() catch 0, .exit = exit };
        return error.UnexpectedGuestExit;
    }
    fn syncUartIrq(self: *Machine, irq: anytype) void {
        irq.setUart(self.uart.irqAsserted());
    }

    fn inputLoop(self: *Machine, irq: HvfIrq) void {
        var byte: [1]u8 = undefined;
        while (true) {
            const n = std.posix.read(0, &byte) catch return;
            if (n == 0) {
                return;
            }
            self.lockUart();
            if (self.uart.rxHasSpace()) {
                self.uart.receive(byte[0]);
            }
            _ = self.vconsole.pushInput(byte[0]);
            self.vconsole.serviceRx(self.ram, RAM_BASE);
            self.syncUartIrq(irq);
            self.syncVconsoleIrq(irq);
            self.uart_lock.unlock();
        }
    }
};

const HvfIrq = struct {
    fn setUart(_: HvfIrq, level: bool) void {
        _ = hvf.hv_gic_set_spi(platform.UART_INTID, level);
    }
    fn setVirtio(_: HvfIrq, level: bool) void {
        _ = hvf.hv_gic_set_spi(platform.VIRTIO_INTID, level);
    }
    fn setVconsole(_: HvfIrq, level: bool) void {
        _ = hvf.hv_gic_set_spi(platform.VCONSOLE_INTID, level);
    }
};

const RawTty = struct {
    fd: std.posix.fd_t,
    saved: std.posix.termios,

    fn enable(fd: std.posix.fd_t) !RawTty {
        const saved = try std.posix.tcgetattr(fd);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .saved = saved };
    }
    fn restore(self: RawTty) void {
        std.posix.tcsetattr(self.fd, .FLUSH, self.saved) catch {};
    }
};

pub const Fault = struct {
    msg: []const u8,
    pc: u64,
    exit: Exit,

    /// Name the transfer register the way the ISA does. Rt/SRT 31 is XZR in an
    /// MSR/MRS and in a data abort — never SP — and "the zero register" is the
    /// informative half: it is why a write's value is known to be 0 without
    /// reading any GPR. "x31" would name a register that does not exist.
    fn rtName(buf: []u8, rt: u5) []const u8 {
        // x0..x30 is 3 chars, so a 3-byte buf always suffices and this cannot fail.
        return if (rt == 31) "xzr" else std.fmt.bufPrint(buf, "x{d}", .{rt}) catch unreachable;
    }

    pub fn format(self: Fault, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("vmm: guest fault: {s}\n", .{self.msg});
        try w.print("  exit.reason = {s}\n", .{@tagName(self.exit.reason)});
        try w.print("  PC          = 0x{x:0>16}\n", .{self.pc});
        if (self.exit.reason != .exception) return;

        const esr = Esr.fromBits(self.exit.syndrome);
        try w.print("  ESR_EL2     = 0x{x:0>8}  (EC = 0x{x})\n", .{ esr.toBits(), @intFromEnum(esr.ec) });

        var buf: [3]u8 = undefined;
        switch (esr.ec) {
            // exit.physical_address is HPFAR-derived: the CPU records it only when
            // the exception HAS a faulting address, i.e. an abort. For every other
            // EC the field is meaningless, and printing "fault PA = 0x0000000000000000"
            // for a trapped sysreg reads as "the fault was at address zero" — a
            // diagnostic that lies is worse than one that stays quiet.
            //
            // Only the _lower variants can appear: an exit is by definition an
            // exception taken from the guest at EL1 to EL2.
            .data_abort_lower, .inst_abort_lower => try w.print(
                "  fault PA    = 0x{x:0>16}\n",
                .{self.exit.physical_address},
            ),

            // EC 0x18 carries the register's identity in the ISS. Decoding it here
            // is what turns "go hand-shift a hex number" into a named register.
            .msr_mrs => {
                const iss = SysRegIss.fromBits(esr.iss);
                // NOT @tagName / {t}: SysReg is non-exhaustive, and @tagName on a value
                // with no name is illegal behavior — i.e. it would blow up on exactly the
                // unknown register you are trying to diagnose. tagName() returns ?[]const u8.
                const name = std.enums.tagName(arm.SysReg, iss.id()) orelse "unnamed";
                try w.print("  sysreg      = {s}  op0={} op1={} CRn={} CRm={} op2={}  {s} {s}\n", .{
                    name, iss.op0, iss.op1, iss.crn, iss.crm, iss.op2,
                    @tagName(iss.direction), // Direction IS exhaustive — safe
                    rtName(&buf, iss.rt),
                });
            },
            else => {},
        }
    }
};

// ---- tests (drive the servicing logic through a FakeVcpu, no HVF) ----------

const testing = std.testing;
const FakeVcpu = @import("vcpu.zig").FakeVcpu;

// Most tests drive the servicing logic without inspecting the mirrored console
// output, so they share this discarding sink. Tests that DO assert on the mirror
// build their own std.Io.Writer.fixed and pass it as `.out` instead.
var test_discard_buf: [64]u8 = undefined;
var test_discard: std.Io.Writer.Discarding = .init(&test_discard_buf);

fn mkMachine() Machine {
    return .{ .ram = undefined, .vcpu = undefined, .out = &test_discard.writer };
}

// The injector test double: records EVERY level pushed instead of calling
// hv_gic_set_spi, so runOn drives it without HVF (the real HvfIrq is verified
// only by a signed run, like the thin Vcpu adapter). A full log, not just the
// last value, because runOn always ends on a poweroff exit that re-syncs — so the
// final level cannot distinguish "synced before servicing" from "after". The
// per-iteration history can. Passed by pointer so the record survives the call.
//
// Two independent lines (UART + virtio), each with its own log, so a test can
// assert they don't cross-talk — the injector maps each device to its own SPI.
const FakeIrq = struct {
    log: [16]bool = undefined,
    n: usize = 0,
    vlog: [16]bool = undefined,
    vn: usize = 0,
    clog: [16]bool = undefined,
    cn: usize = 0,
    fn setUart(self: *FakeIrq, level: bool) void {
        if (self.n < self.log.len) {
            self.log[self.n] = level;
            self.n += 1;
        }
    }
    fn setVirtio(self: *FakeIrq, level: bool) void {
        if (self.vn < self.vlog.len) {
            self.vlog[self.vn] = level;
            self.vn += 1;
        }
    }
    fn setVconsole(self: *FakeIrq, level: bool) void {
        if (self.cn < self.clog.len) {
            self.clog[self.cn] = level;
            self.cn += 1;
        }
    }
    fn last(self: *const FakeIrq) ?bool {
        return if (self.n == 0) null else self.log[self.n - 1];
    }
    fn virtioLast(self: *const FakeIrq) ?bool {
        return if (self.vn == 0) null else self.vlog[self.vn - 1];
    }
};

// Decls nothing calls are never analyzed, so a signature drift in one can sit
// there compiling fine until the day it's used. This type-checks all of them.
// refAllDecls only *references* the decls — it never calls them, so no hv_*
// runs here and the unsigned test binary stays clear of HV_DENIED.
test "every Machine decl compiles" {
    testing.refAllDecls(Machine);
}

// Build the ESR for a plain byte/word data abort with the given direction/reg.
fn dataAbortEsr(is_write: bool, sas: arm.Sas, srt: u5) u64 {
    const iss = DataAbortIss{ .isv = 1, .wnr = @intFromBool(is_write), .sas = sas, .srt = srt };
    return (Esr{ .ec = .data_abort_lower, .iss = iss.toBits() }).toBits();
}

fn abort(is_write: bool, srt: u5, pa: u64) Exit {
    return .{ .reason = .exception, .syndrome = dataAbortEsr(is_write, .byte, srt), .physical_address = pa };
}

// virtio registers are word-only (the device faults sub-word/misaligned), so its
// aborts carry SAS = word — unlike the UART's byte accesses.
fn wordAbort(is_write: bool, srt: u5, pa: u64) Exit {
    return .{ .reason = .exception, .syndrome = dataAbortEsr(is_write, .word, srt), .physical_address = pa };
}

// Hand-write one 16-byte virtq_desc into a guest-RAM buffer at desc_addr + 16*i
// (same layout the device reads back). Lets a test seed a request chain.
fn seedDesc(ram: []u8, i: usize, addr: u64, len: u32, flags: u16, next: u16) void {
    const o = 0x100 + 16 * i;
    std.mem.writeInt(u64, ram[o..][0..8], addr, .little);
    std.mem.writeInt(u32, ram[o + 8 ..][0..4], len, .little);
    std.mem.writeInt(u16, ram[o + 12 ..][0..2], flags, .little);
    std.mem.writeInt(u16, ram[o + 14 ..][0..2], next, .little);
}

// Build an EC 0x18 exit for a trapped access to `reg`, unpacking the SysReg key
// back into ISS fields so a test can name a register instead of five numbers.
fn sysRegExit(reg: arm.SysReg, dir: arm.Direction, rt: u5) Exit {
    const k: arm.SysRegKey = @bitCast(@intFromEnum(reg));
    const iss = SysRegIss{
        .op0 = k.op0,
        .op1 = k.op1,
        .crn = k.crn,
        .crm = k.crm,
        .op2 = k.op2,
        .rt = rt,
        .direction = dir,
    };
    return .{ .reason = .exception, .syndrome = (Esr{ .ec = .msr_mrs, .iss = iss.toBits() }).toBits() };
}

test "serviceDataAbort: LSR read returns THRE|TEMT into the target reg, advances PC" {
    var m = mkMachine();
    var cpu = FakeVcpu{};
    const stop = try m.serviceDataAbort(&cpu, abort(false, 4, UART_BASE + 5));
    try testing.expect(!stop);
    try testing.expectEqual(@as(u64, 0x60), cpu.regs[4]); // THRE|TEMT
    try testing.expectEqual(@as(u64, 4), cpu.pc); // PC += 4
}

// A THR write is mirrored to `out` — the real contract, the bytes the user sees —
// not left sitting in the device's tx_buffer (a proxy). drainUart drains-and-resets,
// so tx_buffer is empty afterward; that emptiness is the fix (it never nears the cap).
test "serviceDataAbort: THR write mirrors the byte to out and resets tx_buffer, advances PC" {
    var obuf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&obuf);
    var m = Machine{ .ram = undefined, .vcpu = undefined, .out = &w };
    var cpu = FakeVcpu{};
    cpu.regs[2] = 'H';
    const stop = try m.serviceDataAbort(&cpu, abort(true, 2, UART_BASE + 0));
    try testing.expect(!stop);
    try testing.expectEqualStrings("H", w.buffered()); // mirrored to out
    try testing.expectEqual(@as(usize, 0), m.uart.tx_buffer.len); // drained and reset
    try testing.expectEqual(@as(u64, 4), cpu.pc);
}

test "serviceDataAbort: store to the poweroff register stops the loop" {
    var m = mkMachine();
    var cpu = FakeVcpu{};
    try testing.expect(try m.serviceDataAbort(&cpu, abort(true, 31, POWEROFF_BASE)));
}

test "serviceDataAbort: access to an unmapped device fails" {
    var m = mkMachine();
    var cpu = FakeVcpu{};
    try testing.expectError(error.UnexpectedGuestExit, m.serviceDataAbort(&cpu, abort(false, 0, 0xdead_0000)));
}

// A guest can provoke an abort carrying no decoded syndrome; servicing it must
// fail cleanly rather than panic. The address is the UART's — a device we DO
// emulate — so this only passes if the ISV check precedes the device dispatch.
test "serviceDataAbort: an abort without a valid syndrome (ISV=0) fails, even for an emulated device" {
    const iss = DataAbortIss{ .isv = 0, .wnr = 1, .sas = .byte, .srt = 2 };
    const exit = Exit{
        .reason = .exception,
        .syndrome = (Esr{ .ec = .data_abort_lower, .iss = iss.toBits() }).toBits(),
        .physical_address = UART_BASE,
    };

    var m = mkMachine();
    var cpu = FakeVcpu{};
    try testing.expectError(error.UnexpectedGuestExit, m.serviceDataAbort(&cpu, exit));
    try testing.expectEqual(@as(usize, 0), m.uart.tx_buffer.len); // nothing reached the device
}

// Only an exception can be serviced; every other exit kind must be refused
// rather than silently resumed. Each of these gets real handling later (the
// virtual timer, and cancellation once a second thread can stop a vCPU).
test "handleExit: exits that are not exceptions fail" {
    for ([_]Exit{
        .{ .reason = .vtimer },
        .{ .reason = .canceled },
        .{ .reason = .unknown },
    }) |exit| {
        var m = mkMachine();
        var cpu = FakeVcpu{};
        try testing.expectError(error.UnexpectedGuestExit, m.handleExit(&cpu, exit));
    }
}

// Exception classes with no branch in handleExit at all: a WFI/WFE, an
// instruction fetch from an unmapped address. Each must fail loudly rather than
// be mistaken for something serviceable.
//
// `.msr_mrs` USED to be in this list and was removed when EC 0x18 got a branch —
// but note it would have stayed GREEN either way, which is the only reason this
// comment exists. The exit below carries ISS = 0, and ISS 0 decodes to an unnamed
// register, which serviceSysReg refuses with the identical error. So the removal
// is not a response to a failure; it is deleting an assertion that had quietly
// become a lie (it claimed EC 0x18 is refused as an unknown exception CLASS; the
// truth is that it is decoded, and that one register is refused). The test with
// teeth is "handleExit: the real OSDLR_EL1 trap ... is serviced" below.
//
// `.hvc` came out the same way when EC 0x16 got its branch — but it is the exact
// MIRROR of the .msr_mrs case, and worth the contrast. This one did NOT stay
// green: the exit carries x0 = 0, which is not a valid FID, and psci.handle
// answers an unknown FID with NOT_SUPPORTED and keeps running (that is its whole
// locked default). So it returned false where the test demanded an error, and
// removing `.hvc` was a response to a REAL failure. Two identical-looking edits;
// only one of them was load-bearing. The test with teeth is in psci.zig.
test "handleExit: exception classes other than a data abort fail" {
    for ([_]arm.ExceptionClass{ .wf_x, .inst_abort_lower }) |ec| {
        var m = mkMachine();
        var cpu = FakeVcpu{};
        const exit = Exit{ .reason = .exception, .syndrome = (Esr{ .ec = ec }).toBits() };
        try testing.expectError(error.UnexpectedGuestExit, m.handleExit(&cpu, exit));
    }
}

// ---- Fault diagnostics ----------------------------------------------------
// The one place string-asserting is right: the rendered text IS the contract, and
// this formatter now does real decode work. It is also the only output a future
// unknown trap will give you, so a regression here is silent until it matters.

fn renderFault(buf: []u8, msg: []const u8, pc: u64, exit: Exit) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{f}", .{Fault{ .msg = msg, .pc = pc, .exit = exit }}) catch unreachable;
    return w.buffered();
}

// A real EC 0x18 syndrome, rendered. Asserts the fault printer names the register
// instead of leaving it as a raw hex number to decode by hand.
test "Fault: an EC 0x18 trap renders a named register, not a hex number" {
    var buf: [512]u8 = undefined;
    const out = renderFault(&buf, "unhandled", 0xffff800080014a00, .{ .reason = .exception, .syndrome = 0x622807e6 });

    try testing.expect(std.mem.indexOf(u8, out, "sysreg      = OSDLR_EL1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "op0=2 op1=0 CRn=1 CRm=3 op2=4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "write xzr") != null); // NOT "x31"
}

// physical_address is only recorded for an abort. Printing it for a sysreg trap
// says "the fault was at address zero", which is a lie — a quiet diagnostic beats
// a confident wrong one.
test "Fault: no fault PA is printed for an exception that has no faulting address" {
    var buf: [512]u8 = undefined;

    const sysreg = renderFault(&buf, "unhandled", 0, .{ .reason = .exception, .syndrome = 0x622807e6 });
    try testing.expect(std.mem.indexOf(u8, sysreg, "fault PA") == null);

    var buf2: [512]u8 = undefined;
    const data_abort = renderFault(&buf2, "unmapped", 0, abort(false, 0, 0xdead_0000));
    try testing.expect(std.mem.indexOf(u8, data_abort, "fault PA    = 0x00000000dead0000") != null);
}

// An unnamed register is EXACTLY the case you hit while diagnosing a new trap, so
// the formatter must survive it — @tagName on a non-exhaustive enum value with no
// name is illegal behavior and would abort here, of all places.
test "Fault: an unnamed system register renders instead of tripping @tagName" {
    var buf: [512]u8 = undefined;
    const iss = SysRegIss{ .op0 = 3, .op1 = 3, .crn = 9, .crm = 12, .op2 = 0, .rt = 7, .direction = .read };
    const exit = Exit{ .reason = .exception, .syndrome = (Esr{ .ec = .msr_mrs, .iss = iss.toBits() }).toBits() };
    const out = renderFault(&buf, "unhandled", 0, exit);

    try testing.expect(std.mem.indexOf(u8, out, "sysreg      = unnamed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "op0=3 op1=3 CRn=9 CRm=12 op2=0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "read x7") != null); // a real reg keeps its number
}

// ---- EC 0x18: trapped system registers ------------------------------------

// The live blocker, both halves: clear_os_lock() writes 0 to OSDLR_EL1 then
// OSLAR_EL1 (Rt=31 == XZR, so there is no register value to read — the syndrome
// alone proves the write is a literal 0). Our model has the OS lock permanently
// clear, so ignoring the write IS the emulation; all that must happen is that the
// guest steps over the instruction.
test "serviceSysReg: the two OS-lock writes clear_os_lock makes are ignored, PC advances" {
    for ([_]arm.SysReg{ .OSDLR_EL1, .OSLAR_EL1 }) |reg| {
        var m = mkMachine();
        var cpu = FakeVcpu{};
        try testing.expect(!try m.serviceSysReg(&cpu, sysRegExit(reg, .write, 31)));
        try testing.expectEqual(@as(u64, 4), cpu.pc);
    }
}

// The negative control for the whole policy: an unnamed sysreg must NOT be
// silently zeroed, and must NOT be stepped over — a refused access leaves PC on
// the trapping instruction. DBGPRCR_EL1 is the honest example: it sits in the
// same trap group and this kernel never executes it, so it is named but unhandled.
test "serviceSysReg: an unnamed system register is refused, not silently zeroed" {
    var m = mkMachine();
    var cpu = FakeVcpu{};
    try testing.expectError(error.UnexpectedGuestExit, m.serviceSysReg(&cpu, sysRegExit(.DBGPRCR_EL1, .write, 0)));
    try testing.expectEqual(@as(u64, 0), cpu.pc);
}

// Write-ignore is only CORRECT because nothing reads the lock back — so the read
// refusal is what keeps that a checked assumption instead of a hope. A guest that
// locked and read back would diverge from our model; this makes it fault by name
// instead of silently believing us. (The only reader in the kernel image is
// cpu_do_resume, which a single-CPU cold boot never executes.)
test "serviceSysReg: reading an OS-lock register back is refused (we model no state)" {
    for ([_]arm.SysReg{ .OSDLR_EL1, .OSLAR_EL1 }) |reg| {
        var m = mkMachine();
        var cpu = FakeVcpu{};
        try testing.expectError(error.UnexpectedGuestExit, m.serviceSysReg(&cpu, sysRegExit(reg, .read, 5)));
        try testing.expectEqual(@as(u64, 0), cpu.pc);
    }
}

// End to end, from the real syndrome, through the real switch. Unlike the
// EC-refusal test above, this one FAILS if the .msr_mrs branch is missing —
// ISS != 0 here, so it names a register we handle.
test "handleExit: the real OSDLR_EL1 trap from the boot trace is serviced" {
    var m = mkMachine();
    var cpu = FakeVcpu{};
    const stop = try m.handleExit(&cpu, .{ .reason = .exception, .syndrome = 0x622807e6 });
    try testing.expect(!stop);
    try testing.expectEqual(@as(u64, 4), cpu.pc);
}

// clear_os_lock() in full, driven through the loop that meets it in the real
// boot: two adjacent traps, then the guest runs on. Verified against the guest —
// disassembling payloads/Image showed these are the ONLY OS-lock accesses on the
// boot path, and a real run produced exactly these two exits and no others.
test "runOn: clear_os_lock's two writes are serviced back to back" {
    const seq = [_]Exit{
        .{ .reason = .exception, .syndrome = 0x622807e6 }, // msr osdlr_el1, xzr  (the real ESR)
        sysRegExit(.OSLAR_EL1, .write, 31), //               msr oslar_el1, xzr
        abort(true, 31, POWEROFF_BASE), //                   stands in for "the boot went on"
    };
    var m = mkMachine();
    var cpu = FakeVcpu{ .exits = &seq };
    var irq = FakeIrq{};
    try testing.expectEqual(@as(u64, 3), try m.runOn(&cpu, &irq));
    try testing.expectEqual(@as(u64, 8), cpu.pc); // both instructions stepped over
}

// syncUartIrq's whole job is to forward the device's interrupt line to the
// injector. Drive it directly through the three states that matter: line low,
// line high (RX int enabled + a byte queued), line low again after the FIFO drains.
// The seam is what lets this run without HVF — HvfIrq would call hv_gic_set_spi.
test "syncUartIrq: forwards the UART interrupt line to the injector" {
    var m = mkMachine();
    var irq = FakeIrq{};

    m.syncUartIrq(&irq);
    try testing.expectEqual(@as(?bool, false), irq.last());

    try m.uart.store(devices.Uart.IER_DLM, 1, 0x01); // ERBFI: enable RX interrupt
    m.uart.receive('x');
    m.syncUartIrq(&irq);
    try testing.expectEqual(@as(?bool, true), irq.last());

    _ = try m.uart.load(devices.Uart.RBR_DLL, 1); // drain the byte
    m.syncUartIrq(&irq);
    try testing.expectEqual(@as(?bool, false), irq.last());
}

// The integration contract runOn adds: after servicing an exit it re-drives the
// line, so a guest RBR read that empties the FIFO leaves the injector LOW. The
// teeth are on log[0], NOT the final level: entering iteration 0 the FIFO holds a
// byte (line high), the guest reads it, and the sync AFTER handleExit must record
// the now-empty FIFO as LOW. A sync BEFORE handleExit would record log[0] = true
// (stale, pre-drain). The final level can't tell them apart — the poweroff
// iteration re-syncs either way — so this asserts the first recorded level.
// Also proves the RX byte reaches the guest register end-to-end.
test "runOn: re-evaluates the UART line after servicing (post-drain, not pre)" {
    var m = mkMachine();
    try m.uart.store(devices.Uart.IER_DLM, 1, 0x01); // ERBFI
    m.uart.receive('Q');

    const seq = [_]Exit{
        abort(false, 4, UART_BASE + 0), // guest reads RBR → pops 'Q', FIFO now empty
        abort(true, 31, POWEROFF_BASE),
    };
    var cpu = FakeVcpu{ .exits = &seq };
    var irq = FakeIrq{};
    try testing.expectEqual(@as(u64, 2), try m.runOn(&cpu, &irq));
    try testing.expectEqual(@as(u64, 'Q'), cpu.regs[4]); // the byte reached the guest
    try testing.expect(irq.n >= 1);
    try testing.expectEqual(false, irq.log[0]); // synced AFTER the drain, not before
}

// The mirror of the above: a byte still queued after the loop settles leaves the
// line HIGH. Without this, a syncUartIrq that always pushed `false` would pass the
// drain test above and still be broken — this is the case that distinguishes them.
test "runOn: leaves the UART line high while a byte stays queued" {
    var m = mkMachine();
    try m.uart.store(devices.Uart.IER_DLM, 1, 0x01); // ERBFI
    m.uart.receive('Q');

    const seq = [_]Exit{abort(true, 31, POWEROFF_BASE)}; // powers off without reading RBR
    var cpu = FakeVcpu{ .exits = &seq };
    var irq = FakeIrq{};
    _ = try m.runOn(&cpu, &irq);
    try testing.expectEqual(@as(?bool, true), irq.last()); // byte still queued → line high
}

test "handleExit: a data abort reaches the device servicing path and mirrors to out" {
    var obuf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&obuf);
    var m = Machine{ .ram = undefined, .vcpu = undefined, .out = &w };
    var cpu = FakeVcpu{};
    cpu.regs[2] = 'H';
    const stop = try m.handleExit(&cpu, abort(true, 2, UART_BASE + 0));
    try testing.expect(!stop);
    try testing.expectEqualStrings("H", w.buffered());
    try testing.expectEqual(@as(u64, 4), cpu.pc);
}

test "runOn: services a read then a write (mirrored to out), stops on poweroff, counts exits" {
    const seq = [_]Exit{
        abort(false, 4, UART_BASE + 5), // LSR read
        abort(true, 2, UART_BASE + 0), // THR write ('H')
        abort(true, 31, POWEROFF_BASE), // poweroff
    };
    var obuf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&obuf);
    var m = Machine{ .ram = undefined, .vcpu = undefined, .out = &w };
    var cpu = FakeVcpu{ .exits = &seq };
    cpu.regs[2] = 'H';
    var irq = FakeIrq{};
    try testing.expectEqual(@as(u64, 3), try m.runOn(&cpu, &irq));
    try testing.expectEqualStrings("H", w.buffered());
}

// The drain fix, end to end: push more single-byte THR stores through the real
// servicing path than the device's tx_buffer can hold, and assert every byte
// still reaches `out`. UartBuffer caps at UART_TX_CAP (1<<16) and silently drops
// past it, so without drain-and-reset the mirror would either stall at 65536
// (a watermark drain) or re-emit the whole growing buffer each store (this one) —
// either way `out` would not receive exactly `n` bytes. A Discarding sink counts
// without needing a >64 KiB buffer. This is the bug that turns fatal in a long
// interactive session; deleting the `tx_buffer.len = 0` reset makes it fail.
test "drainUart: guest console output past the 64 KiB tx_buffer cap is not dropped" {
    const n: usize = (1 << 16) + 5000; // comfortably past UART_TX_CAP
    var sink_buf: [64]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&sink_buf);
    var m = Machine{ .ram = undefined, .vcpu = undefined, .out = &sink.writer };
    var cpu = FakeVcpu{};
    cpu.regs[2] = 'x';
    for (0..n) |_| {
        _ = try m.serviceDataAbort(&cpu, abort(true, 2, UART_BASE + 0));
    }
    try testing.expectEqual(@as(u64, n), sink.fullCount());
}

// ---- virtio-mmio servicing ------------------------------------------------
// The device model itself (register file, virtqueue engine, T_IN/T_OUT) is
// exhaustively tested in the virtual-hardware package at base 0x8000_0000, which
// IS our RAM_BASE. These tests cover only the vmm-side plumbing the package can't:
// routing a virtio PA to load/store, the QueueNotify→process trigger against
// (self.ram, RAM_BASE), and forwarding the completion line to the injector.

// A virtio register read routes through the bus, hits the device's word-only
// load, and lands the value in the target GPR. Offset 0 is MagicValue — an exact
// nonzero constant, so it can only appear if load actually ran at the right offset.
test "serviceVirtio: a word read returns the device register value and advances PC" {
    var m = mkMachine();
    var cpu = FakeVcpu{};
    const stop = try m.serviceDataAbort(&cpu, wordAbort(false, 4, platform.VIRTIO_BASE + 0x00));
    try testing.expect(!stop);
    try testing.expectEqual(@as(u64, devices.Virtio.MAGIC_VAL), cpu.regs[4]);
    try testing.expectEqual(@as(u64, 4), cpu.pc);
}

test "serviceVconsole: a word read at the console slot returns DeviceID 3, not the block device's 2" {
    var m = mkMachine();
    var cpu = FakeVcpu{};

    const stop = try m.serviceDataAbort(&cpu, wordAbort(false, 4, platform.VCONSOLE_BASE + 0x008));
    try testing.expect(!stop);
    try testing.expectEqual(@as(u64, 3), cpu.regs[4]);
    try testing.expectEqual(@as(u64, 4), cpu.pc);

    _ = try m.serviceDataAbort(&cpu, wordAbort(false, 5, platform.VIRTIO_BASE + 0x008));
    try testing.expectEqual(@as(u64, 2), cpu.regs[5]);
}

test "writeConsole: the sink mirrors virtio-console TX to the machine's out writer" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    Machine.writeConsole(&w, "hvc");
    try testing.expectEqualStrings("hvc", w.buffered());
}

test "serviceVconsole: a QueueNotify store routes to the device and advances PC" {
    var ram_backing: [4096]u8 align(std.heap.page_size_min) = @splat(0);
    var m = mkMachine();
    m.ram = &ram_backing;
    var cpu = FakeVcpu{};
    cpu.regs[3] = 0;
    const stop = try m.serviceDataAbort(&cpu, wordAbort(true, 3, platform.VCONSOLE_BASE + QUEUE_NOTIFY));
    try testing.expect(!stop);
    try testing.expectEqual(@as(u64, 4), cpu.pc);
}

// The real integration: a QueueNotify (0x50) store must invoke process
// against (self.ram, RAM_BASE) and complete the queued T_IN request. A full
// single-descriptor-chain is seeded into a real RAM buffer; after the notify the
// disk sector must have DMA'd into the guest data buffer, the status byte cleared,
// notify_pending consumed (proving the process branch ran, not just the store),
// the completion interrupt raised, and the line forwarded to the injector.
test "serviceVirtio: a QueueNotify drives process — sector DMAs into guest RAM, line raised, notify consumed" {
    var ram_backing: [4096]u8 align(std.heap.page_size_min) = @splat(0);
    const ram: []align(std.heap.page_size_min) u8 = &ram_backing;

    var disk: [512]u8 = @splat(0);
    for (0..512) |j| disk[j] = @truncate(j *% 7 + 1);

    seedDesc(ram, 0, RAM_BASE + 0x200, 16, 1, 1); // header, NEXT
    seedDesc(ram, 1, RAM_BASE + 0x300, 512, 3, 2); // data, WRITE|NEXT
    seedDesc(ram, 2, RAM_BASE + 0x600, 1, 2, 0); // status, WRITE
    std.mem.writeInt(u32, ram[0x200..][0..4], 0, .little); // req type = T_IN
    std.mem.writeInt(u32, ram[0x204..][0..4], 0, .little); // reserved
    std.mem.writeInt(u64, ram[0x208..][0..8], 0, .little); // sector 0
    std.mem.writeInt(u16, ram[0x82..][0..2], 1, .little); // avail.idx = 1
    std.mem.writeInt(u16, ram[0x84..][0..2], 0, .little); // avail.ring[0] = head 0
    ram[0x600] = 0xff; // driver presets status

    var m = mkMachine();
    m.ram = ram;
    m.virtio.desc_addr = RAM_BASE + 0x100;
    m.virtio.avail_addr = RAM_BASE + 0x80;
    m.virtio.used_addr = RAM_BASE + 0x700;
    m.virtio.disk = &disk;
    m.virtio.queue_ready = 1;
    m.virtio.status = 0x4; // DRIVER_OK

    var cpu = FakeVcpu{};
    var irq = FakeIrq{};
    const stop = try m.serviceDataAbort(&cpu, wordAbort(true, 3, platform.VIRTIO_BASE + 0x50));
    m.syncVirtioIrq(&irq);

    try testing.expect(!stop);
    try testing.expectEqualSlices(u8, disk[0..512], ram[0x300..][0..512]); // sector DMA'd in
    try testing.expectEqual(@as(u8, 0), ram[0x600]); // status cleared
    try testing.expect(!m.virtio.notify_pending); // process branch ran
    try testing.expect(m.virtio.irqAsserted()); // completion raised the line
    try testing.expectEqual(@as(?bool, true), irq.virtioLast()); // and syncVirtioIrq forwarded it
    try testing.expectEqual(@as(u64, 4), cpu.pc); // stepped over the notify store
}

// syncVirtioIrq forwards the device's level line to the injector, same contract as
// syncUartIrq. Queue-free: seed interrupt_status directly (a completion sets it),
// then the driver's write-1-to-clear ACK lowers it.
test "syncVirtioIrq: forwards the virtio interrupt line to the injector" {
    var m = mkMachine();
    var irq = FakeIrq{};

    m.syncVirtioIrq(&irq);
    try testing.expectEqual(@as(?bool, false), irq.virtioLast());

    m.virtio.interrupt_status = 0x1; // used-buffer notification pending
    m.syncVirtioIrq(&irq);
    try testing.expectEqual(@as(?bool, true), irq.virtioLast());

    try m.virtio.store(0x64, 4, 0x1); // driver ACKs (write-1-to-clear)
    m.syncVirtioIrq(&irq);
    try testing.expectEqual(@as(?bool, false), irq.virtioLast());
}

// runOn drives BOTH lines after every exit, and they must not cross: with the
// UART line high (byte queued + RX int enabled) and virtio idle, the injector's
// virtio line stays LOW. A syncVirtioIrq wired to the wrong device would light it.
test "runOn: drives the UART and virtio lines independently (no cross-talk)" {
    var m = mkMachine();
    try m.uart.store(devices.Uart.IER_DLM, 1, 0x01); // ERBFI
    m.uart.receive('Q'); // UART line → HIGH
    // virtio left idle → its line must stay LOW

    const seq = [_]Exit{abort(true, 31, POWEROFF_BASE)};
    var cpu = FakeVcpu{ .exits = &seq };
    var irq = FakeIrq{};
    _ = try m.runOn(&cpu, &irq);

    try testing.expectEqual(@as(?bool, true), irq.last()); // UART high
    try testing.expectEqual(@as(?bool, false), irq.virtioLast()); // virtio stayed low
}
