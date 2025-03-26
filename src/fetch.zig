const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ChildProcess = std.process.Child;
const StringHashMap = std.StringHashMap;
const ThreadPool = std.Thread.Pool;
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const json = std.json;
const log = std.log;
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const zig = @import("zig-src");
const Package = zig.Package;
const introspect = zig.introspect;

const nix = @import("options").nix;

const Dependency = @import("Dependency.zig");
const parse = @import("parse.zig").parse;

const Prefetch = struct {
    hash: []const u8,
    storePath: []const u8,
};

const Worker = struct {
    child: *ChildProcess,
    dep: *Dependency,
};

// Adapted from cmdFetch in zig/src/main.zig
// pub fn fetchZig(alloc: Allocator, _: *StringHashMap(Dependency)) !void {
pub fn fetchZig(alloc: Allocator) !void {
    // TODO see if this makes sense
    var arena = std.heap.ArenaAllocator.init(alloc);
    // bug if this is not done
    // bug if it is done
    defer arena.deinit();

    const color: std.zig.Color = .auto;
    const work_around_btrfs_bug = native_os == .linux and std.zig.EnvVar.ZIG_BTRFS_WORKAROUND.isSet();

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{ .allocator = alloc });
    defer thread_pool.deinit();

    var http_client: std.http.Client = .{ .allocator = alloc };
    defer http_client.deinit();

    try http_client.initDefaultProxies(arena.allocator());

    var root_prog_node = std.Progress.start(.{
        .root_name = "Fetch",
    });
    defer root_prog_node.end();

    var global_cache_directory: std.Build.Cache.Directory = l: {
        const p = try introspect.resolveGlobalCacheDir(arena.allocator());
        break :l .{
            .handle = try fs.cwd().makeOpenPath(p, .{}),
            .path = p,
        };
    };
    defer global_cache_directory.handle.close();

    var job_queue: Package.Fetch.JobQueue = .{
        .http_client = &http_client,
        .thread_pool = &thread_pool,
        .global_cache = global_cache_directory,
        .recursive = false,
        .read_only = false,
        .debug_hash = true,
        .work_around_btrfs_bug = work_around_btrfs_bug,
    };
    defer job_queue.deinit();

    var fetch: Package.Fetch = .{
        .arena = arena,
        .location = .{
            .path_or_url = "https://codeberg.org/ifreund/zig-xkbcommon/archive/v0.3.0.tar.gz",
        },
        .location_tok = 0,
        .hash_tok = .none, // for 0.15.0-, 0
        .name_tok = 0,
        .lazy_status = .eager,
        .parent_package_root = undefined,
        .parent_manifest_ast = null,
        .prog_node = root_prog_node,
        .job_queue = &job_queue,
        .omit_missing_hash_error = true,
        .allow_missing_paths_field = false,
        // for 0.14.0- comment two lines
        .allow_missing_fingerprint = true,
        // BLOCKED allow_name_string still breaks previous build.zig.zon format, see ziglang/zig#19500
        // hyphen is not a valid character for names
        // fetch.run() parses the resulting directory's build.zig.zon
        // can I stop right after fetch and not let it go to the parse stage?
        .allow_name_string = true,
        .use_latest_commit = true,

        .package_root = undefined,
        .error_bundle = undefined,
        .manifest = null,
        .manifest_ast = undefined,
        // for 0.14.0- .actual_hash = undefined,
        .computed_hash = undefined,
        .has_build_zig = false,
        .oom_flag = false,
        .latest_commit = null,

        .module = null,
    };
    defer fetch.deinit();

    fetch.run() catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
        error.FetchFailed => {}, // error bundle checked below
    };

    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        errors.renderToStdErr(color.renderOptions());
        std.process.exit(1);
    }

    const package_hash = fetch.computedPackageHash();
    // 0.14.0- const package_hash = Package.Manifest.hexDigest(fetch.actual_hash);

    // TODO this hash is unimportant
    // get the fetch dir and compute hash ourselves using nardump.zig
    std.debug.print("hash {s}\n", .{package_hash.bytes});
    // std.debug.print("hash {s}\n", .{package_hash});
}

pub fn fetchNix(alloc: Allocator, deps: *StringHashMap(Dependency)) !void {
    var workers = try ArrayList(Worker).initCapacity(alloc, deps.count());
    defer workers.deinit();
    var done = false;

    while (!done) {
        var iter = deps.valueIterator();
        while (iter.next()) |dep| {
            if (dep.done) {
                continue;
            }

            var child = try alloc.create(ChildProcess);
            const ref = ref: {
                const base = base: {
                    if (dep.rev) |rev| {
                        break :base try fmt.allocPrint(alloc, "git+{s}?rev={s}", .{ dep.url, rev });
                    } else {
                        break :base try fmt.allocPrint(alloc, "tarball+{s}", .{dep.url});
                    }
                };

                const revi = mem.lastIndexOf(u8, base, "rev=") orelse break :ref base;
                const refi = mem.lastIndexOf(u8, base, "ref=") orelse break :ref base;

                defer alloc.free(base);

                const i = @min(revi, refi);
                break :ref try alloc.dupe(u8, base[0..(i - 1)]);
            };
            defer alloc.free(ref);

            //log.debug("running \"nix flake prefetch --json --extra-experimental-features 'flakes nix-command' {s}\"", .{ref});
            const argv = &[_][]const u8{
                nix,
                "flake",
                "prefetch",
                "--json",
                "--extra-experimental-features",
                "flakes nix-command",
                "--no-use-registries",
                "--flake-registry",
                "",
                ref,
            };
            child.* = ChildProcess.init(argv, alloc);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            try child.spawn();
            try workers.append(.{ .child = child, .dep = dep });
        }

        const len_before = deps.count();
        done = true;

        for (workers.items) |worker| {
            const child = worker.child;
            const dep = worker.dep;

            log.debug("f:{*}\n", .{&dep});

            defer alloc.destroy(child);

            const buf = try child.stdout.?.readToEndAlloc(alloc, std.math.maxInt(usize));
            defer alloc.free(buf);

            //log.debug("hash is {s}", .{buf});
            //log.debug("nix prefetch for \"{s}\" returned: {s}", .{ dep.url, buf });

            const res = try json.parseFromSlice(Prefetch, alloc, buf, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            defer res.deinit();

            switch (try child.wait()) {
                .Exited => |code| if (code != 0) {
                    log.err("{s} exited with code {}", .{ child.argv, code });
                    return error.NixError;
                },
                .Signal => |signal| {
                    log.err("{s} terminated with signal {}", .{ child.argv, signal });
                    return error.NixError;
                },
                .Stopped, .Unknown => {
                    log.err("{s} finished unsuccessfully", .{child.argv});
                    return error.NixError;
                },
            }

            assert(res.value.hash.len != 0);
            //log.debug("hash for \"{s}\" is {s}", .{ dep.url, res.value.hash });

            dep.done = true;

            const path = try fmt.allocPrint(alloc, "{s}" ++ fs.path.sep_str ++ "build.zig.zon", .{res.value.storePath});
            defer alloc.free(path);

            const file = fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer file.close();

            try parse(alloc, deps, file, path);
            if (deps.count() > len_before) {
                done = false;
            }
        }

        workers.clearRetainingCapacity();
    }
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}

test fetchNix {
    //   TODO test for zls and wayprompt
    //   Both should be in fixtures
}

test fetchZig {
    //var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var gpa = std.heap.DebugAllocator(.{}).init;
    const allocator = gpa.allocator();
    try fetchZig(allocator);
    defer _ = gpa.deinit();
    //try fetchZig(std.heap.DebugAllocator(.{}));
}
