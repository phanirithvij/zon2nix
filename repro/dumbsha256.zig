const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const file_path = args[1];

    const file = try std.fs.cwd().openFile(file_path, .{});
    const stat = try file.stat();
    const file_buffer = try file.reader().readAllAlloc(allocator, stat.size);
    defer allocator.free(file_buffer);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    try hash.writer().writeAll(file_buffer);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const enc = std.base64.standard.Encoder;
    var buf: [44]u8 = undefined;
    _ = enc.encode(&buf, &digest);
    const sri = try std.fmt.allocPrint(allocator, "sha256-{s}", .{buf});

    try std.io.getStdOut().writer().print("{s}\n", .{std.fmt.bytesToHex(digest, .lower)});
    try std.io.getStdOut().writer().print("{s}\n", .{sri});
}
