const std = @import("std");

pub fn createGhosttyWindows(b: *std.Build) *std.Build.Module {
    const zon = @import("build.zig.zon");
    const ghostty_files = ZigFetch.create(b, .{
        .url = zon.dependencies.ghostty.url,
        .hash = zon.dependencies.ghostty.hash,
    });
    const ghostty_path = ghostty_files.getLazyPath();

    // uucode needs a build config and generates tables at build time.
    // We pass ghostty's uucode_config.zig so it generates the right tables.
    const uucode_tables = blk: {
        const uucode = b.dependency("uucode", .{
            .build_config_path = ghostty_path.path(b, "src/build/uucode_config.zig"),
        });
        break :blk uucode.namedLazyPath("tables.zig");
    };

    const mod = b.createModule(.{
        .root_source_file = ghostty_path.path(b, "src/lib_vt.zig"),
    });
    if (b.lazyDependency("uucode", .{
        .tables_path = uucode_tables,
        .build_config_path = ghostty_path.path(b, "src/build/uucode_config.zig"),
    })) |uucode_dep| {
        mod.addImport("uucode", uucode_dep.module("uucode"));
    }

    // Generate unicode tables by running ghostty's codegen executables
    const props_exe = b.addExecutable(.{
        .name = "props-unigen",
        .root_module = b.createModule(.{
            .root_source_file = ghostty_path.path(b, "src/unicode/props_uucode.zig"),
            .target = b.graph.host,
        }),
        .use_llvm = true,
    });
    const symbols_exe = b.addExecutable(.{
        .name = "symbols-unigen",
        .root_module = b.createModule(.{
            .root_source_file = ghostty_path.path(b, "src/unicode/symbols_uucode.zig"),
            .target = b.graph.host,
        }),
        .use_llvm = true,
    });
    if (b.lazyDependency("uucode", .{
        .target = b.graph.host,
        .tables_path = uucode_tables,
        .build_config_path = ghostty_path.path(b, "src/build/uucode_config.zig"),
    })) |uucode_dep| {
        inline for (&.{ props_exe, symbols_exe }) |exe| {
            exe.root_module.addImport("uucode", uucode_dep.module("uucode"));
        }
    }
    const wf = b.addWriteFiles();
    const props_output = wf.addCopyFile(b.addRunArtifact(props_exe).captureStdOut(), "props.zig");
    const symbols_output = wf.addCopyFile(b.addRunArtifact(symbols_exe).captureStdOut(), "symbols.zig");
    mod.addAnonymousImport("unicode_tables", .{ .root_source_file = props_output });
    mod.addAnonymousImport("symbols_tables", .{ .root_source_file = symbols_output });

    const Artifact = enum { ghostty, lib };
    const opts = b.addOptions();
    opts.addOption(Artifact, "artifact", .lib);
    opts.addOption(bool, "c_abi", false);
    opts.addOption(bool, "oniguruma", false);
    opts.addOption(bool, "simd", false);
    opts.addOption(bool, "slow_runtime_safety", false);
    opts.addOption(bool, "kitty_graphics", false);
    opts.addOption(bool, "tmux_control_mode", false);
    mod.addOptions("terminal_options", opts);

    return mod;
}

const ZigFetchOptions = struct {
    url: []const u8,
    hash: []const u8,
};

const ZigFetch = struct {
    step: std.Build.Step,
    url: []const u8,
    hash: []const u8,

    already_fetched: bool,
    pkg_path_dont_use_me_directly: []const u8,
    lazy_fetch_stdout: std.Build.LazyPath,
    generated_directory: std.Build.GeneratedFile,

    fn create(b: *std.Build, opt: ZigFetchOptions) *ZigFetch {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "fetch", opt.url });
        const fetch = b.allocator.create(ZigFetch) catch @panic("OOM");
        const pkg_path = b.pathJoin(&.{
            b.graph.global_cache_root.path.?,
            "p",
            opt.hash,
        });
        const already_fetched = if (std.fs.cwd().access(pkg_path, .{}))
            true
        else |err| switch (err) {
            error.FileNotFound => false,
            else => |e| std.debug.panic("access '{s}' failed with {s}", .{ pkg_path, @errorName(e) }),
        };
        fetch.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("zig fetch {s}", .{opt.url}),
                .owner = b,
                .makeFn = make,
            }),
            .url = b.allocator.dupe(u8, opt.url) catch @panic("OOM"),
            .hash = b.allocator.dupe(u8, opt.hash) catch @panic("OOM"),
            .pkg_path_dont_use_me_directly = pkg_path,
            .already_fetched = already_fetched,
            .lazy_fetch_stdout = run.captureStdOut(),
            .generated_directory = .{
                .step = &fetch.step,
            },
        };
        if (!already_fetched) {
            fetch.step.dependOn(&run.step);
        }
        return fetch;
    }

    fn getLazyPath(self: *const ZigFetch) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.generated_directory } };
    }

    fn make(step: *std.Build.Step, opt: std.Build.Step.MakeOptions) !void {
        _ = opt;
        const b = step.owner;
        const fetch: *ZigFetch = @fieldParentPtr("step", step);
        if (!fetch.already_fetched) {
            const sha = blk: {
                var file = try std.fs.openFileAbsolute(fetch.lazy_fetch_stdout.getPath(b), .{});
                defer file.close();
                break :blk try file.readToEndAlloc(b.allocator, 999);
            };
            const sha_stripped = std.mem.trimRight(u8, sha, "\r\n");
            if (!std.mem.eql(u8, sha_stripped, fetch.hash)) return step.fail(
                "hash mismatch: declared {s} but the fetched package has {s}",
                .{ fetch.hash, sha_stripped },
            );
        }
        fetch.generated_directory.path = fetch.pkg_path_dont_use_me_directly;
    }
};
