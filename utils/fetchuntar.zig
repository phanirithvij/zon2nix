const std = @import("std");
const print = std.debug.print;
const http = std.http;

pub fn main() !void {
    var dbga = std.heap.DebugAllocator(.{}){};
    defer _ = dbga.deinit();
    const allocator = dbga.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try fetchUnpackTarball(allocator, args[1]);
}

pub fn fetchUnpackTarball(alloc: std.mem.Allocator, url: []const u8) !void {
    var client = http.Client{ .allocator = alloc };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    const buf = try alloc.alloc(u8, 1024 * 1024 * 4);
    defer alloc.free(buf);
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = buf,
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();
    var iter = req.response.iterateHeaders();
    while (iter.next()) |header| {
        std.debug.print("Name:{s}, Value:{s}\n", .{ header.name, header.value });
    }

    try std.testing.expectEqual(req.response.status, .ok);

    const rdr = req.reader();

    try std.fs.cwd().makeDir("extract");
    var dir = try std.fs.cwd().openDir("extract", .{});
    defer dir.close();
    //defer std.fs.cwd().deleteTree("extract");

    // TODO basically, reuse the exact stuff from
    // https://github.com/ziglang/zig/blob/e1c6af2840edc723db8f89522850b6f882f8234f/src/Package/Fetch.zig#L1163
    // nix prefetch flake does it on its own
    // Also git+url?rev is allowed as well I guess in build.zig.zon (at least zon2nix does support it)

    std.tar.pipeToFileSystem(dir, rdr, .{
        .mode_mode = .executable_bit_only,
        .exclude_empty_directories = true,
        .strip_components = 1,
    }) catch |err| {
        std.debug.panic("{?}\n", .{err});
    };

    //const body = try rdr.readAllAlloc(alloc, req.response.content_length orelse 10 * 1024);
    //defer alloc.free(body);
    //try std.io.getStdOut().writer().writeAll(body);
}
