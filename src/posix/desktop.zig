const std = @import("std");
const icons = @import("icons");

pub fn install() !void {
    var data_home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const data_home = std.posix.getenv("XDG_DATA_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse {
            std.log.warn("can't install desktop files, no $HOME or $XDG_DATA_HOME environment variable", .{});
            return;
        };
        break :blk std.fmt.bufPrint(&data_home_buf, "{s}/.local/share", .{home}) catch
            return error.HomePathTooLong;
    };

    var icons_changed = false;
    for (icons.entries) |entry| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/icons/hicolor/{}x{}/apps/mite.png", .{ data_home, entry.size, entry.size }) catch
            return error.DataHomePathTooLong;
        if (try installFile(path, .{ .png = PngIterator.init(entry.size, entry.idat_zlib) }))
            icons_changed = true;
    }

    const desktop_content =
        \\[Desktop Entry]
        \\Name=Mite
        \\Comment=Terminal Emulator
        \\Exec=mite
        \\Icon=mite
        \\Type=Application
        \\Categories=System;TerminalEmulator;
        \\StartupWMClass=mite
        \\
    ;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const desktop_path = std.fmt.bufPrint(&path_buf, "{s}/applications/mite.desktop", .{data_home}) catch
        return error.DataHomePathTooLong;

    const desktop_changed = try installFile(desktop_path, .{ .slice = desktop_content });

    if (icons_changed or desktop_changed) {
        if (icons_changed) {
            var icon_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const icon_dir = std.fmt.bufPrint(&icon_dir_buf, "{s}/icons/hicolor", .{data_home}) catch
                return error.DataHomePathTooLong;
            runCacheUpdate("gtk-update-icon-cache", icon_dir);
        }
        if (desktop_changed) {
            var apps_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const apps_dir = std.fmt.bufPrint(&apps_dir_buf, "{s}/applications", .{data_home}) catch
                return error.DataHomePathTooLong;
            runCacheUpdate("update-desktop-database", apps_dir);
        }
    }
}

fn installFile(path: []const u8, content: ContentIterator) !bool {
    const changed: FileChanged = switch (try fileStatus(path, content)) {
        .up_to_date => {
            std.log.info("{s}: already installed", .{path});
            return false;
        },
        .not_found => .not_found,
        .outdated => .outdated,
    };

    const dir_path = std.fs.path.dirname(path) orelse return false;
    try std.fs.cwd().makePath(dir_path);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var iter = content;
    while (iter.next()) |chunk| {
        try file.writeAll(chunk);
    }
    std.log.info("{s}: {s}", .{
        path,
        switch (changed) {
            .not_found => "newly installed",
            .outdated => "updated",
        },
    });
    return true;
}

const FileChanged = enum { not_found, outdated };
const FileStatus = enum { not_found, outdated, up_to_date };

fn fileStatus(path: []const u8, content: ContentIterator) !FileStatus {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => return err,
    };
    defer file.close();

    var iter = content;
    var read_buf: [4096]u8 = undefined;
    var read_pos: usize = 0;
    var read_len: usize = 0;

    while (iter.next()) |expected_chunk| {
        var chunk_pos: usize = 0;
        while (chunk_pos < expected_chunk.len) {
            if (read_pos >= read_len) {
                read_len = try file.read(&read_buf);
                read_pos = 0;
                if (read_len == 0) return .outdated;
            }
            const avail = @min(read_len - read_pos, expected_chunk.len - chunk_pos);
            if (!std.mem.eql(u8, read_buf[read_pos..][0..avail], expected_chunk[chunk_pos..][0..avail]))
                return .outdated;
            read_pos += avail;
            chunk_pos += avail;
        }
    }

    // Check file has no extra bytes
    if (read_pos < read_len) return .outdated;
    const trailing = try file.read(&read_buf);
    return if (trailing == 0) .up_to_date else .outdated;
}

const ContentIterator = union(enum) {
    slice: ?[]const u8,
    png: PngIterator,

    fn next(self: *ContentIterator) ?[]const u8 {
        switch (self.*) {
            .slice => |*s| {
                const data = s.* orelse return null;
                s.* = null;
                return data;
            },
            .png => |*p| return p.next(),
        }
    }
};

fn runCacheUpdate(cmd: []const u8, dir: []const u8) void {
    var child = std.process.Child.init(&.{ cmd, dir }, std.heap.page_allocator);
    const term = child.spawnAndWait() catch |err| {
        std.log.warn("failed to run {s}: {}", .{ cmd, err });
        return;
    };
    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                std.log.info("{s}: success", .{cmd});
            } else {
                std.log.warn("{s}: exited with code {}", .{ cmd, code });
            }
        },
        inline else => |sig, tag| {
            std.log.warn("{s}: {s} signal {}", .{ cmd, @tagName(tag), sig });
        },
    }
}

const PngIterator = struct {
    state: u8 = 0,
    idat_zlib: []const u8,
    ihdr: [13]u8,
    buf: [4]u8 = undefined,

    fn init(size: u16, idat_zlib: []const u8) PngIterator {
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], size, .big);
        std.mem.writeInt(u32, ihdr[4..8], size, .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 6; // color type: RGBA
        ihdr[10] = 0; // compression
        ihdr[11] = 0; // filter
        ihdr[12] = 0; // interlace
        return .{ .idat_zlib = idat_zlib, .ihdr = ihdr };
    }

    fn next(self: *PngIterator) ?[]const u8 {
        defer self.state += 1;
        return switch (self.state) {
            0 => &.{ 137, 80, 78, 71, 13, 10, 26, 10 }, // PNG signature
            1 => self.int(u32, 13), // IHDR length
            2 => "IHDR",
            3 => &self.ihdr,
            4 => self.crc("IHDR", &self.ihdr),
            5 => self.int(u32, @intCast(self.idat_zlib.len)), // IDAT length
            6 => "IDAT",
            7 => self.idat_zlib,
            8 => self.crc("IDAT", self.idat_zlib),
            9 => self.int(u32, 0), // IEND length
            10 => "IEND",
            11 => self.crc("IEND", &.{}),
            else => null,
        };
    }

    fn int(self: *PngIterator, comptime T: type, value: T) []const u8 {
        std.mem.writeInt(T, &self.buf, value, .big);
        return &self.buf;
    }

    fn crc(self: *PngIterator, chunk_type: *const [4]u8, data: []const u8) []const u8 {
        var h = std.hash.Crc32.init();
        h.update(chunk_type);
        h.update(data);
        std.mem.writeInt(u32, &self.buf, h.final(), .big);
        return &self.buf;
    }
};
