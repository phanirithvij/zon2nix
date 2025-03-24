// ported to zig from tailscale's nardump
// https://github.com/tailscale/tailscale/blob/main/cmd/nardump/nardump.go

// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

// nardump is like nix-store --dump, but in zig, writing a NAR
// file (tar-like, but focused on being reproducible) to stdout
// or to a hash with the --sri flag.
//
// It lets us calculate a Nix sha256 without having Nix available.

// For the format, see:
// https://nix.dev/manual/nix/stable/protocols/nix-archive
// https://gist.github.com/jbeda/5c79d2b1434f0018d693

const std = @import("std");
const fs = std.fs;
const io = std.io;

// narHash gives sha256 sri hash for a directory or a file
pub fn narHash(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});

    const file = try fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();

    if (stat.kind == .directory) {
        try writeNAR(alloc, hash.writer(), path);
    } else {
        const file_buffer = try file.reader().readAllAlloc(alloc, stat.size);
        defer alloc.free(file_buffer);
        try hash.writer().writeAll(file_buffer);
    }

    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const enc = std.base64.standard.Encoder;
    var buf: [44]u8 = undefined;
    _ = enc.encode(&buf, &digest);
    return try std.fmt.allocPrint(alloc, "sha256-{s}", .{buf});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const sri = blk: {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--sri")) break :blk true;
        }
        break :blk false;
    };

    const dir_path = args[args.len - 1];

    if (sri) {
        try io.getStdOut().writer().print("{s}\n", .{try narHash(allocator, dir_path)});
    } else {
        var stdout = io.getStdOut();
        // increase buffer size, does nothing
        var bw = io.BufferedWriter(100 * 1024, fs.File.Writer){ .unbuffered_writer = stdout.writer() };
        try writeNAR(allocator, bw.writer(), dir_path);
        try bw.flush();
    }
}

fn writeDir(alloc: std.mem.Allocator, w: anytype, dir: *fs.Dir, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var it = dir.iterate();
    var entries = std.ArrayList(fs.Dir.Entry).init(arena.allocator());
    defer entries.deinit();

    // next() is a memory destructive method, need to dupe `entry`
    while (try it.next()) |entry| {
        const e = try arena.allocator().create(fs.Dir.Entry);
        e.name = try arena.allocator().dupe(u8, entry.name);
        e.kind = entry.kind;
        try entries.append(e.*);
    }

    std.mem.sort(fs.Dir.Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: fs.Dir.Entry, b: fs.Dir.Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    try writeString(w, "(");
    try writeString(w, "type");
    try writeString(w, "directory");

    for (entries.items) |entry| {
        try writeString(w, "entry");
        try writeString(w, "(");
        try writeString(w, "name");
        try writeString(w, entry.name);
        try writeString(w, "node");

        const full_path = try fs.path.join(arena.allocator(), &[_][]const u8{ path, entry.name });

        switch (entry.kind) {
            .directory => {
                var entry_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer entry_dir.close();
                try writeDir(alloc, w, &entry_dir, full_path);
            },
            .file => try writeFile(alloc, w, full_path),
            .sym_link => try writeSymlink(w, full_path),
            else => return error.UnsupportedFileType,
        }

        try writeString(w, ")");
    }
    try writeString(w, ")");
}

fn writeFile(alloc: std.mem.Allocator, w: anytype, path: []const u8) !void {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();

    try writeString(w, "(");
    try writeString(w, "type");
    try writeString(w, "regular");

    if (stat.mode & 0o111 != 0) {
        try writeString(w, "executable");
        try writeString(w, "");
    }

    try writeString(w, "contents");
    try writeFileContents(alloc, w, file);
    try writeString(w, ")");
}

fn writeSymlink(w: anytype, path: []const u8) !void {
    var target_buf: [fs.max_path_bytes]u8 = undefined;
    const target = try fs.cwd().readLink(path, &target_buf);
    try writeString(w, "(");
    try writeString(w, "type");
    try writeString(w, "symlink");
    try writeString(w, "target");
    try writeString(w, target);
    try writeString(w, ")");
}

fn writeNAR(alloc: std.mem.Allocator, w: anytype, dir_path: []const u8) !void {
    var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    try dir.setAsCwd();
    try writeString(w, "nix-archive-1");
    try writeDir(alloc, w, &dir, ".");
}

fn writeFileContents(alloc: std.mem.Allocator, w: anytype, file: fs.File) !void {
    const stat = try file.stat();
    try w.writeInt(u64, stat.size, .little);

    // nix is by far the fastest, uses least amount of memory, tested for huge archives
    const file_buffer = try file.reader().readAllAlloc(alloc, stat.size);
    defer alloc.free(file_buffer);

    try w.writeAll(file_buffer);

    try writePad(w, @intCast(stat.size));
}

fn writeString(w: anytype, s: []const u8) !void {
    try w.writeInt(u64, s.len, .little);
    try w.writeAll(s);
    try writePad(w, s.len);
}

fn writePad(w: anytype, n: usize) !void {
    const pad = n % 8;
    if (pad == 0) return;
    const zeroes = [_]u8{0} ** 8;
    try w.writeAll(zeroes[0..(8 - pad)]);
}

// TODO fixture and fuzz tests for nar, and unit tests for core functions
