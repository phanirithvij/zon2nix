const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const file_path = args[1];
    const ofile_path = args[2];

    const file = try std.fs.cwd().openFile(file_path, .{});
    const stat = try file.stat();
    const file_buffer = try file.reader().readAllAlloc(allocator, stat.size);
    defer allocator.free(file_buffer);

    var ofile = try std.fs.cwd().createFile(ofile_path, .{});
    defer ofile.close();

    try ofile.writeAll(file_buffer);
}
