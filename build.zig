pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maybe_vt_mod: ?*std.Build.Module = blk: {
        if (builtin.os.tag == .windows) break :blk @import("buildwindows.zig").createGhosttyWindows(b);
        if (b.lazyDependency("ghostty", .{})) |ghostty| break :blk ghostty.module("ghostty-vt");
        break :blk null;
    };

    const icon_gen_exe = b.addExecutable(.{
        .name = "icon_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/icon_gen.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{
                    .name = "backportflate",
                    .module = b.dependency("zipcmdline", .{}).module("backportflate"),
                },
            },
        }),
    });

    const icons = blk: {
        const run = b.addRunArtifact(icon_gen_exe);
        run.addFileArg(b.path("src/mite.png"));
        break :blk b.createModule(.{
            .root_source_file = run.addOutputFileArg("icon_data.zig"),
        });
    };
    const ico = blk: {
        const run = b.addRunArtifact(icon_gen_exe);
        run.addFileArg(b.path("src/mite.png"));
        break :blk run.addOutputFileArg("mite.ico");
    };

    const main = b.path(switch (target.result.os.tag) {
        .windows => "src/mitewindows.zig",
        else => "src/mite.zig",
    });
    const exe = b.addExecutable(.{
        .name = "mite",
        .root_module = b.createModule(.{
            .root_source_file = main,
            .target = target,
            .optimize = optimize,
            // Windows uses std.Thread for the ConPTY read thread.
            .single_threaded = if (target.result.os.tag == .windows) null else true,
        }),
        .win32_manifest = b.path("src/win32.manifest"),
    });
    addImports(b, target.result, exe.root_module, icons, maybe_vt_mod);

    exe.addWin32ResourceFile(.{
        .file = b.path("src/win32.rc"),
        .include_paths = &.{ico.dirname()},
    });
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
    }

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = main,
            .target = target,
            .optimize = optimize,
        }),
    });
    addImports(b, target.result, tests.root_module, icons, maybe_vt_mod);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

fn addImports(
    b: *std.Build,
    target: std.Target,
    mod: *std.Build.Module,
    icons: *std.Build.Module,
    maybe_vt_mod: ?*std.Build.Module,
) void {
    mod.addImport("icons", icons);
    if (maybe_vt_mod) |vt_mod| mod.addImport("vt", vt_mod);
    switch (target.os.tag) {
        .windows => if (b.lazyDependency("win32", .{})) |win32_dep| {
            mod.addImport("win32", win32_dep.module("win32"));
            mod.addIncludePath(b.path("src"));
        },
        else => {
            if (b.lazyDependency("x11", .{})) |x11_dep| {
                mod.addImport("x11", x11_dep.module("x11"));
            }
            if (b.lazyDependency("TrueType", .{})) |true_type_dep| {
                mod.addImport("TrueType", true_type_dep.module("TrueType"));
            }
        },
    }
    switch (target.os.tag) {
        .linux => if (b.lazyDependency("wayland", .{})) |wayland_dep| {
            mod.addImport("wl", wayland_dep.module("wl"));
        },
        else => {},
    }
}

const builtin = @import("builtin");
const std = @import("std");
