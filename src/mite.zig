pub fn main() !void {
    const cmdline = try Cmdline.parse();

    var io_pinned: IoPinned = undefined;
    var backend = blk: {
        const xdg_session_type = std.posix.getenv("XDG_SESSION_TYPE");
        std.log.info("XDG_SESSION_TYPE={?s}", .{xdg_session_type});
        if (std.mem.eql(u8, xdg_session_type orelse "", "wayland"))
            break :blk try wayland_backend.init(&io_pinned, &cmdline);
        if (!std.mem.eql(u8, xdg_session_type orelse "", "x11")) {
            @panic("todo: try wayland");
        }
        break :blk try x11_backend.init(&io_pinned, &cmdline);
    };

    var pty = try Pty.openAndSpawn(backend.cellWidth(), backend.cellHeight());
    defer posix.close(pty.master);
    std.log.info("spawned shell pid={}", .{pty.pid});

    var pty_data: terminal.PtyData = .{};
    var cursor: terminal.Cursor = .{};
    var scroll_back: u16 = 0;
    var scrollbar_drag: ?terminal.ScrollbarDrag = null;
    var focused: bool = true;
    var total_visual_rows: u16 = 1;

    var poll_fds = [_]posix.pollfd{
        .{ .fd = backend.stream.handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 },
    };

    var damaged = false;
    while (true) {
        try backend.flush();
        const ready = try posix.poll(&poll_fds, if (damaged) @as(i32, 0) else -1);
        std.debug.assert(damaged or (ready != 0));
        var handled: usize = 0;

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            handled += 1;
            if (try backend.drain(
                &pty,
                &scroll_back,
                &scrollbar_drag,
                &focused,
                total_visual_rows,
            )) {
                damaged = true;
            }
        }

        if (poll_fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            handled += 1;
            pty_data.read(pty.master, &cursor, backend.displayServer()) catch |err| switch (err) {
                error.EndOfStream => {
                    std.log.info("shell closed", .{});
                    return;
                },
                else => return err,
            };
            damaged = true;
        }
        std.debug.assert(ready == handled);

        if (damaged and ready == 0) {
            total_visual_rows = try backend.render(
                &pty_data,
                cursor,
                scroll_back,
                focused,
            );
            damaged = false;
        }
    }
}

pub const default_fg: u24 = 0xffffff;
pub const default_bg: u24 = 0x2a2a2a;

pub const window_width_pt = 600;
pub const window_height_pt = 400;

pub const ansi_colors = [8]u24{
    0x000000, // black
    0xaa0000, // red
    0x00aa00, // green
    0xaa5500, // yellow/brown
    0x0000aa, // blue
    0xaa00aa, // magenta
    0x00aaaa, // cyan
    0xaaaaaa, // white
};

pub const ansi_bright_colors = [8]u24{
    0x555555, // bright black
    0xff5555, // bright red
    0x55ff55, // bright green
    0xffff55, // bright yellow
    0x5555ff, // bright blue
    0xff55ff, // bright magenta
    0x55ffff, // bright cyan
    0xffffff, // bright white
};

pub fn applySgr(params: []const u8, fg: *u24, bg: *u24, bold: *bool, reverse: *bool) void {
    if (params.len == 0) {
        // \x1b[m is equivalent to \x1b[0m (reset)
        fg.* = default_fg;
        bg.* = default_bg;
        bold.* = false;
        reverse.* = false;
        return;
    }
    var iter = std.mem.splitScalar(u8, params, ';');
    while (iter.next()) |param| {
        const code = std.fmt.parseUnsigned(u8, param, 10) catch continue;
        switch (code) {
            0 => {
                fg.* = default_fg;
                bg.* = default_bg;
                bold.* = false;
                reverse.* = false;
            },
            1 => bold.* = true,
            2 => bold.* = false, // dim - treat as not bold
            7 => reverse.* = true,
            22 => bold.* = false,
            27 => reverse.* = false,
            30...37 => fg.* = if (bold.*) ansi_bright_colors[code - 30] else ansi_colors[code - 30],
            39 => fg.* = default_fg,
            40...47 => bg.* = ansi_colors[code - 40],
            49 => bg.* = default_bg,
            90...97 => fg.* = ansi_bright_colors[code - 90],
            100...107 => bg.* = ansi_bright_colors[code - 100],
            else => {}, // ignore unknown codes
        }
    }
}

pub fn setWinsz(fd: posix.fd_t, cols: u16, rows: u16) void {
    var ws: posix.winsize = .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
    switch (posix.errno(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws)))) {
        .SUCCESS => {},
        else => |e| std.log.err("TIOCSWINSZ failed: {t}", .{e}),
    }
}

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    cols: u16,
    rows: u16,

    pub fn updateWinsz(self: *Pty, cols: u16, rows: u16) void {
        if (cols != self.cols or rows != self.rows) {
            std.log.info("updating winsz from {}x{} to {}x{}", .{ self.cols, self.rows, cols, rows });
            self.cols = cols;
            self.rows = rows;
            setWinsz(self.master, cols, rows);
        }
    }

    pub fn openAndSpawn(cols: u16, rows: u16) !Pty {
        const dev_ptmx = "/dev/ptmx";
        const master = posix.open(dev_ptmx, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0) catch |err| errExit(
            "open '{s}' failed with {t}",
            .{ dev_ptmx, err },
        );
        errdefer posix.close(master);

        // Unlock the slave side (equivalent to unlockpt)
        var unlock: c_int = 0;
        switch (posix.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock)))) {
            .SUCCESS => {},
            else => |e| errExit("IOCSPTLCK failed with {t}", .{e}),
        }

        // Get the slave PTY number
        var pty_num: c_uint = 0;
        switch (posix.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&pty_num)))) {
            .SUCCESS => {},
            else => |e| errExit("IOCGPTN failed with {t}", .{e}),
        }

        // Build slave path: /dev/pts/N
        var pts_path_buf: [32]u8 = undefined;
        const pts_path = std.fmt.bufPrint(&pts_path_buf, "/dev/pts/{}\x00", .{pty_num}) catch unreachable;
        const pts_path_z: [:0]const u8 = pts_path[0 .. pts_path.len - 1 :0];

        setWinsz(master, cols, rows);

        // Fork
        const pid = posix.fork() catch |err| errExit("fork failed with {t}", .{err});
        if (pid == 0) {
            // Child process
            posix.close(master);

            // Create new session
            if (linux.setsid() == -1) errExit("setsid failed", .{});

            // Open the slave — this becomes the controlling terminal
            const slave = posix.open(pts_path_z, .{ .ACCMODE = .RDWR }, 0) catch |err| errExit(
                "open '{s}' failed with {t}",
                .{ pts_path_z, err },
            );

            // Set up stdin/stdout/stderr
            posix.dup2(slave, 0) catch |err| errExit("dup2 stdin failed with {t}", .{err});
            posix.dup2(slave, 1) catch |err| errExit("dup2 stdout failed with {t}", .{err});
            posix.dup2(slave, 2) catch |err| errExit("dup2 stderr failed with {t}", .{err});
            if (slave > 2) posix.close(slave);

            // Exec shell with TERM=xterm-256color
            const shell = posix.getenv("SHELL") orelse "/bin/sh";
            const envp = setTermEnv();
            const err = posix.execvpeZ(
                @ptrCast(shell.ptr),
                &[_:null]?[*:0]const u8{ @ptrCast(shell.ptr), null },
                envp,
            );
            errExit("exec '{s}' failed with {t}", .{ shell, err });
        }

        return .{ .master = master, .pid = pid, .cols = cols, .rows = rows };
    }
};

pub fn setTermEnv() [*:null]?[*:0]const u8 {
    // Try to find and update TERM in place
    for (std.os.environ) |*entry| {
        if (std.mem.startsWith(u8, std.mem.span(entry.*), "TERM=")) {
            entry.* = @ptrCast(@constCast("TERM=xterm-256color"));
            return @ptrCast(std.os.environ.ptr);
        }
    }
    // TERM not found, allocate a new array with one extra entry
    const old_len = std.os.environ.len;
    const new_envp = std.heap.page_allocator.alloc(?[*:0]const u8, old_len + 2) catch
        errExit("failed to allocate envp", .{});
    @memcpy(new_envp[0..old_len], std.os.environ);
    new_envp[old_len] = "TERM=xterm-256color";
    new_envp[old_len + 1] = null;
    return @ptrCast(new_envp.ptr);
}

pub const default_font_paths = [_][]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/TTF/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
    "/usr/share/fonts/truetype/freefont/FreeMono.ttf",
};

pub const IoPinned = struct {
    write_buf: [4096]u8,
    read_buf: [500]u8,
    stream_writer: std.net.Stream.Writer,
    stream_reader: std.net.Stream.Reader,
};

pub const Backend = struct {
    io_pinned: *IoPinned,
    stream: std.net.Stream,
    font_width: u8,
    font_height: u8,

    specific: Specific,

    pub const Specific = union(enum) {
        x11: x11_backend.State,
        wayland: wayland_backend.State,
    };

    pub fn cellWidth(self: *const Backend) u16 {
        return switch (self.specific) {
            .x11 => |*s| s.win_width / self.font_width,
            .wayland => |*s| @intCast(@divTrunc(s.win_width * s.buffer_scale, self.font_width)),
        };
    }
    pub fn cellHeight(self: *const Backend) u16 {
        return switch (self.specific) {
            .x11 => |*s| s.win_height / self.font_height,
            .wayland => |*s| @intCast(@divTrunc(s.win_height * s.buffer_scale, self.font_height)),
        };
    }

    pub fn flush(self: *Backend) !void {
        self.io_pinned.stream_writer.interface.flush() catch {
            return handleWriteErr(&self.io_pinned.stream_writer);
        };
    }

    pub fn drain(self: *Backend, pty: *Pty, scroll_back: *u16, scrollbar_drag: *?terminal.ScrollbarDrag, focused: *bool, total_rows: u16) !bool {
        return switch (self.specific) {
            inline else => |*s| s.drain(self, pty, scroll_back, scrollbar_drag, focused, total_rows),
        };
    }

    pub fn render(self: *Backend, pty_data: *const terminal.PtyData, cursor: terminal.Cursor, scroll_back: u16, focused: bool) !u16 {
        switch (self.specific) {
            inline else => |*s| {
                return s.render(self, pty_data, cursor, scroll_back, focused) catch {
                    try handleWriteErr(&self.io_pinned.stream_writer);
                    unreachable;
                };
            },
        }
    }

    pub fn displayServer(self: *Backend) terminal.DisplayServer {
        return switch (self.specific) {
            inline else => |*s| s.displayServer(self),
        };
    }

    pub fn handleWriteErr(sw: *std.net.Stream.Writer) !void {
        if (sw.err) |e| switch (e) {
            error.BrokenPipe => {
                std.log.info("connection closed", .{});
                std.process.exit(0);
            },
            else => return e,
        };
        unreachable;
    }
};

pub fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const terminal = @import("terminal.zig");
const x11_backend = @import("x11.zig");
const wayland_backend = @import("wayland.zig");
const Cmdline = @import("Cmdline.zig");

comptime {
    _ = @import("terminal.zig");
}
