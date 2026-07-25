const std = @import("std");
const testing = std.testing;
const fdt = @import("fdt.zig");
const platform = @import("platform.zig");
const Prop = fdt.Prop;
const Node = fdt.Node;

const PHANDLE_INTC: u32 = 1;

fn hi(v: u64) u32 {
    return @truncate(v >> 32);
}
fn lo(v: u64) u32 {
    return @truncate(v);
}

pub const Params = struct {
    initrd_start: u64,
    initrd_end: u64,
};

const Arena = struct {
    buf: []u8,
    len: usize = 0,
    fn print(self: *Arena, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const s = try std.fmt.bufPrint(self.buf[self.len..], fmt, args);
        self.len += s.len;
        return s;
    }
};

pub fn build(buf: []u8, p: Params) ![]u8 {
    var strings: [512]u8 = undefined;
    var name_buf: [512]u8 = undefined;
    var na = Arena{ .buf = &name_buf };

    // GICR_SIZE (what the guest walks), NOT GICR_REGION_SIZE (what HVF reserves).
    const gic_reg = [_]u32{
        hi(platform.GICD_BASE), lo(platform.GICD_BASE), hi(platform.GICD_SIZE), lo(platform.GICD_SIZE),
        hi(platform.GICR_BASE), lo(platform.GICR_BASE), hi(platform.GICR_SIZE), lo(platform.GICR_SIZE),
    };
    const mem_reg = [_]u32{
        hi(platform.RAM_BASE), lo(platform.RAM_BASE), hi(platform.RAM_SIZE), lo(platform.RAM_SIZE),
    };
    const uart_reg = [_]u32{ hi(platform.UART_BASE), lo(platform.UART_BASE), 0, 0x100 };
    const uart_ints = [_]u32{ 0, platform.UART_SPI, 0x04 };
    const timer_ints = [_]u32{
        1, 0xd, 0x104, // secure phys     -> intid 29
        1, 0xe, 0x104, // non-secure phys -> intid 30
        1, 0xb, 0x104, // virtual         -> intid 27  <- the live one
        1, 0xa, 0x104, // hyp phys        -> intid 26
    };

    const root_props: []const Prop = &.{
        .{ .name = "#address-cells", .value = .{ .u32 = 2 } },
        .{ .name = "#size-cells", .value = .{ .u32 = 2 } },
        .{ .name = "compatible", .value = .{ .string = "linux,dummy-virt" } },
        .{ .name = "model", .value = .{ .string = "vmm guest" } },
        .{ .name = "interrupt-parent", .value = .{ .u32 = PHANDLE_INTC } },
    };

    const choosen_props: []const Prop = &.{
        .{ .name = "bootargs", .value = .{ .string = try na.print(
            "earlycon=uart8250,mmio,0x{x} console=ttyS0 ignore_loglevel",
            .{platform.UART_BASE},
        ) } },
        .{ .name = "stdout-path", .value = .{ .string = try na.print(
            "/serial@{x}",
            .{platform.UART_BASE},
        ) } },
        .{ .name = "linux,initrd-start", .value = .{ .u64 = p.initrd_start } },
        .{ .name = "linux,initrd-end", .value = .{ .u64 = p.initrd_end } },
    };

    const int_controller_props: []const Prop = &.{
        .{ .name = "compatible", .value = .{ .string = "arm,gic-v3" } },
        .{ .name = "#interrupt-cells", .value = .{ .u32 = 3 } },
        .{ .name = "#address-cells", .value = .{ .u32 = 2 } },
        .{ .name = "#size-cells", .value = .{ .u32 = 2 } },
        .{ .name = "ranges", .value = .empty },
        .{ .name = "interrupt-controller", .value = .empty },
        .{ .name = "reg", .value = .{ .cells = &gic_reg } },
        .{ .name = "phandle", .value = .{ .u32 = PHANDLE_INTC } },
    };

    const chosen: Node = .{
        .name = "chosen",
        .props = choosen_props,
    };

    const memory: Node = .{
        .name = try na.print("memory@{x}", .{platform.RAM_BASE}),
        .props = &.{
            .{ .name = "device_type", .value = .{ .string = "memory" } },
            // The node name and this reg are now the SAME constant. They were two.
            .{ .name = "reg", .value = .{ .cells = &mem_reg } },
        },
    };

    const cpus: Node = .{
        .name = "cpus",
        .props = &.{
            .{ .name = "#address-cells", .value = .{ .u32 = 1 } }, // a cpu reg is an affinity id...
            .{ .name = "#size-cells", .value = .{ .u32 = 0 } }, // ...and has no size
        },
        .children = &.{
            .{
                .name = "cpu@0",
                .props = &.{
                    .{ .name = "device_type", .value = .{ .string = "cpu" } },
                    .{ .name = "compatible", .value = .{ .string = "arm,cortex-a72" } },
                    .{ .name = "reg", .value = .{ .u32 = 0 } },
                },
            },
        },
    };

    const int_controller: Node = .{
        .name = try na.print("interrupt-controller@{x}", .{platform.GICD_BASE}),
        .props = int_controller_props,
    };

    const timer: Node = .{ .name = "timer", .props = &.{
        .{ .name = "compatible", .value = .{ .string = "arm,armv8-timer" } },
        .{ .name = "interrupts", .value = .{ .cells = &timer_ints } },
        .{ .name = "always-on", .value = .empty },
    } };

    const serial: Node = .{
        .name = try na.print("serial@{x}", .{platform.UART_BASE}),
        .props = &.{
            .{ .name = "compatible", .value = .{ .string = "ns16550a" } },
            .{ .name = "reg", .value = .{ .cells = &uart_reg } },
            .{ .name = "clock-frequency", .value = .{ .u32 = 24_000_000 } },
            .{ .name = "interrupts", .value = .{ .cells = &uart_ints } },
        },
    };
    const virtio_reg = [_]u32{ hi(platform.VIRTIO_BASE), lo(platform.VIRTIO_BASE), hi(platform.VIRTIO_SIZE), lo(platform.VIRTIO_SIZE) };
    const virtio_ints = [_]u32{ 0, platform.VIRTIO_SPI, 0x04 };
    const virtio: Node = .{
        .name = try na.print("virtio_mmio@{x}", .{platform.VIRTIO_BASE}),
        .props = &.{
            .{ .name = "compatible", .value = .{ .string = "virtio,mmio" } },
            .{ .name = "reg", .value = .{ .cells = &virtio_reg } },
            .{ .name = "interrupts", .value = .{ .cells = &virtio_ints } },
        },
    };
    const psci: Node = .{ .name = "psci", .props = &.{
        .{ .name = "compatible", .value = .{ .strings = &.{ "arm,psci-1.0", "arm,psci-0.2" } } },
        .{ .name = "method", .value = .{ .string = "hvc" } },
    } };

    const root = Node{
        .name = "",
        .props = root_props,
        .children = &.{ chosen, memory, cpus, int_controller, timer, serial, psci, virtio },
    };

    return fdt.serialize(buf, &strings, root);
}

// What this guards: a value known only at run time must reach the blob.
// Two different extents must produce different blobs, and the actual cells must be
// present, big-endian, two cells (Value.u64).
test "device_tree: the initrd extent reaches the blob" {
    var buf: [4096]u8 = undefined;
    var buf2: [4096]u8 = undefined;
    const one = try build(&buf, .{ .initrd_start = 0x9000_0000, .initrd_end = 0x9022_0800 });
    const two = try build(&buf2, .{ .initrd_start = 0x9000_0000, .initrd_end = 0x9033_0000 });
    try testing.expect(!std.mem.eql(u8, one, two));
    try testing.expect(std.mem.indexOf(u8, one, &.{ 0, 0, 0, 0, 0x90, 0x22, 0x08, 0x00 }) != null);
    try testing.expect(std.mem.indexOf(u8, one, &.{ 0, 0, 0, 0, 0x90, 0x00, 0x00, 0x00 }) != null);
}

// THE landmine, asserted: dtc synthesizes `phandle` from the intc: label, so
// guest.dts never wrote it. Omit it here and interrupt-parent resolves to nothing,
// the timer never probes, and the boot regresses to an arch-timer panic from a
// tree that dumps fine. Verified present in the real dtc blob by decompiling it.
test "device_tree: the GIC node carries a phandle" {
    var buf: [4096]u8 = undefined;
    const blob = try build(&buf, .{ .initrd_start = 0x9000_0000, .initrd_end = 0x9022_0800 });
    try testing.expect(std.mem.indexOf(u8, blob, "phandle\x00") != null);
    const parent = std.mem.indexOf(u8, blob, "interrupt-parent\x00");
    try testing.expect(parent != null);
    try testing.expect(std.mem.indexOf(u8, blob, &[_]u8{ 0, 0, 0, PHANDLE_INTC }) != null);
}

test "device_tree: the tree is well-formed and fits the DTB budget" {
    var buf: [4096]u8 = undefined;
    const blob = try build(&buf, .{ .initrd_start = 0x9000_0000, .initrd_end = 0x9022_0800 });
    try testing.expectEqualSlices(u8, &.{ 0xd0, 0x0d, 0xfe, 0xed }, blob[0..4]);
    var h = std.mem.bytesToValue(fdt.Header, blob[0..@sizeOf(fdt.Header)]);
    std.mem.byteSwapAllFields(fdt.Header, &h);
    try testing.expectEqual(@as(usize, h.totalsize), blob.len);
    try testing.expect(blob.len < 4096);
}

// Step 5's node: how the guest discovers the virtio-mmio device — its MMIO window
// and its SPI. reg and interrupts are built from the SAME platform constants the
// bus router and the injector use, so this pins that they reach the blob unchanged.
// interrupts = <0 VIRTIO_SPI 4>: cell 0 = GIC_SPI, cell 2 = 0x04 = IRQ_TYPE_LEVEL_HIGH,
// matching the device's level interrupt_status (an edge type here would drop
// completions). Building the expected bytes from platform.VIRTIO_SPI is what makes
// a stray literal in the node fail this instead of silently mis-wiring the IRQ.
test "device_tree: the virtio-mmio node carries reg and a level-high SPI from the platform constants" {
    var buf: [4096]u8 = undefined;
    const blob = try build(&buf, .{ .initrd_start = 0x9000_0000, .initrd_end = 0x9022_0800 });

    try testing.expect(std.mem.indexOf(u8, blob, "virtio,mmio\x00") != null);

    var reg: [16]u8 = undefined;
    std.mem.writeInt(u32, reg[0..4], hi(platform.VIRTIO_BASE), .big);
    std.mem.writeInt(u32, reg[4..8], lo(platform.VIRTIO_BASE), .big);
    std.mem.writeInt(u32, reg[8..12], hi(platform.VIRTIO_SIZE), .big);
    std.mem.writeInt(u32, reg[12..16], lo(platform.VIRTIO_SIZE), .big);
    try testing.expect(std.mem.indexOf(u8, blob, &reg) != null);

    var ints: [12]u8 = undefined;
    std.mem.writeInt(u32, ints[0..4], 0, .big); // GIC_SPI
    std.mem.writeInt(u32, ints[4..8], platform.VIRTIO_SPI, .big); // DT-relative SPI number
    std.mem.writeInt(u32, ints[8..12], 0x04, .big); // IRQ_TYPE_LEVEL_HIGH
    try testing.expect(std.mem.indexOf(u8, blob, &ints) != null);
}
