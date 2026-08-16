const std = @import("std");
const loader = @import("loader.zig");
const ImageHeader = @import("linux_boot").arm64.ImageHeader;
const hvf = @import("hvf.zig");
const device_tree = @import("device_tree.zig");
const RAM_BASE = @import("platform.zig").RAM_BASE;
const RAM_SIZE = @import("platform.zig").RAM_SIZE;
const MiB = @import("platform.zig").MiB;

// Payload placement WITHIN RAM (offsets from RAM_BASE). Constraints are from the
// arm64 boot protocol (Documentation/arch/arm64/booting.rst); the addresses these
// imply must match whatever the guest's device tree claims.
pub const KERNEL_OFF: usize = 0x0020_0000; // 2 MiB — Image base MUST be 2 MiB-aligned
pub const INITRD_OFF: usize = 0x1000_0000; // 256 MiB — above the kernel
pub const DTB_OFF: usize = 0x1F00_0000; // 496 MiB — 8-byte aligned, <2 MiB, within RAM's first 512 MiB

pub const KERNEL_IPA: hvf.hv_ipa_t = RAM_BASE + KERNEL_OFF;
pub const INITRD_IPA: hvf.hv_ipa_t = RAM_BASE + INITRD_OFF;
pub const DTB_IPA: hvf.hv_ipa_t = RAM_BASE + DTB_OFF;
comptime {
    std.debug.assert(KERNEL_IPA % (2 * MiB) == 0);

    // DTB: 8-byte aligned, within the first 512 MiB of RAM
    std.debug.assert(DTB_IPA % 8 == 0);

    // arm64 booting.rst: Image base is 2 MiB-aligned
    std.debug.assert(DTB_OFF < 512 * MiB);

    // Payload regions ordered within RAM. Only ordering is provable here; whether
    // they actually FIT depends on file sizes, so loadPayloads checks that at run time.
    std.debug.assert(KERNEL_OFF < INITRD_OFF);
    std.debug.assert(INITRD_OFF < DTB_OFF);
    std.debug.assert(DTB_OFF < RAM_SIZE);
}

const Payloads = struct {
    image_size: u64,
    kernel_len: usize,
    initrd_len: usize,
    dtb_len: usize,
};
pub fn loadPayloads(io: std.Io, dir: std.Io.Dir, ram: []u8) !Payloads {
    std.debug.assert(ram.len >= DTB_OFF); // boot layout must fit the RAM we were given

    const kernel_len = try loader.load(io, dir, ram, KERNEL_OFF, "payloads/Image", INITRD_OFF - KERNEL_OFF);

    const header = try ImageHeader.parse(ram[KERNEL_OFF..][0..64].*);
    if (header.image_size != 0 and KERNEL_OFF + header.image_size > INITRD_OFF)
        return error.KernelFootprintOverflow;

    const initrd_len = try loader.load(io, dir, ram, INITRD_OFF, "payloads/initramfs.cpio", DTB_OFF - INITRD_OFF);
    if (INITRD_OFF + initrd_len > DTB_OFF) return error.InitrdOverflow;

    const dtb = try device_tree.build(ram[DTB_OFF..], .{
        .initrd_start = INITRD_IPA,
        .initrd_end = INITRD_IPA + initrd_len,
    });
    const dtb_len = dtb.len;

    return .{ .image_size = header.image_size, .kernel_len = kernel_len, .initrd_len = initrd_len, .dtb_len = dtb_len };
}

const testing = std.testing;

// A minimal valid arm64 Image header (magic + image_size) in a 128-byte blob.
fn fakeImage(buf: []u8, image_size: u64) void {
    @memset(buf, 0);
    buf[56] = 0x41; // "ARM\x64" magic at offset 0x38, little-endian
    buf[57] = 0x52;
    buf[58] = 0x4d;
    buf[59] = 0x64;
    std.mem.writeInt(u64, buf[16..24], image_size, .little);
}

// Full-size fake guest RAM. page_allocator = lazy mmap, so only the few pages we
// actually write (near the three offsets) commit — the ~500 MiB length is cheap.
fn fakeRam() ![]u8 {
    return std.heap.page_allocator.alloc(u8, DTB_OFF + 0x10000);
}

test "loadPayloads: places kernel/initrd and generates a DTB carrying the initrd extent" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "payloads");

    var image: [128]u8 = undefined;
    fakeImage(&image, 0x1000); // small footprint, fits the kernel window
    const initrd = "INITRAMFS-CONTENT"; // 17 bytes → drives initrd_end below
    try tmp.dir.writeFile(io, .{ .sub_path = "payloads/Image", .data = &image });
    try tmp.dir.writeFile(io, .{ .sub_path = "payloads/initramfs.cpio", .data = initrd });
    // No guest.dtb on disk: the DTB is generated, not loaded.

    const ram = try fakeRam();
    defer std.heap.page_allocator.free(ram);

    const p = try loadPayloads(io, tmp.dir, ram);
    try testing.expectEqual(@as(u64, 0x1000), p.image_size);
    try testing.expectEqual(image.len, p.kernel_len);
    try testing.expectEqual(initrd.len, p.initrd_len);
    // kernel + initrd landed at their offsets
    try testing.expectEqual(@as(u8, 0x41), ram[KERNEL_OFF + 56]); // magic byte
    try testing.expectEqualStrings(initrd, ram[INITRD_OFF..][0..initrd.len]);

    // The DTB was generated in place at DTB_OFF: real FDT magic, not a copied file.
    const blob = ram[DTB_OFF..][0..p.dtb_len];
    try testing.expectEqualSlices(u8, &.{ 0xd0, 0x0d, 0xfe, 0xed }, blob[0..4]);
    // THE integration contract: initrd_end = INITRD_IPA + initrd_len is derived from
    // THIS run's initrd length and written into the blob. 0x9000_0000 + 17 =
    // 0x9000_0011, as two big-endian cells. A wiring that ignored initrd_len, or
    // read a stale on-disk DTB, cannot produce these bytes.
    const initrd_end = [_]u8{ 0, 0, 0, 0, 0x90, 0x00, 0x00, 0x11 };
    try testing.expect(std.mem.indexOf(u8, blob, &initrd_end) != null);
}

test "loadPayloads: rejects a kernel whose image_size overflows into the initrd region" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "payloads");

    var image: [128]u8 = undefined;
    fakeImage(&image, INITRD_OFF); // KERNEL_OFF + INITRD_OFF > INITRD_OFF → overflow
    try tmp.dir.writeFile(io, .{ .sub_path = "payloads/Image", .data = &image });
    try tmp.dir.writeFile(io, .{ .sub_path = "payloads/initramfs.cpio", .data = "x" });

    const ram = try fakeRam();
    defer std.heap.page_allocator.free(ram);

    try testing.expectError(error.KernelFootprintOverflow, loadPayloads(io, tmp.dir, ram));
}
