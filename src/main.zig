const std = @import("std");
const machine = @import("machine.zig");

pub const guest_blob = @embedFile("guest.bin");
// Creating a VM only succeeds if this process is signed with the
// com.apple.security.hypervisor entitlement (vmm.entitlements + the codesign step
// in build.zig); unsigned or unentitled, the kernel answers HV_DENIED. That is
// why the binary must be run from a build, never from a bare `zig run`.

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The guest console mirror. The buffer and File.Writer must outlive init()
    // (the Machine only borrows the interface), so they live here in main.
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &out_buf);

    var m = try machine.Machine.init(io, &out.interface);
    // var m = try machine.Machine.initBlob(machine.guest_blob, &out.interface);
    defer m.deinit();

    m.run() catch |e| {
        if (m.fault) |f| {
            std.debug.print("{f}\n", .{f});
        }
        return e;
    };
}

// Pull the exe-module files' tests into `zig build test` (explicit, so lazy
// analysis of unused decls can't silently drop them).
test {
    _ = @import("arm.zig");
    _ = @import("hvf.zig");
    _ = @import("gic.zig");
    _ = @import("bus.zig");
    _ = @import("device_tree.zig");
    _ = @import("psci.zig");
    _ = @import("vcpu.zig");
    _ = @import("machine.zig");
    _ = @import("loader.zig");
    _ = @import("boot_layout.zig");
}
