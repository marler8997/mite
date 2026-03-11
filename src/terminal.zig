pub const DisplayServer = union(enum) {
    x11: X11,
    wayland: Wayland,

    pub const X11 = struct {
        sink: *x11.RequestSink,
        window_id: x11.Window,
    };

    pub const Wayland = struct {
        writer: *wl.Writer,
        xdg_toplevel_id: wl.object,
    };

    pub fn setTitle(self: DisplayServer, title: []const u8) error{WriteFailed}!void {
        switch (self) {
            .x11 => |s| try s.sink.ChangeProperty(
                .replace,
                s.window_id,
                .WM_NAME,
                .STRING,
                u8,
                .{ .ptr = title.ptr, .len = @intCast(title.len) },
            ),
            .wayland => |s| try wl.xdg_toplevel.set_title(s.writer, s.xdg_toplevel_id, title),
        }
    }
};

pub const Cursor = struct {
    write_idx: usize = 0,
    line_end: usize = 0,
    max_used: usize = 0, // high-water mark for buffer usage
    dec_graphics: bool = false, // true when G0 is set to DEC Special Graphics (\x1b(0)
    pending_esc: bool = false, // true when previous read ended with incomplete ESC
};

pub const PtyData = struct {
    foo: ?Foo = null,
    const Foo = struct {
        slice: []u8,
        used: usize,
    };

    pub fn read(pty_data: *PtyData, pty_fd: posix.fd_t, cursor: *Cursor, display: DisplayServer) !void {
        const foo: *Foo = blk: {
            if (pty_data.foo == null) {
                pty_data.foo = .{
                    .slice = try posix.mmap(
                        null,
                        std.heap.pageSize(),
                        posix.PROT.READ | posix.PROT.WRITE,
                        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                        -1,
                        0,
                    ),
                    .used = 0,
                };
            }
            break :blk &pty_data.foo.?;
        };

        if (foo.used == foo.slice.len) {
            const new_len = foo.slice.len * 2;
            foo.slice = try posix.mremap(
                @alignCast(foo.slice.ptr),
                foo.slice.len,
                new_len,
                .{ .MAYMOVE = true },
                null,
            );
        }
        const buf = foo.slice[foo.used..];
        const n = posix.read(pty_fd, buf) catch |err| switch (err) {
            error.InputOutput => {
                std.log.info("pty read EIO", .{});
                std.process.exit(0);
            },
            else => |e| return e,
        };
        if (n == 0) {
            std.log.info("shell closed", .{});
            return error.EndOfStream;
        }
        const log_pty = false;
        if (log_pty) std.log.info("pty: {} bytes \"{f}\"", .{ n, std.zig.fmtString(buf[0..n]) });

        try process(foo.slice, foo.used, foo.used + n, cursor, display);
        foo.used = cursor.max_used;
    }
};

pub fn process(
    slice: []u8,
    read_start: usize,
    read_end: usize,
    cursor: *Cursor,
    display: DisplayServer,
) error{WriteFailed}!void {
    var write_idx: usize = cursor.write_idx;
    var line_end: usize = cursor.line_end;
    var max_used: usize = cursor.max_used;
    var read_idx: usize = read_start;
    var rend: usize = read_end;
    // Handle incomplete escape from previous read
    var in_escape = cursor.pending_esc;
    cursor.pending_esc = false;
    while (read_idx < rend) : (read_idx += 1) {
        if (in_escape) {
            in_escape = false;
            if (slice[read_idx] == '[') {
                // CSI sequence: parse parameter bytes then final byte
                read_idx += 1;
                const param_start = read_idx;
                while (read_idx < rend and slice[read_idx] < 0x40) : (read_idx += 1) {}
                // read_idx now points at the final byte
                if (read_idx < rend) {
                    const final = slice[read_idx];
                    const params = slice[param_start..read_idx];
                    // Skip private mode sequences (? or > prefix)
                    if (params.len > 0 and (params[0] == '?' or params[0] == '>' or params[0] == '<')) {
                        // Ignore private mode set/reset (?Nh/?Nl),
                        // XTVERSION (>0q), kitty keyboard (<u), etc.
                    } else {
                        const param = if (params.len == 0) @as(u16, 0) else std.fmt.parseUnsigned(u16, params, 10) catch 0;
                        switch (final) {
                            'A' => { // cursor up
                                const n: u16 = if (param == 0) 1 else param;
                                line_end = @max(write_idx, line_end);
                                max_used = @max(max_used, line_end);
                                const ls = lineStart(slice, write_idx);
                                const col = colAt(slice, ls, write_idx);
                                var target_ls = ls;
                                var moved: u16 = 0;
                                while (moved < n and target_ls > 0) : (moved += 1) {
                                    target_ls -= 1; // skip past the \n
                                    target_ls = lineStart(slice, target_ls);
                                }
                                var target_le = target_ls;
                                while (target_le < max_used and slice[target_le] != '\n') : (target_le += 1) {}
                                write_idx = posAtCol(slice, target_ls, col, target_le);
                                line_end = target_le;
                            },
                            'B' => { // cursor down
                                const n: u16 = if (param == 0) 1 else param;
                                line_end = @max(write_idx, line_end);
                                max_used = @max(max_used, line_end);
                                const ls = lineStart(slice, write_idx);
                                const col = colAt(slice, ls, write_idx);
                                var target_ls = ls;
                                var moved: u16 = 0;
                                while (moved < n) : (moved += 1) {
                                    var nl = target_ls;
                                    while (nl < max_used and slice[nl] != '\n') : (nl += 1) {}
                                    if (nl >= max_used) break;
                                    target_ls = nl + 1;
                                }
                                var target_le = target_ls;
                                while (target_le < max_used and slice[target_le] != '\n') : (target_le += 1) {}
                                write_idx = posAtCol(slice, target_ls, col, target_le);
                                line_end = target_le;
                            },
                            'C' => { // cursor right
                                const n: u16 = if (param == 0) 1 else param;
                                line_end = @max(write_idx, line_end);
                                for (0..n) |_| {
                                    slice[write_idx] = ' ';
                                    write_idx += 1;
                                }
                            },
                            'D' => { // cursor left
                                const n: u16 = if (param == 0) 1 else param;
                                line_end = @max(write_idx, line_end);
                                const ls = lineStart(slice, write_idx);
                                write_idx = if (write_idx >= n) @max(write_idx - n, ls) else ls;
                            },
                            'G' => { // cursor absolute column
                                const target_col: u16 = if (param == 0) 0 else param - 1;
                                line_end = @max(write_idx, line_end);
                                const ls = lineStart(slice, write_idx);
                                write_idx = posAtCol(slice, ls, target_col, @max(write_idx, line_end));
                            },
                            'K' => { // erase in line
                                switch (param) {
                                    0 => { // erase cursor to end
                                        if (line_end > write_idx) {
                                            @memset(slice[write_idx..line_end], ' ');
                                        }
                                        line_end = write_idx;
                                    },
                                    1 => { // erase start to cursor
                                        const ls = lineStart(slice, write_idx);
                                        @memset(slice[ls..write_idx], ' ');
                                    },
                                    2 => { // erase entire line
                                        const ls = lineStart(slice, write_idx);
                                        @memset(slice[ls..@max(write_idx, line_end)], ' ');
                                        line_end = write_idx;
                                    },
                                    else => {},
                                }
                            },
                            'm' => {
                                // Preserve SGR sequence in buffer for renderer
                                const sgr_len = params.len + 3; // \x1b [ params m
                                const write_end = write_idx + sgr_len;
                                // If our write would overwrite unread data, shift it forward
                                if (write_end > read_idx + 1 and read_idx + 1 < rend) {
                                    const remaining = rend - (read_idx + 1);
                                    const shift = write_end - (read_idx + 1);
                                    std.mem.copyBackwards(u8, slice[read_idx + 1 + shift ..][0..remaining], slice[read_idx + 1 ..][0..remaining]);
                                    read_idx += shift;
                                    rend += shift;
                                }
                                // Save params before overwriting
                                var param_buf: [32]u8 = undefined;
                                const saved_params = param_buf[0..params.len];
                                @memcpy(saved_params, params);
                                slice[write_idx] = '\x1b';
                                slice[write_idx + 1] = '[';
                                write_idx += 2;
                                @memcpy(slice[write_idx..][0..saved_params.len], saved_params);
                                write_idx += saved_params.len;
                                slice[write_idx] = 'm';
                                write_idx += 1;
                            },
                            'c' => {}, // device attributes request - TODO: respond
                            'H' => {}, // cursor position - TODO
                            'J' => { // erase in display
                                switch (param) {
                                    0 => { // erase from cursor to end of display
                                        const end = @max(write_idx, @max(line_end, max_used));
                                        if (end > write_idx) {
                                            @memset(slice[write_idx..end], ' ');
                                        }
                                        line_end = write_idx;
                                        max_used = write_idx;
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                    }
                }
                // loop increment will skip the final byte
            } else if (slice[read_idx] == ']') {
                // OSC sequence: parse command number and content
                read_idx += 1;
                const osc_start = read_idx;
                while (read_idx < rend) : (read_idx += 1) {
                    if (slice[read_idx] == '\x07') break;
                    if (slice[read_idx] == '\x1b' and read_idx + 1 < rend and slice[read_idx + 1] == '\\') {
                        read_idx += 1;
                        break;
                    }
                }
                const osc_end = read_idx -| @intFromBool(read_idx > 0 and slice[read_idx] == '\\');
                const osc_content = slice[osc_start..osc_end];
                // OSC 0 (icon name + title) and OSC 2 (title): \x1b]0;title\x07
                if (osc_content.len >= 2 and (osc_content[0] == '0' or osc_content[0] == '2') and osc_content[1] == ';') {
                    const title = osc_content[2..];
                    try display.setTitle(title);
                }
            } else if (slice[read_idx] == 'M') {
                // Reverse Index: move cursor up one line
                line_end = @max(write_idx, line_end);
                max_used = @max(max_used, line_end);
                const ls = lineStart(slice, write_idx);
                if (ls > 0) { // not on first line
                    const col = colAt(slice, ls, write_idx);
                    const prev_ls = lineStart(slice, ls - 1);
                    write_idx = posAtCol(slice, prev_ls, col, ls - 1);
                    line_end = ls - 1;
                }
            } else if (slice[read_idx] == '(') {
                // Character set designation G0
                read_idx += 1;
                if (read_idx < rend) {
                    cursor.dec_graphics = slice[read_idx] == '0';
                }
            }
            // else: unknown escape, skip the one char after ESC
            continue;
        }
        const byte = slice[read_idx];
        switch (byte) {
            '\n' => {
                write_idx = @max(write_idx, line_end);
                slice[write_idx] = '\n';
                write_idx += 1;
                line_end = write_idx;
            },
            '\r' => {
                line_end = @max(write_idx, line_end);
                write_idx = lineStart(slice, write_idx);
            },
            '\x08' => { // cursor back
                const ls = lineStart(slice, write_idx);
                if (write_idx > ls) {
                    line_end = @max(write_idx, line_end);
                    write_idx -= 1;
                }
            },
            '\x07' => {}, // bell
            '\x1b' => {
                // Check if there's a next byte available
                if (read_idx + 1 < rend) {
                    in_escape = true;
                    // Loop increment will advance to the byte after \x1b
                } else {
                    // \x1b at end of read — save for next call
                    cursor.pending_esc = true;
                }
            },
            '\t' => {
                slice[write_idx] = '\t';
                write_idx += 1;
            },
            else => {
                if (byte < 32) {
                    // ignore other control chars
                } else if (byte < 0x80) {
                    // ASCII printable
                    slice[write_idx] = if (cursor.dec_graphics) decGraphicsMap(byte) else byte;
                    write_idx += 1;
                } else if (byte < 0xC0) {
                    // Stray UTF-8 continuation byte, skip
                } else {
                    // UTF-8 lead byte: copy full sequence to buffer
                    const seq_len: usize = if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
                    slice[write_idx] = byte;
                    write_idx += 1;
                    var remaining = seq_len - 1;
                    while (remaining > 0 and read_idx + 1 < rend and slice[read_idx + 1] >= 0x80 and slice[read_idx + 1] < 0xC0) {
                        read_idx += 1;
                        slice[write_idx] = slice[read_idx];
                        write_idx += 1;
                        remaining -= 1;
                    }
                }
            },
        }
    }
    cursor.write_idx = write_idx;
    cursor.line_end = line_end;
    cursor.max_used = @max(max_used, @max(write_idx, line_end));
}

/// Decode a UTF-8 sequence starting at data[0]. Returns the codepoint and byte length.
pub fn decodeUtf8(data: []const u8) struct { codepoint: u21, len: u3 } {
    const b = data[0];
    if (b < 0x80) return .{ .codepoint = b, .len = 1 };
    if (b < 0xC0) return .{ .codepoint = 0xFFFD, .len = 1 }; // stray continuation
    if (b < 0xE0) {
        if (data.len < 2) return .{ .codepoint = 0xFFFD, .len = 1 };
        return .{ .codepoint = (@as(u21, b & 0x1F) << 6) | (data[1] & 0x3F), .len = 2 };
    }
    if (b < 0xF0) {
        if (data.len < 3) return .{ .codepoint = 0xFFFD, .len = 1 };
        return .{ .codepoint = (@as(u21, b & 0x0F) << 12) | (@as(u21, data[1] & 0x3F) << 6) | (data[2] & 0x3F), .len = 3 };
    }
    if (data.len < 4) return .{ .codepoint = 0xFFFD, .len = 1 };
    return .{ .codepoint = (@as(u21, b & 0x07) << 18) | (@as(u21, data[1] & 0x3F) << 12) | (@as(u21, data[2] & 0x3F) << 6) | (data[3] & 0x3F), .len = 4 };
}

/// Find the start of the line containing `pos` (position after the last \n before pos, or 0).
fn lineStart(slice: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and slice[i - 1] != '\n') i -= 1;
    return i;
}

/// Compute the logical column at `pos` within a line starting at `ls`.
/// Skips SGR escape sequences and UTF-8 continuation bytes, expands tabs to tab stops.
fn colAt(slice: []const u8, ls: usize, pos: usize) u16 {
    var col: u16 = 0;
    var i = ls;
    while (i < pos) {
        if (slice[i] == '\x1b' and i + 1 < pos and slice[i + 1] == '[') {
            i += 2;
            while (i < pos and slice[i] < 0x40) : (i += 1) {}
            if (i < pos) i += 1; // skip final byte
        } else if (slice[i] == '\t') {
            col = (col + 8) & ~@as(u16, 7);
            i += 1;
        } else if (slice[i] >= 0x80 and slice[i] < 0xC0) {
            // UTF-8 continuation byte, skip (doesn't add a column)
            i += 1;
        } else {
            col += 1;
            i += 1;
        }
    }
    return col;
}

/// Find the byte position for logical column `target_col` within a line from `ls` to `end`.
fn posAtCol(slice: []const u8, ls: usize, target_col: u16, end: usize) usize {
    var col: u16 = 0;
    var i = ls;
    while (i < end) {
        if (col >= target_col) break;
        if (slice[i] == '\x1b' and i + 1 < end and slice[i + 1] == '[') {
            i += 2;
            while (i < end and slice[i] < 0x40) : (i += 1) {}
            if (i < end) i += 1;
        } else if (slice[i] == '\t') {
            const next_col = (col + 8) & ~@as(u16, 7);
            if (next_col > target_col) break;
            col = next_col;
            i += 1;
        } else if (slice[i] >= 0x80 and slice[i] < 0xC0) {
            // UTF-8 continuation byte, skip
            i += 1;
        } else {
            col += 1;
            i += 1;
        }
    }
    return i;
}

/// Map DEC Special Graphics characters (0x60-0x7E) to ASCII approximations.
/// See: https://en.wikipedia.org/wiki/DEC_Special_Graphics
fn decGraphicsMap(c: u8) u8 {
    return switch (c) {
        '`' => '?', // diamond
        'a' => '#', // checkerboard
        'j' => '+', // lower right corner
        'k' => '+', // upper right corner
        'l' => '+', // upper left corner
        'm' => '+', // lower left corner
        'n' => '+', // crossing
        'o' => '-', // scan line 1
        'p' => '-', // scan line 3
        'q' => '-', // horizontal line
        'r' => '-', // scan line 7
        's' => '-', // scan line 9
        't' => '+', // left tee
        'u' => '+', // right tee
        'v' => '+', // bottom tee
        'w' => '+', // top tee
        'x' => '|', // vertical line
        'y' => '<', // less than or equal
        'z' => '>', // greater than or equal
        '~' => '.', // bullet
        else => c,
    };
}

pub const VisualInfo = struct {
    total_visual_rows: u16,
    cursor_visual_row: i16,
    cursor_visual_col: u16,
};

/// Walk the buffer data to compute visual row counts and cursor position,
/// accounting for line wrapping at num_cols.
pub fn computeVisualInfo(data: []const u8, num_cols: u16, cursor: Cursor) VisualInfo {
    var visual_row: i16 = 0;
    var col: u16 = 0;
    var cursor_visual_row: i16 = 0;
    var cursor_visual_col: u16 = 0;
    var cursor_found = false;
    var i: usize = 0;

    while (i < data.len) {
        switch (data[i]) {
            '\n' => {
                if (!cursor_found and i == cursor.write_idx) {
                    cursor_visual_row = visual_row;
                    cursor_visual_col = col;
                    cursor_found = true;
                }
                visual_row += 1;
                col = 0;
            },
            '\x1b' => {
                if (i + 2 < data.len and data[i + 1] == '[') {
                    i += 2;
                    while (i < data.len and data[i] < 0x40) : (i += 1) {}
                }
            },
            '\t' => {
                if (!cursor_found and i == cursor.write_idx) {
                    cursor_visual_row = visual_row;
                    cursor_visual_col = col;
                    cursor_found = true;
                }
                col = (col + 8) & ~@as(u16, 7);
                if (num_cols > 0 and col >= num_cols) {
                    visual_row += 1;
                    col = 0;
                }
            },
            else => {
                if (data[i] >= 0x80 and data[i] < 0xC0) {
                    // UTF-8 continuation byte, skip
                    i += 1;
                    continue;
                }
                if (data[i] >= 32) {
                    if (num_cols > 0 and col >= num_cols) {
                        visual_row += 1;
                        col = 0;
                    }
                    if (!cursor_found and i == cursor.write_idx) {
                        cursor_visual_row = visual_row;
                        cursor_visual_col = col;
                        cursor_found = true;
                    }
                    col += 1;
                }
            },
        }
        i += 1;
    }

    // Cursor at end of data (or beyond)
    if (!cursor_found) {
        if (num_cols > 0 and col >= num_cols) {
            visual_row += 1;
            col = 0;
        }
        cursor_visual_row = visual_row;
        cursor_visual_col = col;
    }

    const total: u16 = @intCast(@max(cursor_visual_row + 1, visual_row + 1));

    return .{
        .total_visual_rows = total,
        .cursor_visual_row = cursor_visual_row,
        .cursor_visual_col = cursor_visual_col,
    };
}

// Tests
const TestResult = struct {
    buf: [1024]u8 = undefined,
    used: usize = 0,
    cursor: Cursor = .{},
    x11_buf: [4096]u8 = undefined,
    writer: x11.Writer = undefined,
    sink: x11.RequestSink = undefined,

    fn init(self: *TestResult) void {
        self.writer = x11.Writer.fixed(&self.x11_buf);
        self.sink = .{ .writer = &self.writer };
    }

    fn display(self: *TestResult) DisplayServer {
        return .{ .x11 = .{ .sink = &self.sink, .window_id = test_window } };
    }

    fn output(self: *const TestResult) []const u8 {
        return self.buf[0..self.used];
    }

    fn x11Output(self: *const TestResult) []const u8 {
        return self.x11_buf[0..self.writer.end];
    }
};

const test_window: x11.Window = @enumFromInt(1);

fn testProcess(input: []const u8) TestResult {
    var result: TestResult = .{};
    result.init();
    @memcpy(result.buf[0..input.len], input);
    process(&result.buf, 0, input.len, &result.cursor, result.display()) catch unreachable;
    result.used = result.cursor.max_used;
    return result;
}

test "plain text" {
    const r = testProcess("hello");
    try std.testing.expectEqualStrings("hello", r.output());
    try std.testing.expectEqual(@as(usize, 5), r.cursor.write_idx);
}

test "newline" {
    const r = testProcess("ab\ncd");
    try std.testing.expectEqualStrings("ab\ncd", r.output());
    try std.testing.expectEqual(@as(usize, 5), r.cursor.write_idx);
}

test "carriage return overwrites line" {
    const r = testProcess("abc\rxy");
    try std.testing.expectEqualStrings("xyc", r.output());
    try std.testing.expectEqual(@as(usize, 2), r.cursor.write_idx);
}

test "backspace moves cursor back" {
    const r = testProcess("abc\x08");
    try std.testing.expectEqualStrings("abc", r.output());
    try std.testing.expectEqual(@as(usize, 2), r.cursor.write_idx);
}

test "backspace then retype" {
    const r = testProcess("a\x08a");
    try std.testing.expectEqualStrings("a", r.output());
    try std.testing.expectEqual(@as(usize, 1), r.cursor.write_idx);
}

test "cursor left then type overwrites at cursor position" {
    const r = testProcess("a\x1b[Db");
    try std.testing.expectEqualStrings("b", r.output());
    try std.testing.expectEqual(@as(usize, 1), r.cursor.write_idx);
}

test "shell backspace erase sequence across reads" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;
    simWrite(&buf, &used, "$ ", &cursor, disp);
    try std.testing.expectEqualStrings("$ ", buf[0..used]);
    simWrite(&buf, &used, "a", &cursor, disp);
    try std.testing.expectEqualStrings("$ a", buf[0..used]);
    simWrite(&buf, &used, "\x08 \x08", &cursor, disp);
    try std.testing.expectEqualStrings("$  ", buf[0..used]);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx);
    simWrite(&buf, &used, "b", &cursor, disp);
    try std.testing.expectEqualStrings("$ b", buf[0..used]);
    try std.testing.expectEqual(@as(usize, 3), cursor.write_idx);
}

test "backspace erase clears character from buffer" {
    const r = testProcess("a\x08\x1b[K");
    try std.testing.expectEqual(@as(usize, 0), r.cursor.write_idx);
    try std.testing.expectEqual(@as(u8, ' '), r.buf[0]);
}

test "backspace at start does nothing" {
    const r = testProcess("\x08\x08abc");
    try std.testing.expectEqualStrings("abc", r.output());
    try std.testing.expectEqual(@as(usize, 3), r.cursor.write_idx);
}

test "CSI K erases from cursor to end of line" {
    const r = testProcess("abc\x08\x1b[K");
    try std.testing.expectEqualStrings("ab", r.output());
    try std.testing.expectEqual(@as(usize, 2), r.cursor.write_idx);
}

test "SGR sequence preserved in buffer" {
    const r = testProcess("ab\x1b[31mcd");
    try std.testing.expectEqualStrings("ab\x1b[31mcd", r.output());
    try std.testing.expectEqual(@as(usize, 9), r.cursor.write_idx);
}

test "OSC escape sequence stripped (BEL terminated)" {
    const r = testProcess("ab\x1b]0;title\x07cd");
    try std.testing.expectEqualStrings("abcd", r.output());
    try std.testing.expectEqual(@as(usize, 4), r.cursor.write_idx);
}

test "OSC escape sequence stripped (ST terminated)" {
    const r = testProcess("ab\x1b]0;title\x1b\\cd");
    try std.testing.expectEqualStrings("abcd", r.output());
    try std.testing.expectEqual(@as(usize, 4), r.cursor.write_idx);
}

test "tab preserved in buffer" {
    const r = testProcess("ab\tcd");
    try std.testing.expectEqualStrings("ab\tcd", r.output());
    try std.testing.expectEqual(@as(usize, 5), r.cursor.write_idx);
}

test "bell stripped" {
    const r = testProcess("ab\x07cd");
    try std.testing.expectEqualStrings("abcd", r.output());
}

test "carriage return partial overwrite preserves remainder" {
    const r = testProcess("hello\rhi");
    try std.testing.expectEqualStrings("hillo", r.output());
    try std.testing.expectEqual(@as(usize, 2), r.cursor.write_idx);
}

test "carriage return then newline" {
    const r = testProcess("prompt$ \r\noutput\r\nnew$ ");
    try std.testing.expectEqualStrings("prompt$ \noutput\nnew$ ", r.output());
    try std.testing.expectEqual(@as(usize, 21), r.cursor.write_idx);
}

test "multiple SGR sequences preserved" {
    const r = testProcess("\x1b[01;32mhello\x1b[00m");
    try std.testing.expectEqualStrings("\x1b[01;32mhello\x1b[00m", r.output());
    try std.testing.expectEqual(@as(usize, 18), r.cursor.write_idx);
}

test "simulated ls session across multiple reads" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;
    simWrite(&buf, &used, "\x1b[?2004h\x1b]0;user@host: ~/dir\x07\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/dir\x1b[00m$ ", &cursor, disp);
    try std.testing.expectEqualStrings("\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/dir\x1b[00m$ ", buf[0..used]);
    simWrite(&buf, &used, "l", &cursor, disp);
    simWrite(&buf, &used, "s", &cursor, disp);
    try std.testing.expectEqualStrings("\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/dir\x1b[00m$ ls", buf[0..used]);
    simWrite(&buf, &used, "\r\n", &cursor, disp);
    try std.testing.expectEqualStrings("\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/dir\x1b[00m$ ls\n", buf[0..used]);
    simWrite(&buf, &used, "file1\tfile2\r\n", &cursor, disp);
    simWrite(&buf, &used, "\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/dir\x1b[00m$ ", &cursor, disp);
    const expected = "\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/dir\x1b[00m$ ls\nfile1\tfile2\n\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/dir\x1b[00m$ ";
    try std.testing.expectEqualStrings(expected, buf[0..used]);
}

test "OSC 0 sets window title" {
    const r = testProcess("\x1b]0;my terminal title\x07hello");
    try std.testing.expectEqualStrings("hello", r.output());
    const x11_out = r.x11Output();
    try std.testing.expect(x11_out.len >= 24);
    const title_len = std.mem.readInt(u32, x11_out[20..24], .little);
    try std.testing.expectEqual(@as(u32, 17), title_len);
    try std.testing.expectEqualStrings("my terminal title", x11_out[24..][0..title_len]);
}

test "OSC 2 sets window title" {
    const r = testProcess("\x1b]2;another title\x07");
    const x11_out = r.x11Output();
    try std.testing.expect(x11_out.len >= 24);
    const title_len = std.mem.readInt(u32, x11_out[20..24], .little);
    try std.testing.expectEqual(@as(u32, 13), title_len);
    try std.testing.expectEqualStrings("another title", x11_out[24..][0..title_len]);
}

test "OSC title with ST terminator" {
    const r = testProcess("\x1b]0;st title\x1b\\hello");
    try std.testing.expectEqualStrings("hello", r.output());
    const x11_out = r.x11Output();
    try std.testing.expect(x11_out.len >= 24);
    const title_len = std.mem.readInt(u32, x11_out[20..24], .little);
    try std.testing.expectEqualStrings("st title", x11_out[24..][0..title_len]);
}

test "reverse index moves cursor up and overwrites" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;
    simWrite(&buf, &used, "line1\r\nline2\r\n\r\x1bM\x1bM", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 0), cursor.write_idx);

    simWrite(&buf, &used, "LINE1\r\nLINE2\r\n\r\x1bM\x1bM", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 0), cursor.write_idx);
    try std.testing.expectEqualStrings("LINE1\nLINE2\n", buf[0..used]);
}

test "build output pattern: erase display + lines + reverse index" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;

    simWrite(&buf, &used, " \r\n", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // start of line 1

    simWrite(&buf, &used, "\x1b[J" ++ "building foo\r\n" ++ "building bar\r\n" ++ "building baz\r\n" ++ "\r\x1bM\x1bM\x1bM", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // back to line 1

    simWrite(&buf, &used, "\x1b[J" ++ "compiling A\r\n" ++ "compiling B\r\n" ++ "compiling C\r\n" ++ "\r\x1bM\x1bM\x1bM", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // back to line 1

    try std.testing.expectEqualStrings(" \ncompiling A\ncompiling B\ncompiling C\n", buf[0..used]);
}

test "build output: shrinking line count between updates" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;
    simWrite(&buf, &used, " \r\n", &cursor, disp);

    simWrite(&buf, &used, "\x1b[J" ++
        "line1\r\n" ++ "line2\r\n" ++ "line3\r\n" ++
        "line4\r\n" ++ "line5\r\n" ++ "line6\r\n" ++
        "\r\x1bM\x1bM\x1bM\x1bM\x1bM\x1bM", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // back to line 1

    simWrite(&buf, &used, "\x1b[J" ++
        "AAA\r\n" ++ "BBB\r\n" ++ "CCC\r\n" ++
        "DDD\r\n" ++ "EEE\r\n" ++
        "\r\x1bM\x1bM\x1bM\x1bM\x1bM", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // back to line 1

    try std.testing.expectEqualStrings(" \nAAA\nBBB\nCCC\nDDD\nEEE\n", buf[0..used]);
}

test "build output: separate pty reads like real scenario" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;

    simWrite(&buf, &used, " ", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 1), cursor.write_idx);

    simWrite(&buf, &used, "\r\n", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // start of line 1

    simWrite(&buf, &used, "\x1b[?2004l\r", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // still at start of line 1

    simWrite(&buf, &used, "\x1b[?2026h\x1b[J" ++
        "[3] Compile\r\n" ++
        "\x1b(0tq\x1b(B LLVM Emit\r\n" ++
        "\r\x1bM\x1bM" ++
        "\x1b[?2026l", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // back to line 1
    try std.testing.expectEqualStrings(" \n[3] Compile\n+- LLVM Emit\n", buf[0..used]);

    simWrite(&buf, &used, "\x1b[?2026h\x1b[J" ++
        "[7] Linking\r\n" ++
        "\x1b(0mq\x1b(B CodeGen\r\n" ++
        "\r\x1bM\x1bM" ++
        "\x1b[?2026l", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 2), cursor.write_idx); // back to line 1
    try std.testing.expectEqualStrings(" \n[7] Linking\n+- CodeGen\n", buf[0..used]);
}

test "reverse index with prior content preserves write position" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;
    simWrite(&buf, &used, "$ zig build\r\n", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 12), cursor.write_idx); // after "$ zig build\n"

    simWrite(&buf, &used, " \r\n", &cursor, disp);
    try std.testing.expectEqual(@as(usize, 14), cursor.write_idx); // after " \n"

    simWrite(&buf, &used, "\x1b[J" ++
        "line1\r\n" ++ "line2\r\n" ++ "line3\r\n" ++
        "line4\r\n" ++ "line5\r\n" ++ "line6\r\n" ++
        "\r\x1bM\x1bM\x1bM\x1bM\x1bM\x1bM", &cursor, disp);

    try std.testing.expectEqual(@as(usize, 14), cursor.write_idx); // back to line 2
    // max_used includes all content written (lines extend beyond write_idx)
    try std.testing.expect(cursor.max_used > cursor.write_idx);
}

test "cursor right fills with spaces" {
    // CSI C (cursor right) should produce spaces, not leave raw buffer garbage
    const r = testProcess("ab\x1b[3Ccd");
    try std.testing.expectEqualStrings("ab   cd", r.output());
    try std.testing.expectEqual(@as(usize, 7), r.cursor.write_idx);
}

test "cursor right with SGR" {
    // CSI C after SGR should produce spaces between SGR and text
    const r = testProcess("\x1b[31mhello\x1b[1Cworld");
    try std.testing.expectEqualStrings("\x1b[31mhello world", r.output());
}

test "SGR escape split across pty reads" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;
    // First read ends with \x1b (incomplete escape)
    simWrite(&buf, &used, "hello\x1b", &cursor, disp);
    // Second read has the rest of the SGR sequence
    simWrite(&buf, &used, "[2mworld", &cursor, disp);
    // The SGR should be preserved intact, not rendered as visible "[2m" text
    try std.testing.expectEqualStrings("hello\x1b[2mworld", buf[0..used]);
}

test "CSI escape split across pty reads" {
    var buf: [4096]u8 = undefined;
    var cursor: Cursor = .{};
    var x11_buf: [4096]u8 = undefined;
    var writer = x11.Writer.fixed(&x11_buf);
    var sink: x11.RequestSink = .{ .writer = &writer };
    const disp: DisplayServer = .{ .x11 = .{ .sink = &sink, .window_id = test_window } };

    const simWrite = struct {
        fn f(b: *[4096]u8, used: *usize, data: []const u8, cur: *Cursor, d: DisplayServer) void {
            @memcpy(b[used.*..][0..data.len], data);
            process(b, used.*, used.* + data.len, cur, d) catch unreachable;
            used.* = cur.max_used;
        }
    }.f;

    var used: usize = 0;
    // ESC [ split across reads — the erase should still work
    simWrite(&buf, &used, "hello\x1b", &cursor, disp);
    simWrite(&buf, &used, "[K", &cursor, disp);
    // CSI K should erase from cursor to end of line, not write "[K" as text
    try std.testing.expectEqualStrings("hello", buf[0..used]);
    try std.testing.expectEqual(@as(usize, 5), cursor.write_idx);
}

// computeVisualInfo wrapping tests

fn expectVisualInfo(data: []const u8, num_cols: u16, cursor: Cursor, expected: VisualInfo) !void {
    const actual = computeVisualInfo(data, num_cols, cursor);
    try std.testing.expectEqual(expected.total_visual_rows, actual.total_visual_rows);
    try std.testing.expectEqual(expected.cursor_visual_row, actual.cursor_visual_row);
    try std.testing.expectEqual(expected.cursor_visual_col, actual.cursor_visual_col);
}

test "visual: empty buffer" {
    try expectVisualInfo("", 10, .{}, .{ .total_visual_rows = 1, .cursor_visual_row = 0, .cursor_visual_col = 0 });
}

test "visual: short line no wrap" {
    try expectVisualInfo("hello", 10, .{ .write_idx = 5 }, .{ .total_visual_rows = 1, .cursor_visual_row = 0, .cursor_visual_col = 5 });
}

test "visual: line exactly fills columns" {
    // 10 chars in 10 cols: cursor at end wraps to next visual row
    try expectVisualInfo("0123456789", 10, .{ .write_idx = 10 }, .{ .total_visual_rows = 2, .cursor_visual_row = 1, .cursor_visual_col = 0 });
}

test "visual: line wraps once" {
    // 15 chars in 10 cols: cursor at end
    try expectVisualInfo("0123456789abcde", 10, .{ .write_idx = 15 }, .{ .total_visual_rows = 2, .cursor_visual_row = 1, .cursor_visual_col = 5 });
}

test "visual: line wraps twice" {
    // 25 chars in 10 cols: 3 visual rows
    try expectVisualInfo("0123456789" ++ "0123456789" ++ "01234", 10, .{ .write_idx = 25 }, .{ .total_visual_rows = 3, .cursor_visual_row = 2, .cursor_visual_col = 5 });
}

test "visual: cursor in middle of wrapped line" {
    // 15 chars, cursor at byte 5 (first visual row)
    try expectVisualInfo("0123456789abcde", 10, .{ .write_idx = 5 }, .{ .total_visual_rows = 2, .cursor_visual_row = 0, .cursor_visual_col = 5 });
}

test "visual: cursor at wrap boundary" {
    // 15 chars, cursor at byte 10 (start of second visual row)
    try expectVisualInfo("0123456789abcde", 10, .{ .write_idx = 10 }, .{ .total_visual_rows = 2, .cursor_visual_row = 1, .cursor_visual_col = 0 });
}

test "visual: two lines, second wraps" {
    // "abc\n" (4 bytes) + 15 chars, cursor at byte 19
    try expectVisualInfo("abc\n0123456789abcde", 10, .{ .write_idx = 19 }, .{ .total_visual_rows = 3, .cursor_visual_row = 2, .cursor_visual_col = 5 });
}

test "visual: two lines, first wraps" {
    // "0123456789abcde\n" (16 bytes) + "abc", cursor at byte 19
    try expectVisualInfo("0123456789abcde\nabc", 10, .{ .write_idx = 19 }, .{ .total_visual_rows = 3, .cursor_visual_row = 2, .cursor_visual_col = 3 });
}

test "visual: multiple lines with wrapping" {
    // "0123456789abcde\nhello\n" (22 bytes) + 25 chars, cursor at byte 47
    try expectVisualInfo("0123456789abcde\nhello\n" ++ "0123456789" ++ "0123456789" ++ "01234", 10, .{ .write_idx = 47 }, .{ .total_visual_rows = 6, .cursor_visual_row = 5, .cursor_visual_col = 5 });
}

test "visual: SGR sequences don't affect column count" {
    // "\x1b[31m" (5 bytes) + "0123456789" (10 bytes) + "\x1b[0m" (4 bytes) + "abcde" (5 bytes) = 24 bytes
    try expectVisualInfo("\x1b[31m0123456789\x1b[0mabcde", 10, .{ .write_idx = 24 }, .{ .total_visual_rows = 2, .cursor_visual_row = 1, .cursor_visual_col = 5 });
}

test "visual: tab wrapping" {
    // "\t" (1 byte) + "ab" (2 bytes) = 3 bytes, cursor at end
    try expectVisualInfo("\tab", 10, .{ .write_idx = 3 }, .{ .total_visual_rows = 2, .cursor_visual_row = 1, .cursor_visual_col = 0 });
}

test "visual: num_cols 0 means no wrapping" {
    try expectVisualInfo("0123456789abcde", 0, .{ .write_idx = 15 }, .{ .total_visual_rows = 1, .cursor_visual_row = 0, .cursor_visual_col = 15 });
}

test "visual: cursor beyond content on empty line" {
    // "abc\n" with cursor at byte 4 (end of data, on empty line after newline)
    try expectVisualInfo("abc\n", 10, .{ .write_idx = 4 }, .{ .total_visual_rows = 2, .cursor_visual_row = 1, .cursor_visual_col = 0 });
}

test "visual: cursor at end of data same as beyond" {
    // cursor at data.len with write_idx
    try expectVisualInfo("abc\n", 10, .{ .write_idx = 4 }, .{ .total_visual_rows = 2, .cursor_visual_row = 1, .cursor_visual_col = 0 });
}

pub const ScrollbarDrag = struct {
    /// Y offset from the top of the thumb where the drag started
    grab_offset: i16,

    pub fn scrollbackFromY(mouse_y: i16, grab_offset: i16, track_height: u16, win_height: u16, total_rows: u16, visible_rows: u16) u16 {
        const max_scroll = if (total_rows > visible_rows) total_rows - visible_rows else return 0;
        const usable_height = win_height -| track_height;
        if (usable_height == 0) return 0;
        const thumb_top = mouse_y - grab_offset;
        const clamped: u16 = @intCast(std.math.clamp(thumb_top, 0, @as(i16, @intCast(usable_height))));
        const offset: u16 = @intFromFloat(
            @as(f32, @floatFromInt(clamped)) / @as(f32, @floatFromInt(usable_height)) * @as(f32, @floatFromInt(max_scroll)),
        );
        // scroll_back is inverse of offset: offset 0 = scroll_back max, offset max = scroll_back 0
        return max_scroll - offset;
    }
};

const std = @import("std");
const x11 = @import("x11");
const wl = @import("wl");
const posix = std.posix;
