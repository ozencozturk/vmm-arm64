const std = @import("std");

/// Read `path` (relative to `dir`) into ram[off..], size-checked against `limit`.
/// Returns the number of bytes loaded. The caller passes `std.Io.Dir.cwd()` in
/// production; tests pass a temp dir. (Zig 0.17-dev: fs I/O lives under std.Io.)
pub fn load(io: std.Io, dir: std.Io.Dir, ram: []u8, off: usize, path: []const u8, limit: usize) !usize {
    const f = try dir.openFile(io, path, .{});
    defer f.close(io);
    const sz: usize = @intCast((try f.stat(io)).size);
    if (sz > limit) {
        return error.PayloadTooLarge;
    }
    var rbuf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    try fr.interface.readSliceAll(ram[off..][0..sz]);
    return sz;
}

const testing = std.testing;

test "load: reads a file into ram at the given offset, leaving the prefix untouched" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "hello loader payload";
    try tmp.dir.writeFile(io, .{ .sub_path = "blob.bin", .data = content });

    var ram: [256]u8 = @splat(0xAA);
    const off: usize = 16;
    const n = try load(io, tmp.dir, &ram, off, "blob.bin", ram.len - off);

    try testing.expectEqual(content.len, n);
    try testing.expectEqualStrings(content, ram[off..][0..n]);
    try testing.expectEqual(@as(u8, 0xAA), ram[off - 1]); // bytes before off untouched
}

test "load: errors when the file exceeds the limit" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = "0123456789" });
    var ram: [64]u8 = undefined;
    try testing.expectError(error.PayloadTooLarge, load(io, tmp.dir, &ram, 0, "big.bin", 5));
}

test "load: propagates FileNotFound for a missing file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var ram: [64]u8 = undefined;
    try testing.expectError(error.FileNotFound, load(io, tmp.dir, &ram, 0, "nope.bin", 64));
}
