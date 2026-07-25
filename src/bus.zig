const std = @import("std");
const platform = @import("platform.zig");

pub const Target = union(enum) {
    poweroff,
    uart: usize,
    virtio: usize,
};

pub fn route(pa: platform.Ipa) ?Target {
    for (platform.emulated) |r| {
        if (pa >= r.base and pa < r.base + r.size) {
            return switch (r.device.?) {
                .poweroff => .poweroff,
                .uart => .{ .uart = pa - r.base },
                .virtio => .{ .virtio = pa - r.base },
            };
        }
    }
    return null;
}

const testing = std.testing;

// Each emulated hole routes to its device, carrying the offset WITHIN the region
// (the arithmetic bus owns so no call site repeats it). Poweroff is void — the
// whole doubleword is one trigger, no offset.
test "route: each emulated region maps to its device with the offset within it" {
    try testing.expect(route(platform.POWEROFF_BASE).? == .poweroff);

    const u = route(platform.UART_BASE + 5).?;
    try testing.expect(u == .uart);
    try testing.expectEqual(@as(usize, 5), u.uart);

    const v = route(platform.VIRTIO_BASE + 0x50).?;
    try testing.expect(v == .virtio);
    try testing.expectEqual(@as(usize, 0x50), v.virtio);
}

// The range is half-open: the last byte of a region is in, the first byte past it
// is not. This is the off-by-one a `<=` would get wrong.
test "route: half-open — base+size-1 is in, base+size is out" {
    try testing.expect(route(platform.UART_BASE + platform.UART_SIZE - 1) != null);
    try testing.expect(route(platform.UART_BASE + platform.UART_SIZE) == null);
}

// An address in no emulated region routes to null (→ the fail path in the caller).
// GICD is the important case: HVF services it, so bus must NOT claim it — a data
// abort there means hv_gic_create failed, not a missing device model.
test "route: an address in no emulated region is null (gap, RAM, HVF-owned hole)" {
    try testing.expect(route(0xdead_0000) == null);
    try testing.expect(route(platform.RAM_BASE) == null);
    try testing.expect(route(platform.GICD_BASE) == null);
}

// Ties the router to the platform map so the two lists can't drift: every hole in
// platform.emulated must route at both its first and last byte. Add a region to
// the map without a matching route arm and this goes red (or r.device.? panics on
// a tagless entry) — either way it can't pass silently.
test "route: every platform.emulated region is routable at both ends" {
    for (platform.emulated) |r| {
        try testing.expect(route(r.base) != null);
        try testing.expect(route(r.base + r.size - 1) != null);
    }
}
