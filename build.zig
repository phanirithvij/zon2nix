const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Link mode");

    // TODO: ideally this dependency requirement can be dropped
    // we can rely on zig's builtin fetcher for fetching the dependencies
    // and rely on nardump.go ported to zig, to get sri hashes for archives
    // But this I think beefs up this program's binary size
    const nix = b.option([]const u8, "nix", "Path to the Nix executable") orelse "nix";

    const options = b.addOptions();
    options.addOption([]const u8, "nix", nix);

    // https://github.com/marler8997/anyzig
    const zig_dep = b.dependency("zig", .{});
    const write = b.addWriteFiles();
    // TODO make sure to copy only Fetch related code
    _ = write.addCopyDirectory(zig_dep.path("./src"), "", .{});
    const root = write.addCopyFile(b.path("zigroot/root.zig"), "root.zig");
    const zig_mod = b.createModule(.{
        .root_source_file = root,
    });
    zig_mod.addOptions("build_options", b.addOptions());

    const exe = b.addExecutable(.{
        .name = "zon2nix",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
    });
    exe.root_module.addOptions("options", options);
    exe.root_module.addImport("zig-src", zig_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("zig-src", zig_mod);
    unit_tests.linkage = linkage;
    unit_tests.root_module.addOptions("options", options);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
