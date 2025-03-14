const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket = b.dependency("websocket", .{
            .target = target,
            .optimize = optimize,
    });

    const lib_mod = b.addModule("zdiscord", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
	lib_mod.addImport("websocket", websocket.module("websocket"));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zdiscord",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
