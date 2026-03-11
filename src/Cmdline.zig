const Cmdline = @This();

action: Action = .run,
font: Font = .{ .ttf = null },
font_size: f32 = 16.0,
@"x11-no-render-ext": bool = false,

const Action = enum { run, list_x_cell_fonts, list_x_mono_fonts };

const Font = union(enum) {
    ttf: ?[]const u8, // optional path; null = auto-discover
    xfont: []const u8, // X11 font name/pattern
};

pub fn usage() !void {
    try std.fs.File.stderr().writeAll(
        \\Usage: mite [options]
        \\
        \\Font Options:
        \\  --ttf <path>              Use TrueType font at <path>
        \\  --xfont <name>            Use X11 server font <name>
        \\  --font-size <float>       Font size (scaled by DPI, default: 16.0)
        \\  --list-x-cell-fonts       List available X11 cell-spaced fonts
        \\  --list-x-mono-fonts       List available X11 mono fonts
        \\
        \\Advanced Options:
        \\  --x11-no-ender-ext        Dont use the x11 RENDER extension
        \\
    );
}

pub fn parse() !Cmdline {
    var result: Cmdline = .{};
    var args = std.process.args();
    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ttf")) {
            result.font = .{ .ttf = args.next() orelse errExit("--ttf requires a path argument", .{}) };
        } else if (std.mem.eql(u8, arg, "--xfont")) {
            result.font = .{ .xfont = args.next() orelse errExit("--xfont requires a font name argument", .{}) };
        } else if (std.mem.eql(u8, arg, "--font-size")) {
            const size_str = args.next() orelse errExit("--font-size requires an argument", .{});
            result.font_size = std.fmt.parseFloat(f32, size_str) catch errExit(
                "invalid --font-size '{s}'",
                .{size_str},
            );
            if (result.font_size <= 0) errExit(
                "invalid --font-size  '{d}' (must be positive)",
                .{result.font_size},
            );
            std.log.info("--font-size {d}", .{result.font_size});
        } else if (std.mem.eql(u8, arg, "--list-x-cell-fonts")) {
            result.action = .list_x_cell_fonts;
        } else if (std.mem.eql(u8, arg, "--list-x-mono-fonts")) {
            result.action = .list_x_mono_fonts;
        } else if (std.mem.eql(u8, arg, "--x11-no-render-ext")) {
            result.@"x11-no-render-ext" = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try Cmdline.usage();
            std.process.exit(0);
        } else errExit("unknown cmdline option '{s}'", .{arg});
    }
    return result;
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
