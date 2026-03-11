const Id = enum {
    display,
    registry,
    callback,
    compositor,
    shm,
    xdg_wm_base,
    seat,
    output,
    surface,
    xdg_surface,
    xdg_toplevel,
    shm_pool,
    buffer,
    keyboard,
    pointer,
};

pub const State = struct {
    ids: wl.IdTable(Id) = .{},
    shm_buf: ShmBuffer = undefined,
    glyph_cache: GlyphCache = .{},
    ttf: TrueType,
    ttf_scale: f32,
    font_ascent: i16,
    win_width: i32,
    win_height: i32,
    buffer_scale: i32,
    mods_ctrl: bool = false,
    mods_shift: bool = false,

    pub fn drain(self: *State, backend: *mite.Backend, pty: *mite.Pty, scroll_back: *u16, scrollbar_drag: *?terminal.ScrollbarDrag, focused: *bool, total_rows: u16) !bool {
        _ = scrollbar_drag;
        var damaged = false;
        const reader = backend.io_pinned.stream_reader.interface();
        const writer = &backend.io_pinned.stream_writer.interface;
        const visible_rows = backend.cellHeight();
        var need_resize = false;
        while (true) {
            const sender, const opcode, const size = wl.readHeader(reader) catch break;
            switch (self.ids.lookup(sender)) {
                .display => switch (opcode) {
                    wl.display.event.@"error" => {
                        const object_id = try reader.takeInt(u32, wl.native_endian);
                        const code = try reader.takeInt(u32, wl.native_endian);
                        const msg_size = try reader.takeInt(u32, wl.native_endian);
                        const msg_word_count = std.mem.alignForward(u32, msg_size, 4);
                        var msg_buf: [400]u8 = undefined;
                        const msg = msg_buf[0..@min(msg_buf.len, msg_size -| 1)];
                        try reader.readSliceAll(msg);
                        try reader.discardAll(msg_word_count - msg.len);
                        std.log.err("display error: object={} code={} message='{s}'", .{ object_id, code, msg });
                        std.process.exit(0xff);
                    },
                    wl.display.event.delete_id => {
                        _ = try reader.takeInt(u32, wl.native_endian);
                    },
                    else => try reader.discardAll(size - 8),
                },
                .xdg_wm_base => switch (opcode) {
                    wl.xdg_wm_base.event.ping => {
                        const serial = try reader.takeInt(u32, wl.native_endian);
                        try wl.xdg_wm_base.pong(writer, self.ids.get(.xdg_wm_base), serial);
                    },
                    else => try reader.discardAll(size - 8),
                },
                .xdg_toplevel => switch (opcode) {
                    wl.xdg_toplevel.event.configure => {
                        const w = try reader.takeInt(i32, wl.native_endian);
                        const h = try reader.takeInt(i32, wl.native_endian);
                        const states_len = try reader.takeInt(u32, wl.native_endian);
                        try reader.discardAll(std.mem.alignForward(u32, states_len, 4));
                        if (w > 0 and h > 0) {
                            if (w != self.win_width or h != self.win_height) {
                                self.win_width = w;
                                self.win_height = h;
                                need_resize = true;
                            }
                        }
                    },
                    wl.xdg_toplevel.event.close => {
                        std.log.info("close requested", .{});
                        std.process.exit(0);
                    },
                    else => try reader.discardAll(size - 8),
                },
                .xdg_surface => switch (opcode) {
                    wl.xdg_surface.event.configure => {
                        const serial = try reader.takeInt(u32, wl.native_endian);
                        try wl.xdg_surface.ack_configure(writer, self.ids.get(.xdg_surface), serial);
                    },
                    else => try reader.discardAll(size - 8),
                },
                .keyboard => switch (opcode) {
                    wl.keyboard.event.keymap => {
                        _ = try reader.takeInt(u32, wl.native_endian); // format
                        _ = try reader.takeInt(u32, wl.native_endian); // size
                    },
                    wl.keyboard.event.enter => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // surface
                        const keys_len = try reader.takeInt(u32, wl.native_endian);
                        try reader.discardAll(std.mem.alignForward(u32, keys_len, 4));
                        focused.* = true;
                        damaged = true;
                    },
                    wl.keyboard.event.leave => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // surface
                        focused.* = false;
                        damaged = true;
                    },
                    wl.keyboard.event.key => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        const key = try reader.takeInt(u32, wl.native_endian);
                        const state = try reader.takeInt(u32, wl.native_endian);
                        if (state == 1 or state == 2) { // pressed or repeated
                            if (self.mods_shift and key == 104) { // Shift+PageUp
                                const max_scroll = if (total_rows > visible_rows) total_rows - visible_rows else 0;
                                scroll_back.* = @min(scroll_back.* +| visible_rows, max_scroll);
                                damaged = true;
                            } else if (self.mods_shift and key == 109) { // Shift+PageDown
                                scroll_back.* -|= visible_rows;
                                damaged = true;
                            } else {
                                if (scroll_back.* != 0) {
                                    scroll_back.* = 0;
                                    damaged = true;
                                }
                                const bytes = evdevKeyToBytes(key, self.mods_shift, self.mods_ctrl);
                                if (bytes.len > 0) {
                                    const written = posix.write(pty.master, bytes) catch |err| std.debug.panic("pty write failed: {}", .{err});
                                    if (written != bytes.len) std.debug.panic("pty short write: {} of {}", .{ written, bytes.len });
                                }
                            }
                        }
                    },
                    wl.keyboard.event.modifiers => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        const mods_depressed = try reader.takeInt(u32, wl.native_endian);
                        _ = try reader.takeInt(u32, wl.native_endian); // mods_latched
                        _ = try reader.takeInt(u32, wl.native_endian); // mods_locked
                        _ = try reader.takeInt(u32, wl.native_endian); // group
                        self.mods_ctrl = (mods_depressed & 0x4) != 0;
                        self.mods_shift = (mods_depressed & 0x1) != 0;
                    },
                    wl.keyboard.event.repeat_info => {
                        _ = try reader.takeInt(u32, wl.native_endian); // rate
                        _ = try reader.takeInt(u32, wl.native_endian); // delay
                    },
                    else => try reader.discardAll(size - 8),
                },
                .pointer => switch (opcode) {
                    wl.pointer.event.button => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        _ = try reader.takeInt(u32, wl.native_endian); // button
                        _ = try reader.takeInt(u32, wl.native_endian); // state
                    },
                    wl.pointer.event.axis => {
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        const axis = try reader.takeInt(u32, wl.native_endian);
                        const value_raw = try reader.takeInt(i32, wl.native_endian);
                        if (axis == 0) { // vertical
                            const scroll_lines: u16 = 4;
                            if (value_raw < 0) { // scroll up
                                const max_scroll = if (total_rows > visible_rows) total_rows - visible_rows else 0;
                                scroll_back.* = @min(scroll_back.* +| scroll_lines, max_scroll);
                                damaged = true;
                            } else if (value_raw > 0) { // scroll down
                                scroll_back.* -|= scroll_lines;
                                damaged = true;
                            }
                        }
                    },
                    wl.pointer.event.enter => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // surface
                        _ = try reader.takeInt(i32, wl.native_endian); // x (fixed)
                        _ = try reader.takeInt(i32, wl.native_endian); // y (fixed)
                    },
                    wl.pointer.event.leave => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // surface
                    },
                    wl.pointer.event.motion => {
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        _ = try reader.takeInt(i32, wl.native_endian); // x
                        _ = try reader.takeInt(i32, wl.native_endian); // y
                    },
                    wl.pointer.event.frame => {},
                    wl.pointer.event.axis_source => {
                        _ = try reader.takeInt(u32, wl.native_endian);
                    },
                    wl.pointer.event.axis_stop => {
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        _ = try reader.takeInt(u32, wl.native_endian); // axis
                    },
                    wl.pointer.event.axis_discrete => {
                        _ = try reader.takeInt(u32, wl.native_endian); // axis
                        _ = try reader.takeInt(i32, wl.native_endian); // discrete
                    },
                    else => try reader.discardAll(size - 8),
                },
                .shm => try reader.discardAll(size - 8),
                .seat => try reader.discardAll(size - 8),
                .buffer => try reader.discardAll(size - 8),
                else => try reader.discardAll(size - 8),
            }
            // Keep draining if the reader has buffered data
            if (reader.seek >= reader.end) break;
        }

        if (need_resize) {
            self.shm_buf.destroy();
            const buf_w: u16 = @intCast(self.win_width * self.buffer_scale);
            const buf_h: u16 = @intCast(self.win_height * self.buffer_scale);
            self.shm_buf = try ShmBuffer.recreate(backend.stream, &backend.io_pinned.stream_writer.interface, &self.ids, buf_w, buf_h);
            pty.updateWinsz(buf_w / backend.font_width, buf_h / backend.font_height);
            damaged = true;
        }
        return damaged;
    }

    pub fn render(self: *State, backend: *mite.Backend, pty_data: *const terminal.PtyData, cursor: terminal.Cursor, scroll_back: u16, focused: bool) !u16 {
        const w: u16 = @intCast(self.win_width * self.buffer_scale);
        const h: u16 = @intCast(self.win_height * self.buffer_scale);
        const total_visual_rows = doRender(
            self.shm_buf.pixel_data,
            w,
            h,
            backend.font_width,
            backend.font_height,
            self.font_ascent,
            &self.glyph_cache,
            self.ttf,
            self.ttf_scale,
            pty_data,
            cursor,
            backend.cellHeight(),
            scroll_back,
            focused,
        );
        const writer = &backend.io_pinned.stream_writer.interface;
        try wl.surface.attach(writer, self.ids.get(.surface), self.ids.get(.buffer), 0, 0);
        try wl.surface.damage(writer, self.ids.get(.surface), 0, 0, self.win_width, self.win_height);
        try wl.surface.commit(writer, self.ids.get(.surface));
        return total_visual_rows;
    }

    pub fn displayServer(self: *State, backend: *mite.Backend) terminal.DisplayServer {
        return .{ .wayland = .{
            .writer = &backend.io_pinned.stream_writer.interface,
            .xdg_toplevel_id = self.ids.get(.xdg_toplevel),
        } };
    }
};

pub fn init(io_pinned: *mite.IoPinned, cmdline: *const Cmdline) !mite.Backend {
    var err: wl.SockaddrError = undefined;
    const addr = wl.getSockaddr(&err) catch {
        std.log.err("{f}", .{err});
        std.process.exit(0xff);
    };
    std.log.info("connecting to '{f}'", .{addr});
    const stream = wl.connect(&addr) catch |e| {
        std.log.err("connect to {f} failed with {s}", .{ addr, @errorName(e) });
        std.process.exit(0xff);
    };

    io_pinned.stream_writer = stream.writer(&io_pinned.write_buf);
    io_pinned.stream_reader = stream.reader(&io_pinned.read_buf);
    const writer = &io_pinned.stream_writer.interface;
    const reader = io_pinned.stream_reader.interface();

    var ids: wl.IdTable(Id) = .{};

    // Request registry and sync
    try wl.display.get_registry(writer, ids.new(.registry));
    try wl.display.sync(writer, ids.new(.callback));
    try writer.flush();

    // Discover globals
    const Object = struct { name: u32, version: u32 };
    var maybe_shm: ?Object = null;
    var maybe_compositor: ?Object = null;
    var maybe_xdg_wm_base: ?Object = null;
    var maybe_seat: ?Object = null;
    var maybe_output: ?Object = null;

    while (true) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .registry => switch (opcode) {
                wl.registry.event.global => {
                    const name = try reader.takeInt(u32, wl.native_endian);
                    const interface_size = try reader.takeInt(u32, wl.native_endian);
                    const interface_word_count = @divTrunc(interface_size + 3, 4);
                    var interface_buf: [400]u8 = undefined;
                    const interface = interface_buf[0..@min(interface_buf.len, interface_size -| 1)];
                    try reader.readSliceAll(interface);
                    try reader.discardAll(interface_word_count * 4 - interface.len);
                    const version = try reader.takeInt(u32, wl.native_endian);
                    std.log.info("registry global name={} interface='{s}' version={}", .{ name, interface, version });
                    if (std.mem.eql(u8, interface, wl.shm.name)) {
                        maybe_shm = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.compositor.name)) {
                        maybe_compositor = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.xdg_wm_base.name)) {
                        maybe_xdg_wm_base = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.seat.name)) {
                        maybe_seat = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.output.name)) {
                        maybe_output = .{ .name = name, .version = version };
                    }
                },
                else => try reader.discardAll(size - 8),
            },
            .callback => switch (opcode) {
                wl.callback.event.done => {
                    _ = try reader.takeInt(u32, wl.native_endian);
                    break;
                },
                else => try reader.discardAll(size - 8),
            },
            else => try reader.discardAll(size - 8),
        }
    }

    // Bind required globals
    const compositor_global = maybe_compositor orelse mite.errExit("no wl_compositor", .{});
    try wl.registry.bind(writer, ids.get(.registry), compositor_global.name, wl.compositor.name, @min(wl.compositor.version, compositor_global.version), ids.new(.compositor));

    const shm_global = maybe_shm orelse mite.errExit("no wl_shm", .{});
    try wl.registry.bind(writer, ids.get(.registry), shm_global.name, wl.shm.name, @min(wl.shm.version, shm_global.version), ids.new(.shm));

    const xdg_wm_base_global = maybe_xdg_wm_base orelse mite.errExit("no xdg_wm_base", .{});
    try wl.registry.bind(writer, ids.get(.registry), xdg_wm_base_global.name, wl.xdg_wm_base.name, @min(wl.xdg_wm_base.version, xdg_wm_base_global.version), ids.new(.xdg_wm_base));

    const seat_global = maybe_seat orelse mite.errExit("no wl_seat", .{});
    try wl.registry.bind(writer, ids.get(.registry), seat_global.name, wl.seat.name, @min(wl.seat.version, seat_global.version), ids.new(.seat));

    const output_global = maybe_output orelse mite.errExit("no wl_output", .{});
    try wl.registry.bind(writer, ids.get(.registry), output_global.name, wl.output.name, @min(wl.output.version, output_global.version), ids.new(.output));

    // Get keyboard and pointer from seat
    try wl.seat.get_keyboard(writer, ids.get(.seat), ids.new(.keyboard));
    try wl.seat.get_pointer(writer, ids.get(.seat), ids.new(.pointer));

    // Roundtrip to receive wl_output events (including scale)
    try wl.display.sync(writer, ids.get(.callback));
    try writer.flush();
    var buffer_scale: i32 = 1;
    while (true) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .output => switch (opcode) {
                wl.output.event.scale => {
                    buffer_scale = try reader.takeInt(i32, wl.native_endian);
                    std.log.info("output scale={}", .{buffer_scale});
                },
                wl.output.event.done => break,
                else => try reader.discardAll(size - 8),
            },
            .callback => switch (opcode) {
                wl.callback.event.done => {
                    _ = try reader.takeInt(u32, wl.native_endian);
                    break;
                },
                else => try reader.discardAll(size - 8),
            },
            else => try reader.discardAll(size - 8),
        }
    }

    // Load TrueType font
    const _100mb: usize = 100 * 1024 * 1024;
    const ttf: TrueType = blk: {
        for (mite.default_font_paths) |path| {
            const ttf_content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, _100mb) catch continue;
            break :blk TrueType.load(ttf_content) catch continue;
        }
        mite.errExit("unable to find monospace ttf font", .{});
    };
    const target_pixel_height: u16 = @intFromFloat(@round(cmdline.font_size * @as(f32, @floatFromInt(buffer_scale))));
    const scale_f = ttf.scaleForPixelHeight(@floatFromInt(target_pixel_height));
    const vm = ttf.verticalMetrics();
    const ascent_f: f32 = @as(f32, @floatFromInt(vm.ascent)) * scale_f;
    const descent_f: f32 = @as(f32, @floatFromInt(vm.descent)) * scale_f;
    const font_ascent: i16 = @intFromFloat(@round(ascent_f));
    const cell_height: u16 = @intFromFloat(@round(ascent_f - descent_f));
    const m_glyph = ttf.codepointGlyphIndex('m');
    const m_metrics = ttf.glyphHMetrics(m_glyph);
    const cell_width: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(m_metrics.advance_width)) * scale_f));
    std.log.info("font: cell={}x{} ascent={}", .{ cell_width, cell_height, font_ascent });

    // Pre-warm glyph cache for ASCII 32-126
    var glyph_cache: GlyphCache = .{};
    for (32..127) |codepoint| {
        const glyph_index: u16 = @intFromEnum(ttf.codepointGlyphIndex(@intCast(codepoint)));
        _ = glyph_cache.getOrRasterize(ttf, scale_f, glyph_index);
    }

    // Create surface
    try wl.compositor.create_surface(writer, ids.get(.compositor), ids.new(.surface));
    try wl.xdg_wm_base.get_xdg_surface(writer, ids.get(.xdg_wm_base), ids.new(.xdg_surface), ids.get(.surface));
    try wl.xdg_surface.get_toplevel(writer, ids.get(.xdg_surface), ids.new(.xdg_toplevel));
    try wl.xdg_toplevel.set_title(writer, ids.get(.xdg_toplevel), "mite");
    // Initial empty commit to get the configure event
    try wl.surface.commit(writer, ids.get(.surface));
    try writer.flush();

    // Wait for initial configure
    var win_width: i32 = mite.window_width_pt;
    var win_height: i32 = mite.window_height_pt;
    var configured = false;
    while (!configured) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .xdg_toplevel => switch (opcode) {
                wl.xdg_toplevel.event.configure => {
                    const w = try reader.takeInt(i32, wl.native_endian);
                    const h = try reader.takeInt(i32, wl.native_endian);
                    const states_len = try reader.takeInt(u32, wl.native_endian);
                    try reader.discardAll(std.mem.alignForward(u32, states_len, 4));
                    if (w > 0 and h > 0) {
                        win_width = @intCast(w);
                        win_height = @intCast(h);
                    }
                },
                else => try reader.discardAll(size - 8),
            },
            .xdg_surface => switch (opcode) {
                wl.xdg_surface.event.configure => {
                    const serial = try reader.takeInt(u32, wl.native_endian);
                    try wl.xdg_surface.ack_configure(writer, ids.get(.xdg_surface), serial);
                    configured = true;
                },
                else => try reader.discardAll(size - 8),
            },
            .xdg_wm_base => switch (opcode) {
                wl.xdg_wm_base.event.ping => {
                    const serial = try reader.takeInt(u32, wl.native_endian);
                    try wl.xdg_wm_base.pong(writer, ids.get(.xdg_wm_base), serial);
                },
                else => try reader.discardAll(size - 8),
            },
            else => try reader.discardAll(size - 8),
        }
    }

    // Create SHM buffer at native pixel resolution
    const buf_width: u16 = @intCast(win_width * buffer_scale);
    const buf_height: u16 = @intCast(win_height * buffer_scale);
    const shm_buf = try ShmBuffer.create(stream, writer, &ids, buf_width, buf_height);

    // Set buffer scale and attach initial buffer
    try wl.surface.set_buffer_scale(writer, ids.get(.surface), buffer_scale);
    try wl.surface.attach(writer, ids.get(.surface), ids.get(.buffer), 0, 0);
    try wl.surface.commit(writer, ids.get(.surface));

    return .{
        .io_pinned = io_pinned,
        .stream = stream,
        .font_width = @intCast(cell_width),
        .font_height = @intCast(cell_height),
        .specific = .{ .wayland = .{
            .ids = ids,
            .shm_buf = shm_buf,
            .glyph_cache = glyph_cache,
            .ttf = ttf,
            .ttf_scale = scale_f,
            .font_ascent = font_ascent,
            .win_width = win_width,
            .win_height = win_height,
            .buffer_scale = buffer_scale,
        } },
    };
}

const GlyphCache = struct {
    // Bitset indexed by TrueType glyph index (u16), 65536 bits = 8KB
    const num_words = 1024;
    // Direct-mapped bitmap storage for glyph indices < max_direct
    const max_direct = 4096;
    bits: [num_words]u64 = .{0} ** num_words,
    bitmaps: [max_direct]GlyphBitmap = undefined,
    pixels: std.ArrayListUnmanaged(u8) = .empty,

    fn isSet(self: *const GlyphCache, glyph_index: u16) bool {
        return self.bits[glyph_index >> 6] & (@as(u64, 1) << @as(u6, @truncate(glyph_index))) != 0;
    }

    fn set(self: *GlyphCache, glyph_index: u16) void {
        self.bits[glyph_index >> 6] |= @as(u64, 1) << @as(u6, @truncate(glyph_index));
    }

    fn getOrRasterize(self: *GlyphCache, ttf: TrueType, scale: f32, glyph_index: u16) ?GlyphBitmap {
        if (self.isSet(glyph_index)) {
            return if (glyph_index < max_direct) self.bitmaps[glyph_index] else null;
        }

        // Rasterize on demand
        self.pixels.clearRetainingCapacity();
        const bitmap = ttf.glyphBitmap(std.heap.page_allocator, &self.pixels, @enumFromInt(glyph_index), scale, scale) catch return null;
        if (bitmap.width == 0 or bitmap.height == 0) {
            self.set(glyph_index); // mark as cached (empty glyph)
            return null;
        }
        const alpha_data = std.heap.page_allocator.alloc(u8, bitmap.width * bitmap.height) catch return null;
        @memcpy(alpha_data, self.pixels.items[0 .. bitmap.width * bitmap.height]);
        const gb: GlyphBitmap = .{
            .data = alpha_data.ptr,
            .width = @intCast(bitmap.width),
            .height = @intCast(bitmap.height),
            .off_x = bitmap.off_x,
            .off_y = bitmap.off_y,
        };
        self.set(glyph_index);
        if (glyph_index < max_direct) {
            self.bitmaps[glyph_index] = gb;
        }
        return gb;
    }
};

const GlyphBitmap = struct {
    data: [*]const u8,
    width: u16,
    height: u16,
    off_x: i16,
    off_y: i16,
};

const ShmBuffer = struct {
    fd: posix.fd_t,
    pixel_data: [*]u32,
    mmap_slice: []align(std.heap.pageSize()) u8,
    width: u16,
    height: u16,

    fn create(stream: std.net.Stream, writer: *wl.Writer, ids: *wl.IdTable(Id), width: u16, height: u16) !ShmBuffer {
        const stride: u32 = @as(u32, width) * 4;
        const shm_size: u32 = stride * @as(u32, height);

        const shm_fd = posix.memfd_createZ("mite-shm", 0) catch |e|
            mite.errExit("memfd_create failed with {s}", .{@errorName(e)});
        posix.ftruncate(shm_fd, shm_size) catch |e|
            mite.errExit("ftruncate failed with {s}", .{@errorName(e)});

        const pixels = posix.mmap(null, shm_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch |e|
            mite.errExit("mmap shm failed with {s}", .{@errorName(e)});

        try writer.flush();
        wl.shm.create_pool(stream, ids.get(.shm), ids.new(.shm_pool), shm_fd, @intCast(shm_size)) catch |e|
            mite.errExit("create_pool failed with {s}", .{@errorName(e)});

        try wl.shm_pool.create_buffer(writer, ids.get(.shm_pool), ids.new(.buffer), 0, width, height, @intCast(stride), .argb8888);
        try wl.shm_pool.destroy(writer, ids.get(.shm_pool));

        return .{
            .fd = shm_fd,
            .pixel_data = @ptrCast(@alignCast(pixels.ptr)),
            .mmap_slice = pixels,
            .width = width,
            .height = height,
        };
    }

    fn recreate(stream: std.net.Stream, writer: *wl.Writer, ids: *wl.IdTable(Id), width: u16, height: u16) !ShmBuffer {
        const stride: u32 = @as(u32, width) * 4;
        const shm_size: u32 = stride * @as(u32, height);

        // Destroy old buffer before reusing the ID
        try wl.buffer.destroy(writer, ids.get(.buffer));

        const shm_fd = posix.memfd_createZ("mite-shm", 0) catch |e|
            mite.errExit("memfd_create failed with {s}", .{@errorName(e)});
        posix.ftruncate(shm_fd, shm_size) catch |e|
            mite.errExit("ftruncate failed with {s}", .{@errorName(e)});

        const pixels = posix.mmap(null, shm_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch |e|
            mite.errExit("mmap shm failed with {s}", .{@errorName(e)});

        try writer.flush();
        wl.shm.create_pool(stream, ids.get(.shm), ids.get(.shm_pool), shm_fd, @intCast(shm_size)) catch |e|
            mite.errExit("create_pool failed with {s}", .{@errorName(e)});

        try wl.shm_pool.create_buffer(writer, ids.get(.shm_pool), ids.get(.buffer), 0, width, height, @intCast(stride), .argb8888);
        try wl.shm_pool.destroy(writer, ids.get(.shm_pool));

        return .{
            .fd = shm_fd,
            .pixel_data = @ptrCast(@alignCast(pixels.ptr)),
            .mmap_slice = pixels,
            .width = width,
            .height = height,
        };
    }

    fn destroy(self: *ShmBuffer) void {
        posix.munmap(self.mmap_slice);
        posix.close(self.fd);
    }
};

fn doRender(
    pixel_data: [*]u32,
    win_width: u16,
    win_height: u16,
    cell_width: u16,
    cell_height: u16,
    font_ascent: i16,
    glyph_cache: *GlyphCache,
    ttf: TrueType,
    ttf_scale: f32,
    pty_data: *const terminal.PtyData,
    cursor: terminal.Cursor,
    visible_rows: u16,
    scroll_back: u16,
    focused: bool,
) u16 {
    // Clear with background color
    const bg_pixel = rgb24ToArgb32(mite.default_bg);
    const total_pixels = @as(usize, win_width) * @as(usize, win_height);
    for (0..total_pixels) |i| {
        pixel_data[i] = bg_pixel;
    }

    const data = if (pty_data.foo) |foo| foo.slice[0..foo.used] else "";
    const num_cols: u16 = if (cell_width > 0) win_width / cell_width else 0;

    const visual_info = terminal.computeVisualInfo(data, num_cols, cursor);

    const auto_offset: i16 = if (visual_info.total_visual_rows >= visible_rows)
        @as(i16, @intCast(visual_info.total_visual_rows)) - @as(i16, @intCast(visible_rows))
    else
        0;
    const scroll_offset: i16 = auto_offset -| @as(i16, @intCast(scroll_back));

    var fg: u24 = mite.default_fg;
    var bg: u24 = mite.default_bg;
    var bold = false;
    var reverse = false;
    var visual_row: i16 = 0;
    var visual_col: u16 = 0;
    var cursor_drawn = false;
    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        switch (byte) {
            '\n' => {
                visual_row += 1;
                visual_col = 0;
                i += 1;
            },
            '\t' => {
                visual_col = (visual_col + 8) & ~@as(u16, 7);
                if (num_cols > 0 and visual_col >= num_cols) {
                    visual_row += 1;
                    visual_col = 0;
                }
                i += 1;
            },
            '\x1b' => {
                if (i + 2 < data.len and data[i + 1] == '[') {
                    const param_start = i + 2;
                    var end = param_start;
                    while (end < data.len and data[end] < 0x40) : (end += 1) {}
                    if (end < data.len and data[end] == 'm') {
                        mite.applySgr(data[param_start..end], &fg, &bg, &bold, &reverse);
                        i = end + 1;
                        continue;
                    }
                }
                i += 1;
            },
            else => {
                // Skip UTF-8 continuation bytes (they don't start a new column)
                if (byte >= 0x80 and byte < 0xC0) {
                    i += 1;
                    continue;
                }
                if (num_cols > 0 and visual_col >= num_cols) {
                    visual_row += 1;
                    visual_col = 0;
                }
                const screen_row = visual_row - scroll_offset;
                if (screen_row >= 0 and screen_row < visible_rows) {
                    const is_cursor = (i == cursor.write_idx);
                    if (is_cursor) cursor_drawn = true;
                    const render_fg = if (reverse) bg else fg;
                    const render_bg = if (reverse) fg else bg;
                    const char_fg: u24 = if (is_cursor and focused) render_bg else render_fg;
                    const char_bg: u24 = if (is_cursor and focused) render_fg else render_bg;
                    // Decode codepoint (ASCII or UTF-8)
                    const codepoint: u21 = if (byte < 0x80) byte else terminal.decodeUtf8(data[i..]).codepoint;
                    putGlyph(pixel_data, win_width, win_height, cell_width, cell_height, font_ascent, glyph_cache, ttf, ttf_scale, screen_row, visual_col, codepoint, char_fg, char_bg);
                    if (is_cursor and !focused) {
                        drawRect(pixel_data, win_width, win_height, @as(i16, @intCast(visual_col)) * @as(i16, @intCast(cell_width)), screen_row * @as(i16, @intCast(cell_height)), cell_width, cell_height, mite.default_fg);
                    }
                }
                visual_col += 1;
                i += 1;
            },
        }
    }

    if (!cursor_drawn) {
        const cursor_screen_row = visual_info.cursor_visual_row - scroll_offset;
        if (cursor_screen_row >= 0 and cursor_screen_row < visible_rows) {
            if (focused) {
                putGlyph(pixel_data, win_width, win_height, cell_width, cell_height, font_ascent, glyph_cache, ttf, ttf_scale, cursor_screen_row, visual_info.cursor_visual_col, ' ', mite.default_bg, mite.default_fg);
            } else {
                drawRect(pixel_data, win_width, win_height, @as(i16, @intCast(visual_info.cursor_visual_col)) * @as(i16, @intCast(cell_width)), cursor_screen_row * @as(i16, @intCast(cell_height)), cell_width, cell_height, mite.default_fg);
            }
        }
    }

    // Draw scrollbar
    const total_vis_rows: u16 = visual_info.total_visual_rows;
    if (total_vis_rows > visible_rows) {
        const scrollbar_width: u16 = 8;
        const scrollbar_x: u16 = win_width -| scrollbar_width;
        const min_track_height: u16 = 20;
        const track_height: u16 = @max(min_track_height, @as(u16, @intFromFloat(
            @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_vis_rows)) * @as(f32, @floatFromInt(win_height)),
        )));
        const max_offset = total_vis_rows - visible_rows;
        const current_offset: u16 = if (max_offset >= scroll_back) max_offset - scroll_back else 0;
        const track_y: u16 = @intFromFloat(
            @as(f32, @floatFromInt(current_offset)) / @as(f32, @floatFromInt(max_offset)) * @as(f32, @floatFromInt(win_height -| track_height)),
        );
        const scrollbar_color: u32 = 0xFF888888;
        for (track_y..@min(@as(u32, track_y) + track_height, win_height)) |y| {
            for (scrollbar_x..win_width) |x| {
                pixel_data[y * @as(usize, win_width) + x] = scrollbar_color;
            }
        }
    }

    return visual_info.total_visual_rows;
}

fn putGlyph(
    pixel_data: [*]u32,
    win_width: u16,
    win_height: u16,
    cell_width: u16,
    cell_height: u16,
    font_ascent: i16,
    glyph_cache: *GlyphCache,
    ttf: TrueType,
    ttf_scale: f32,
    row: i16,
    col: u16,
    codepoint: u21,
    fg: u24,
    bg: u24,
) void {
    const px: i32 = @as(i32, @intCast(col)) * @as(i32, @intCast(cell_width));
    const py: i32 = @as(i32, row) * @as(i32, @intCast(cell_height));

    // Fill cell background
    const bg_pixel = rgb24ToArgb32(bg);
    for (0..cell_height) |dy| {
        const y: i32 = py + @as(i32, @intCast(dy));
        if (y < 0 or y >= win_height) continue;
        const y_u: usize = @intCast(y);
        for (0..cell_width) |dx| {
            const x: i32 = px + @as(i32, @intCast(dx));
            if (x < 0 or x >= win_width) continue;
            const x_u: usize = @intCast(x);
            pixel_data[y_u * @as(usize, win_width) + x_u] = bg_pixel;
        }
    }

    // Draw glyph
    const glyph_index: u16 = @intFromEnum(ttf.codepointGlyphIndex(codepoint));
    const maybe_glyph: ?GlyphBitmap = glyph_cache.getOrRasterize(ttf, ttf_scale, glyph_index);

    if (maybe_glyph) |glyph| {
        const fg_r: u32 = (fg >> 16) & 0xFF;
        const fg_g: u32 = (fg >> 8) & 0xFF;
        const fg_b: u32 = fg & 0xFF;
        const bg_r: u32 = (bg >> 16) & 0xFF;
        const bg_g: u32 = (bg >> 8) & 0xFF;
        const bg_b: u32 = bg & 0xFF;
        for (0..glyph.height) |by| {
            const y: i32 = py + @as(i32, font_ascent) + @as(i32, glyph.off_y) + @as(i32, @intCast(by));
            if (y < 0 or y >= win_height) continue;
            const y_u: usize = @intCast(y);
            for (0..glyph.width) |bx| {
                const x: i32 = px + @as(i32, glyph.off_x) + @as(i32, @intCast(bx));
                if (x < 0 or x >= win_width) continue;
                const x_u: usize = @intCast(x);
                const alpha: u32 = glyph.data[by * glyph.width + bx];
                if (alpha == 0) continue;
                if (alpha == 255) {
                    pixel_data[y_u * @as(usize, win_width) + x_u] = rgb24ToArgb32(fg);
                } else {
                    const inv = 255 - alpha;
                    const r = (fg_r * alpha + bg_r * inv) / 255;
                    const g = (fg_g * alpha + bg_g * inv) / 255;
                    const b = (fg_b * alpha + bg_b * inv) / 255;
                    pixel_data[y_u * @as(usize, win_width) + x_u] = 0xFF000000 | (r << 16) | (g << 8) | b;
                }
            }
        }
    }
}

fn drawRect(pixel_data: [*]u32, win_width: u16, win_height: u16, px: i16, py: i16, w: u16, h: u16, color: u24) void {
    const pixel = rgb24ToArgb32(color);
    // Top and bottom edges
    for (0..w) |dx| {
        const x: i32 = @as(i32, px) + @as(i32, @intCast(dx));
        if (x < 0 or x >= win_width) continue;
        const x_u: usize = @intCast(x);
        if (py >= 0 and py < win_height) {
            pixel_data[@as(usize, @intCast(py)) * @as(usize, win_width) + x_u] = pixel;
        }
        const bot: i32 = @as(i32, py) + @as(i32, @intCast(h)) - 1;
        if (bot >= 0 and bot < win_height) {
            pixel_data[@as(usize, @intCast(bot)) * @as(usize, win_width) + x_u] = pixel;
        }
    }
    // Left and right edges
    for (1..h -| 1) |dy| {
        const y: i32 = @as(i32, py) + @as(i32, @intCast(dy));
        if (y < 0 or y >= win_height) continue;
        const y_u: usize = @intCast(y);
        if (px >= 0 and px < win_width) {
            pixel_data[y_u * @as(usize, win_width) + @as(usize, @intCast(px))] = pixel;
        }
        const right: i32 = @as(i32, px) + @as(i32, @intCast(w)) - 1;
        if (right >= 0 and right < win_width) {
            pixel_data[y_u * @as(usize, win_width) + @as(usize, @intCast(right))] = pixel;
        }
    }
}

fn rgb24ToArgb32(rgb: u24) u32 {
    return 0xFF000000 | @as(u32, rgb);
}

// Evdev keycode to byte mapping for US keyboard layout
fn evdevKeyToBytes(key: u32, shift: bool, ctrl: bool) []const u8 {
    const S = struct {
        var buf: [1]u8 = undefined;
    };

    // Handle Ctrl+letter
    if (ctrl) {
        const char = evdevToChar(key, false);
        if (char != 0) {
            if ((char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z')) {
                S.buf[0] = char & 0x1f;
                return &S.buf;
            }
            if (char >= '@' and char <= '_') {
                S.buf[0] = char & 0x1f;
                return &S.buf;
            }
        }
    }

    // Function keys / special keys
    return switch (key) {
        1 => "\x1b", // ESC
        14 => "\x7f", // Backspace
        15 => "\t", // Tab
        28 => "\r", // Enter
        96 => "\r", // Keypad Enter
        102 => "\x1b[H", // Home
        103 => "\x1b[A", // Up
        104 => "\x1b[5~", // PageUp
        105 => "\x1b[D", // Left
        106 => "\x1b[C", // Right
        107 => "\x1b[F", // End
        108 => "\x1b[B", // Down
        109 => "\x1b[6~", // PageDown
        110 => "\x1b[2~", // Insert
        111 => "\x1b[3~", // Delete
        // Modifier-only keys
        29, 97 => "", // Left/Right Ctrl
        42, 54 => "", // Left/Right Shift
        56, 100 => "", // Left/Right Alt
        125, 126 => "", // Left/Right Super
        58 => "", // CapsLock
        69 => "", // NumLock
        70 => "", // ScrollLock
        else => blk: {
            const char = evdevToChar(key, shift);
            if (char != 0) {
                S.buf[0] = char;
                break :blk &S.buf;
            }
            break :blk "";
        },
    };
}

fn evdevToChar(key: u32, shift: bool) u8 {
    if (shift) {
        return switch (key) {
            2 => '!',
            3 => '@',
            4 => '#',
            5 => '$',
            6 => '%',
            7 => '^',
            8 => '&',
            9 => '*',
            10 => '(',
            11 => ')',
            12 => '_',
            13 => '+',
            16 => 'Q',
            17 => 'W',
            18 => 'E',
            19 => 'R',
            20 => 'T',
            21 => 'Y',
            22 => 'U',
            23 => 'I',
            24 => 'O',
            25 => 'P',
            26 => '{',
            27 => '}',
            30 => 'A',
            31 => 'S',
            32 => 'D',
            33 => 'F',
            34 => 'G',
            35 => 'H',
            36 => 'J',
            37 => 'K',
            38 => 'L',
            39 => ':',
            40 => '"',
            41 => '~',
            43 => '|',
            44 => 'Z',
            45 => 'X',
            46 => 'C',
            47 => 'V',
            48 => 'B',
            49 => 'N',
            50 => 'M',
            51 => '<',
            52 => '>',
            53 => '?',
            57 => ' ',
            else => 0,
        };
    }
    return switch (key) {
        2 => '1',
        3 => '2',
        4 => '3',
        5 => '4',
        6 => '5',
        7 => '6',
        8 => '7',
        9 => '8',
        10 => '9',
        11 => '0',
        12 => '-',
        13 => '=',
        16 => 'q',
        17 => 'w',
        18 => 'e',
        19 => 'r',
        20 => 't',
        21 => 'y',
        22 => 'u',
        23 => 'i',
        24 => 'o',
        25 => 'p',
        26 => '[',
        27 => ']',
        30 => 'a',
        31 => 's',
        32 => 'd',
        33 => 'f',
        34 => 'g',
        35 => 'h',
        36 => 'j',
        37 => 'k',
        38 => 'l',
        39 => ';',
        40 => '\'',
        41 => '`',
        43 => '\\',
        44 => 'z',
        45 => 'x',
        46 => 'c',
        47 => 'v',
        48 => 'b',
        49 => 'n',
        50 => 'm',
        51 => ',',
        52 => '.',
        53 => '/',
        57 => ' ',
        else => 0,
    };
}

const std = @import("std");
const wl = @import("wl");
const mite = @import("mite.zig");
const terminal = @import("terminal.zig");
const Cmdline = @import("Cmdline.zig");
const TrueType = @import("Font").TrueType;
const posix = std.posix;
