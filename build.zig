const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x11_dep = b.dependency("x11", .{});
    const x11 = x11_dep.module("x11");
    const font_mod = x11_dep.module("Font");
    const wl_mod = b.dependency("wayland", .{}).module("wl");

    const exe = b.addExecutable(.{
        .name = "mite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "x11", .module = x11 },
                .{ .name = "wl", .module = wl_mod },
                .{ .name = "Font", .module = font_mod },
            },
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "x11", .module = x11 },
                .{ .name = "wl", .module = wl_mod },
                .{ .name = "Font", .module = font_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
