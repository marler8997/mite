const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn font(self: Ids) x11.Font {
        return self.base.add(2).font();
    }
    pub fn offscreenPixmap(self: Ids) x11.Pixmap {
        return self.base.add(3).pixmap();
    }
    // XRender resource IDs (used when TrueType fonts are active)
    pub fn tempPixmap(self: Ids) x11.Pixmap {
        return self.base.add(4).pixmap();
    }
    pub fn tempGc(self: Ids) x11.GraphicsContext {
        return self.base.add(5).graphicsContext();
    }
    pub fn backbufPicture(self: Ids) x11.render.Picture {
        return self.base.add(6).picture();
    }
    // Solid color pictures use IDs starting at 7
    pub fn solidPicture(self: Ids, idx: u32) x11.render.Picture {
        return self.base.add(7 + idx).picture();
    }
    // Glyph pictures indexed by TrueType glyph index
    pub fn glyphPicture(self: Ids, glyph_index: u16) x11.render.Picture {
        return self.base.add(@as(u32, 7) + TtfFont.ColorCache.max_colors + glyph_index).picture();
    }
};

const Screen = struct {
    window: x11.Window,
    visual: x11.Visual,
    depth: x11.Depth,
};

pub const State = struct {
    sink: x11.RequestSink,
    source: x11.Source,
    ids: Ids,
    screen: Screen,
    keymap: x11.keymap.Full,
    dpi_scale: f32,
    font_dims: FontDims,
    gc: Gc,
    maybe_render_ext: ?RenderExt,
    maybe_ttf_font_store: ?TtfFont,
    win_width: u16,
    win_height: u16,
    // Pixmap tracking
    pixmap_width: u16,
    pixmap_height: u16,

    pub fn maybeTtfFont(self: *State) ?*TtfFont {
        return if (self.maybe_ttf_font_store != null) &self.maybe_ttf_font_store.? else null;
    }

    pub fn drain(self: *State, backend: *mite.Backend, pty: *mite.Pty, scroll_back: *u16, scrollbar_drag: *?terminal.ScrollbarDrag, focused: *bool, total_rows: u16) !bool {
        var damaged = drainX11Events(&self.source, &self.keymap, pty, &self.win_width, &self.win_height, scroll_back, scrollbar_drag, focused, backend.cellHeight(), total_rows, self.dpi_scale, backend.font_width, backend.font_height) catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed", .{});
                std.process.exit(0);
            },
            else => return err,
        };
        // Recreate offscreen pixmap if window was resized
        if (self.win_width != self.pixmap_width or self.win_height != self.pixmap_height) {
            if (self.maybeTtfFont()) |ttf_font| {
                x11.render.FreePicture(&self.sink, ttf_font.render_ext_opcode, self.ids.backbufPicture()) catch {
                    try mite.Backend.handleWriteErr(&backend.io_pinned.stream_writer);
                    unreachable;
                };
            }
            try self.sink.FreePixmap(self.ids.offscreenPixmap());
            try self.sink.CreatePixmap(self.ids.offscreenPixmap(), self.ids.window().drawable(), .{
                .depth = self.screen.depth,
                .width = self.win_width,
                .height = self.win_height,
            });
            if (self.maybeTtfFont()) |ttf_font| {
                try x11.render.CreatePicture(
                    &self.sink,
                    ttf_font.render_ext_opcode,
                    self.ids.backbufPicture(),
                    self.ids.offscreenPixmap().drawable(),
                    ttf_font.render_ext_screen_format,
                    .{},
                );
                ttf_font.dst_picture = self.ids.backbufPicture();
            }
            self.pixmap_width = self.win_width;
            self.pixmap_height = self.win_height;
            damaged = true;
        }
        return damaged;
    }

    pub fn render(self: *State, backend: *mite.Backend, pty_data: *const terminal.PtyData, cursor: terminal.Cursor, scroll_back: u16, focused: bool) error{WriteFailed}!u16 {
        return try doRender(
            &self.sink,
            self.ids.window(),
            self.ids.gc(),
            self.screen.depth,
            self.font_dims,
            backend.font_width,
            backend.font_height,
            pty_data,
            cursor,
            &self.gc,
            backend.cellHeight(),
            scroll_back,
            self.ids.offscreenPixmap(),
            self.win_width,
            self.win_height,
            self.dpi_scale,
            focused,
            self.maybeTtfFont(),
        );
    }

    pub fn displayServer(self: *State, _: *mite.Backend) terminal.DisplayServer {
        return .{ .x11 = .{ .sink = &self.sink, .window_id = self.ids.window() } };
    }
};

pub fn init(io_pinned: *mite.IoPinned, cmdline: *const Cmdline) !mite.Backend {
    io_pinned.stream_reader, const used_auth = try x11.draft.connect(&io_pinned.read_buf);
    errdefer x11.disconnect(io_pinned.stream_reader.getStream());
    _ = used_auth;
    io_pinned.stream_writer = io_pinned.stream_reader.getStream().writer(&io_pinned.write_buf);
    return init2(io_pinned, cmdline) catch |err| switch (err) {
        error.ReadFailed => return io_pinned.stream_reader.getError().?,
        error.WriteFailed => return io_pinned.stream_writer.err.?,
        else => |e| return e,
    };
}
fn init2(io_pinned: *mite.IoPinned, cmdline: *const Cmdline) !mite.Backend {
    const setup = try x11.readSetupSuccess(io_pinned.stream_reader.interface());
    std.log.info("setup reply {f}", .{setup});
    var source: x11.Source = .initFinishSetup(io_pinned.stream_reader.interface(), &setup);
    const screen: Screen = blk: {
        const screen = try x11.draft.readSetupDynamic(&source, &setup, .{}) orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        break :blk .{
            .window = screen.root,
            .visual = screen.root_visual,
            .depth = x11.Depth.init(screen.root_depth) orelse std.debug.panic(
                "unsupported depth {}",
                .{screen.root_depth},
            ),
        };
    };
    var sink: x11.RequestSink = .{ .writer = &io_pinned.stream_writer.interface };

    if (switch (cmdline.action) {
        .run => null,
        .list_x_cell_fonts => "-*-*-*-*-*-*-*-*-*-*-c-*-*-*",
        .list_x_mono_fonts => "-*-*-*-*-*-*-*-*-*-*-m-*-*-*",
    }) |pattern| {
        try sink.ListFonts(0xffff, .init(pattern.ptr, @intCast(pattern.len)));
        try sink.writer.flush();
        const stdout_file = x11.stdoutFile();
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer: x11.File15.Writer = .init(stdout_file, &stdout_buffer);
        streamFonts(&source, sink.sequence, &stdout_writer.interface) catch |err| switch (err) {
            error.WriteFailed => return stdout_writer.err.?,
            else => |e| return e,
        };
        std.process.exit(0);
    }

    const keyrange: x11.KeycodeRange = try .init(setup.min_keycode, setup.max_keycode);
    const keymap: x11.keymap.Full = try .initSynchronous(&sink, &source, keyrange);

    // Read DPI from X11 RESOURCE_MANAGER property (Xft.dpi)
    const dpi_scale = blk: {
        try sink.GetProperty(screen.window, .{
            .property = .RESOURCE_MANAGER,
            .type = .STRING,
            .offset = 0,
            .len = 1024 * 1024, // up to 4MB
            .delete = false,
        });
        try sink.writer.flush();
        const reply = try source.readSynchronousReply1(sink.sequence);
        break :blk readDpiScale(&source, reply.flexible);
    };
    std.log.info("dpi_scale={d:.2}", .{dpi_scale});

    const scaled_width: u16 = @intFromFloat(@as(f32, @floatFromInt(mite.window_width_pt)) * dpi_scale);
    const scaled_height: u16 = @intFromFloat(@as(f32, @floatFromInt(mite.window_height_pt)) * dpi_scale);

    const ids: Ids = .{ .base = setup.resource_id_base };
    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = screen.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = scaled_width,
            .height = scaled_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = screen.visual,
        },
        .{
            .bg_pixel = screen.depth.rgbFrom24(mite.default_bg),
            .bit_gravity = .north_west,
            .event_mask = .{
                .KeyPress = 1,
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .ButtonMotion = 1,
                .Exposure = 1,
                .StructureNotify = 1,
                .FocusChange = 1,
            },
        },
    );

    const maybe_render_ext: ?RenderExt = blk: {
        if (cmdline.@"x11-no-render-ext") {
            std.log.info("extension '{f}': disabled (cmdline)", .{x11.render.name});
            break :blk null;
        }

        const ext = try x11.draft.synchronousQueryExtension(&source, &sink, x11.render.name) orelse {
            break :blk null;
        };

        // Query version (we need at least 0.10 for CreateSolidFill)
        try x11.render.request.QueryVersion(&sink, ext.opcode_base, 0, 10);
        try sink.writer.flush();
        const version, _ = try source.readSynchronousReplyFull(sink.sequence, .render_QueryVersion);
        std.log.info("extension '{f}': version {}.{}", .{ x11.render.name, version.major, version.minor });
        if (version.major != 0 or version.minor < 10) {
            std.log.info("extension '{f}': disabled (too old)", .{x11.render.name});
            break :blk null;
        }

        // Query pict formats to find A8 and screen-depth formats
        try x11.render.QueryPictFormats(&sink, ext.opcode_base);
        try sink.writer.flush();
        const result, _ = try source.readSynchronousReplyHeader(sink.sequence, .render_QueryPictFormats);

        var a8_format: ?x11.render.PictureFormat = null;
        var screen_format: ?x11.render.PictureFormat = null;
        for (0..result.num_formats) |_| {
            var format: x11.render.PictureFormatInfo = undefined;
            try source.readReply(std.mem.asBytes(&format));
            // A8 format: 8-bit depth, direct type, alpha_mask=0xff
            if (format.depth == 8 and format.direct.alpha_mask == 0xff and a8_format == null) {
                a8_format = format.id;
            }
            // Screen format: matches screen depth
            if (format.depth == screen.depth.byte() and screen_format == null) {
                screen_format = format.id;
            }
        }
        try source.replyDiscard(source.replyRemainingSize());

        if (a8_format == null or screen_format == null) {
            std.log.info(
                "extension '{f}': disabled, required pict formats not found (a8={?d}, screen={?d})",
                .{ x11.render.name, a8_format, screen_format },
            );
            break :blk null;
        }
        break :blk .{ .opcode = ext.opcode_base, .a8_format = a8_format.?, .screen_format = screen_format.? };
    };

    var maybe_ttf_font_store = blk_ttf_font: switch (cmdline.font) {
        .xfont => null,
        .ttf => |maybe_path| {
            const render_ext = &(maybe_render_ext orelse {
                if (maybe_path != null) mite.errExit("--ttf unsupported without the '{f}' extension", .{x11.render.name});
                std.log.info("falling back to xfont (no {f} extension)", .{x11.render.name});
                break :blk_ttf_font null;
            });

            const target_pixel_height: u16 = @intFromFloat(@round(cmdline.font_size * dpi_scale));
            const _100mb: usize = 100 * 1024 * 1024;
            const ttf: TrueType = blk: {
                if (maybe_path) |path| {
                    const ttf_content = std.fs.cwd().readFileAlloc(
                        std.heap.page_allocator,
                        path,
                        _100mb,
                    ) catch |err| mite.errExit("read ttf file '{s}' failed with {s}", .{ path, @errorName(err) });
                    break :blk TrueType.load(ttf_content) catch |err| {
                        std.log.err("load ttf file '{s}' failed with {t}", .{ path, err });
                        return err;
                    };
                }
                for (mite.default_font_paths) |path| {
                    const ttf_content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, _100mb) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => |e| return e,
                    };
                    break :blk TrueType.load(ttf_content) catch |err| {
                        std.log.err("load ttf file '{s}' failed with {t}", .{ path, err });
                        continue;
                    };
                }
                std.log.info("unable to find monospace ttf font, falling back to xfont (use --ttf to specify one)", .{});
                break :blk_ttf_font null;
            };
            break :blk_ttf_font try TtfFont.init(
                ttf,
                target_pixel_height,
                &sink,
                ids,
                render_ext.*,
                screen.window.drawable(),
            );
        },
    };
    const maybe_ttf_font: ?*TtfFont = if (maybe_ttf_font_store) |*tf| tf else null;

    const font_width: u8, const font_height: u8, const font_dims: FontDims = if (maybe_ttf_font) |ttf_font| .{
        @intCast(ttf_font.cell_width),
        @intCast(ttf_font.cell_height),
        .{ .font_left = 0, .font_ascent = ttf_font.ascent },
    } else blk: {
        const font_name: FontName = switch (cmdline.font) {
            .xfont => |name| blk2: {
                var fn_buf: FontName = .{};
                if (name.len > 256) mite.errExit("xfont name too long ({} bytes)", .{name.len});
                fn_buf.len = @intCast(name.len);
                @memcpy(fn_buf.buf[0..name.len], name);
                break :blk2 fn_buf;
            },
            .ttf => try findFont(&sink, &source, dpi_scale),
        };
        std.log.info("selected font: {s}", .{font_name.constSlice()});
        try sink.OpenFont(ids.font(), .{ .ptr = font_name.constSlice().ptr, .len = @intCast(font_name.constSlice().len) });
        try sink.QueryTextExtents(ids.font().fontable(), .initComptime(&[_]u16{'m'}));
        try sink.writer.flush();
        const extents, _ = try source.readSynchronousReplyFull(sink.sequence, .QueryTextExtents);
        std.log.info("text extents: {}", .{extents});
        break :blk .{
            @as(u8, @intCast(extents.overall_width)),
            @as(u8, @intCast(extents.font_ascent + extents.font_descent)),
            .{ .font_left = @intCast(extents.overall_left), .font_ascent = extents.font_ascent },
        };
    };

    const gc: Gc = .{ .fg = mite.default_fg, .bg = mite.default_bg };
    const gc_opts: x11.CreateGcOptions = gc_blk: {
        var opts: x11.CreateGcOptions = .{
            .foreground = screen.depth.rgbFrom24(gc.fg),
            .background = screen.depth.rgbFrom24(gc.bg),
            .graphics_exposures = false,
        };
        if (maybe_ttf_font == null) opts.font = ids.font();
        break :gc_blk opts;
    };
    try sink.CreateGc(ids.gc(), ids.window().drawable(), gc_opts);

    // Set up double buffering via offscreen pixmap + CopyArea
    try sink.CreatePixmap(ids.offscreenPixmap(), ids.window().drawable(), .{
        .depth = screen.depth,
        .width = scaled_width,
        .height = scaled_height,
    });
    if (maybe_ttf_font) |ttf_font| {
        try x11.render.CreatePicture(
            &sink,
            ttf_font.render_ext_opcode,
            ids.backbufPicture(),
            ids.offscreenPixmap().drawable(),
            ttf_font.render_ext_screen_format,
            .{},
        );
        ttf_font.dst_picture = ids.backbufPicture();
    }

    try sink.MapWindow(ids.window());

    std.debug.assert(source.state == .kind);
    return .{
        .io_pinned = io_pinned,
        .stream = io_pinned.stream_reader.getStream(),
        .font_width = font_width,
        .font_height = font_height,
        .specific = .{
            .x11 = .{
                .sink = sink,
                .source = .initAfterSetup(io_pinned.stream_reader.interface()),
                .ids = ids,
                .screen = screen,
                .keymap = keymap,
                .dpi_scale = dpi_scale,
                .font_dims = font_dims,
                .gc = gc,
                .maybe_render_ext = maybe_render_ext,
                .maybe_ttf_font_store = maybe_ttf_font_store,
                .win_width = scaled_width,
                .win_height = scaled_height,
                .pixmap_width = scaled_width,
                .pixmap_height = scaled_height,
            },
        },
    };
}

const FontDims = struct {
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

const Gc = struct {
    fg: u24,
    bg: u24,

    const Opts = struct {
        fg: ?u24 = null,
        bg: ?u24 = null,
    };

    fn update(self: *Gc, sink: *x11.RequestSink, gc: x11.GraphicsContext, depth: x11.Depth, opts: Opts) !void {
        var gc_opts: x11.ChangeGcOptions = .{};
        if (opts.fg) |fg| if (self.fg != fg) {
            self.fg = fg;
            gc_opts.foreground = depth.rgbFrom24(fg);
        };
        if (opts.bg) |bg| if (self.bg != bg) {
            self.bg = bg;
            gc_opts.background = depth.rgbFrom24(bg);
        };
        if (gc_opts.foreground != null or gc_opts.background != null) {
            try sink.ChangeGc(gc, gc_opts);
        }
    }
};

const GlyphRenderer = struct {
    sink: *x11.RequestSink,
    drawable: x11.Drawable,
    gc: x11.GraphicsContext,
    depth: x11.Depth,
    font_dims: FontDims,
    font_width: u8,
    font_height: u8,
    gc_state: *Gc,
    maybe_ttf_font: ?*TtfFont,

    fn put(self: *GlyphRenderer, row: i16, col: u16, codepoint: u21, fg: u24, bg: u24) !void {
        if (self.maybe_ttf_font) |ttf_font| {
            return ttf_font.putGlyph(self.sink, row, col, codepoint, fg, bg);
        }
        // X11 server font fallback (ASCII only)
        const char: u8 = if (codepoint < 128) @intCast(codepoint) else '?';
        try self.gc_state.update(self.sink, self.gc, self.depth, .{ .fg = fg, .bg = bg });
        const px: i16 = self.font_dims.font_left + @as(i16, @intCast(col)) * @as(i16, @intCast(self.font_width));
        const py: i16 = self.font_dims.font_ascent + row * @as(i16, @intCast(self.font_height));
        try self.sink.ImageText8(
            self.drawable,
            self.gc,
            .{ .x = px, .y = py },
            .{ .ptr = @ptrCast(&char), .len = 1 },
        );
    }
};

const RenderExt = struct {
    opcode: u8,
    a8_format: x11.render.PictureFormat,
    screen_format: x11.render.PictureFormat,
};

const TtfFont = struct {
    cell_width: u16,
    cell_height: u16,
    ascent: i16,
    scale: f32,
    ttf: TrueType,
    render_ext_opcode: u8,
    render_ext_a8_format: x11.render.PictureFormat,
    render_ext_screen_format: x11.render.PictureFormat,
    dst_picture: x11.render.Picture,
    ids: Ids,
    color_cache: ColorCache,
    glyph_cache: GlyphCache,

    const ColorCache = struct {
        colors: [max_colors]u24 = undefined,
        pictures: [max_colors]x11.render.Picture = undefined,
        count: u32 = 0,
        const max_colors = 64;

        fn getOrCreate(self: *ColorCache, sink: *x11.RequestSink, ext_opcode: u8, ids: Ids, rgb: u24) !x11.render.Picture {
            for (0..self.count) |i| {
                if (self.colors[i] == rgb) return self.pictures[i];
            }
            if (self.count >= max_colors) {
                // Evict oldest entry
                x11.render.FreePicture(sink, ext_opcode, self.pictures[0]) catch {};
                for (1..self.count) |i| {
                    self.colors[i - 1] = self.colors[i];
                    self.pictures[i - 1] = self.pictures[i];
                }
                self.count -= 1;
            }
            const pic = ids.solidPicture(self.count);
            try x11.render.CreateSolidFill(sink, ext_opcode, pic, x11.render.Color.fromRgb24(rgb));
            self.colors[self.count] = rgb;
            self.pictures[self.count] = pic;
            self.count += 1;
            return pic;
        }
    };

    const GlyphCache = struct {
        // Bitset indexed by TrueType glyph index (u16), 65536 bits = 8KB
        const num_words = 1024;
        bits: [num_words]u64 = .{0} ** num_words,
        pixels: std.ArrayListUnmanaged(u8) = .empty,

        fn isSet(self: *const GlyphCache, glyph_index: u16) bool {
            return self.bits[glyph_index >> 6] & (@as(u64, 1) << @as(u6, @truncate(glyph_index))) != 0;
        }

        fn set(self: *GlyphCache, glyph_index: u16) void {
            self.bits[glyph_index >> 6] |= @as(u64, 1) << @as(u6, @truncate(glyph_index));
        }

        fn getOrCreate(
            self: *GlyphCache,
            sink: *x11.RequestSink,
            font: *TtfFont,
            glyph_index: u16,
        ) !?x11.render.Picture {
            const pic = font.ids.glyphPicture(glyph_index);
            if (self.isSet(glyph_index)) return pic;

            // Cache miss — rasterize and upload
            self.pixels.clearRetainingCapacity();
            const bitmap = font.ttf.glyphBitmap(std.heap.page_allocator, &self.pixels, @enumFromInt(glyph_index), font.scale, font.scale) catch return null;
            if (bitmap.width == 0 or bitmap.height == 0) return null;

            // Stream scanlines directly to X11 via PutImageStart/Finish
            const scanline: u18 = std.mem.alignForward(u18, font.cell_width, 4);
            const padded_size: u18 = scanline * font.cell_height;
            const pad_len = sink.PutImageStart(padded_size, .{
                .format = .z_pixmap,
                .drawable = font.ids.tempPixmap().drawable(),
                .gc_id = font.ids.tempGc(),
                .width = font.cell_width,
                .height = font.cell_height,
                .x = 0,
                .y = 0,
                .depth = .@"8",
            }) catch return null;

            const gx: i16 = bitmap.off_x;
            const gy: i16 = font.ascent + bitmap.off_y;
            const pad_per_line = scanline - font.cell_width;
            for (0..font.cell_height) |cy_usize| {
                const cy: i32 = @intCast(cy_usize);
                const by = cy - gy;
                if (by >= 0 and by < bitmap.height) {
                    const src_row = self.pixels.items[@as(usize, @intCast(by)) * bitmap.width ..][0..bitmap.width];
                    for (0..font.cell_width) |cx_usize| {
                        const cx: i32 = @intCast(cx_usize);
                        const bx = cx - gx;
                        const alpha: u8 = if (bx >= 0 and bx < bitmap.width) src_row[@intCast(bx)] else 0;
                        try sink.writer.writeAll(&.{alpha});
                    }
                } else {
                    try sink.writer.splatByteAll(0, font.cell_width);
                }
                try sink.writer.splatByteAll(0, pad_per_line);
            }
            try sink.PutImageFinish(pad_len);

            x11.render.CreatePicture(
                sink,
                font.render_ext_opcode,
                pic,
                font.ids.tempPixmap().drawable(),
                font.render_ext_a8_format,
                .{},
            ) catch return null;

            // Picture now references the pixmap data, need fresh pixmap for next glyph
            sink.FreePixmap(font.ids.tempPixmap()) catch {};
            sink.CreatePixmap(font.ids.tempPixmap(), font.ids.window().drawable(), .{
                .depth = .@"8",
                .width = font.cell_width,
                .height = font.cell_height,
            }) catch {};

            self.set(glyph_index);
            return pic;
        }
    };

    fn init(
        ttf: TrueType,
        target_pixel_height: u16,
        sink: *x11.RequestSink,
        ids: Ids,
        render_ext: RenderExt,
        screen: x11.Drawable,
    ) !TtfFont {
        const scale = ttf.scaleForPixelHeight(@floatFromInt(target_pixel_height));
        const vm = ttf.verticalMetrics();
        const ascent_f: f32 = @as(f32, @floatFromInt(vm.ascent)) * scale;
        const descent_f: f32 = @as(f32, @floatFromInt(vm.descent)) * scale;
        const ascent: i16 = @intFromFloat(@round(ascent_f));
        const cell_height: u16 = @intFromFloat(@round(ascent_f - descent_f));

        const m_glyph = ttf.codepointGlyphIndex('m');
        const m_metrics = ttf.glyphHMetrics(m_glyph);
        const cell_width: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(m_metrics.advance_width)) * scale));

        std.log.info("TrueType font: cell={}x{} ascent={}", .{ cell_width, cell_height, ascent });

        // Create temp 8-bit pixmap and GC for uploading alpha masks
        try sink.CreatePixmap(ids.tempPixmap(), screen, .{
            .depth = .@"8",
            .width = cell_width,
            .height = cell_height,
        });
        try sink.CreateGc(ids.tempGc(), ids.tempPixmap().drawable(), .{});

        var result: TtfFont = .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .ascent = ascent,
            .scale = scale,
            .ttf = ttf,
            .render_ext_opcode = render_ext.opcode,
            .render_ext_a8_format = render_ext.a8_format,
            .render_ext_screen_format = render_ext.screen_format,
            .dst_picture = .none, // set after drawable is known
            .ids = ids,
            .color_cache = .{},
            .glyph_cache = .{},
        };

        // Pre-warm cache for ASCII glyphs
        for (32..127) |codepoint| {
            const glyph_index: u16 = @intFromEnum(ttf.codepointGlyphIndex(@intCast(codepoint)));
            _ = result.glyph_cache.getOrCreate(sink, &result, glyph_index) catch continue;
        }

        return result;
    }

    fn putGlyph(self: *TtfFont, sink: *x11.RequestSink, row: i16, col: u16, codepoint: u21, fg: u24, bg: u24) !void {
        const px: i16 = @as(i16, @intCast(col)) * @as(i16, @intCast(self.cell_width));
        const py: i16 = row * @as(i16, @intCast(self.cell_height));
        const w = self.cell_width;
        const h = self.cell_height;
        const ext = self.render_ext_opcode;

        // Fill background
        try x11.render.FillRectangles(sink, ext, .{
            .picture_operation = .src,
            .dst_picture = self.dst_picture,
            .color = x11.render.Color.fromRgb24(bg),
            .rects = .init(@ptrCast(&x11.Rectangle{ .x = px, .y = py, .width = w, .height = h }), 1),
        });

        // Look up glyph by TrueType glyph index (unified cache for ASCII and Unicode)
        const glyph_index: u16 = @intFromEnum(self.ttf.codepointGlyphIndex(codepoint));
        const mask_picture: ?x11.render.Picture = self.glyph_cache.getOrCreate(sink, self, glyph_index) catch null;

        if (mask_picture) |mask_pic| {
            const fg_pic = try self.color_cache.getOrCreate(sink, ext, self.ids, fg);
            try x11.render.Composite(sink, ext, .{
                .picture_operation = .over,
                .src_picture = fg_pic,
                .mask_picture = mask_pic,
                .dst_picture = self.dst_picture,
                .src_x = 0,
                .src_y = 0,
                .mask_x = 0,
                .mask_y = 0,
                .dst_x = px,
                .dst_y = py,
                .width = w,
                .height = h,
            });
        }
    }
};

fn drainX11Events(
    source: *x11.Source,
    keymap: *const x11.keymap.Full,
    pty: *mite.Pty,
    win_width: *u16,
    win_height: *u16,
    scroll_back: *u16,
    scrollbar_drag: *?ScrollbarDrag,
    focused: *bool,
    visible_rows: u16,
    total_rows: u16,
    dpi_scale: f32,
    font_width: u8,
    font_height: u8,
) !bool {
    var damaged = false;
    while (true) {
        const msg_kind = source.readKind() catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed (EndOfStream)", .{});
                std.process.exit(0);
            },
            else => return err,
        };
        switch (msg_kind) {
            .Expose => {
                const expose = try source.read2(.Expose);
                if (false) std.log.info("X11 {}", .{expose});
                damaged = true;
            },
            .ConfigureNotify => {
                const config = try source.read2(.ConfigureNotify);
                win_width.* = config.width;
                win_height.* = config.height;
                pty.updateWinsz(win_width.* / font_width, win_height.* / font_height);
                damaged = true;
            },
            .KeyPress => {
                const event = try source.read2(.KeyPress);
                // Check unshifted keysym for Shift+PageUp/Down scroll
                const unshifted = keymap.getKeysym(event.keycode, .lower) catch |err| switch (err) {
                    error.KeycodeTooSmall => std.debug.panic("keycode {} is too small", .{event.keycode}),
                };
                if (event.state.shift and unshifted == .kbd_page_up) {
                    const max_scroll = if (total_rows > visible_rows) total_rows - visible_rows else 0;
                    scroll_back.* = @min(scroll_back.* +| visible_rows, max_scroll);
                    damaged = true;
                } else if (event.state.shift and unshifted == .kbd_page_down) {
                    scroll_back.* -|= visible_rows;
                    damaged = true;
                } else {
                    const keysym = keymap.getKeysym(event.keycode, event.state.mod()) catch |err| switch (err) {
                        error.KeycodeTooSmall => std.debug.panic("keycode {} is too small", .{event.keycode}),
                    };
                    // Any other key resets scroll to bottom
                    if (scroll_back.* != 0) {
                        scroll_back.* = 0;
                        damaged = true;
                    }
                    const bytes = if (event.state.control)
                        keysymToCtrlBytes(keysym)
                    else
                        keysymToBytes(keysym);
                    if (bytes.len > 0) {
                        const written = posix.write(pty.master, bytes) catch |err| std.debug.panic("pty write failed: {}", .{err});
                        if (written != bytes.len) std.debug.panic("pty short write: {} of {}", .{ written, bytes.len });
                    }
                }
            },
            .ButtonPress => {
                const event = try source.read2(.ButtonPress);
                const scroll_lines: u16 = 4;
                switch (event.button) {
                    1 => { // left click — check if on scrollbar
                        if (total_rows > visible_rows) {
                            const scrollbar_width: u16 = @intFromFloat(@round(8.0 * dpi_scale));
                            const scrollbar_x: i16 = @intCast(win_width.* -| scrollbar_width);
                            if (event.event_x >= scrollbar_x) {
                                const min_track_height: u16 = @intFromFloat(@round(20.0 * dpi_scale));
                                const track_height: u16 = @max(min_track_height, @as(u16, @intFromFloat(
                                    @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_rows)) * @as(f32, @floatFromInt(win_height.*)),
                                )));
                                const max_offset = total_rows - visible_rows;
                                const current_offset: u16 = if (max_offset >= scroll_back.*) max_offset - scroll_back.* else 0;
                                const track_y: i16 = @intCast(@as(u16, @intFromFloat(
                                    @as(f32, @floatFromInt(current_offset)) / @as(f32, @floatFromInt(max_offset)) * @as(f32, @floatFromInt(win_height.* -| track_height)),
                                )));
                                if (event.event_y >= track_y and event.event_y < track_y + @as(i16, @intCast(track_height))) {
                                    // Clicked on the thumb — start drag
                                    scrollbar_drag.* = .{ .grab_offset = event.event_y - track_y };
                                } else {
                                    // Clicked on the track — jump to position
                                    scroll_back.* = ScrollbarDrag.scrollbackFromY(event.event_y, @intCast(track_height / 2), track_height, win_height.*, total_rows, visible_rows);
                                    damaged = true;
                                }
                            }
                        }
                    },
                    4 => { // scroll up
                        const max_scroll = if (total_rows > visible_rows) total_rows - visible_rows else 0;
                        scroll_back.* = @min(scroll_back.* +| scroll_lines, max_scroll);
                        damaged = true;
                    },
                    5 => { // scroll down
                        scroll_back.* -|= scroll_lines;
                        damaged = true;
                    },
                    else => {},
                }
            },
            .ButtonRelease => {
                const event = try source.read2(.ButtonRelease);
                if (event.button == 1) {
                    scrollbar_drag.* = null;
                }
            },
            .MotionNotify => {
                const event = try source.read2(.MotionNotify);
                if (scrollbar_drag.*) |drag| {
                    if (total_rows > visible_rows) {
                        const min_track_height: u16 = @intFromFloat(@round(20.0 * dpi_scale));
                        const track_height: u16 = @max(min_track_height, @as(u16, @intFromFloat(
                            @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_rows)) * @as(f32, @floatFromInt(win_height.*)),
                        )));
                        scroll_back.* = ScrollbarDrag.scrollbackFromY(event.event_y, drag.grab_offset, track_height, win_height.*, total_rows, visible_rows);
                        damaged = true;
                    }
                }
            },
            .FocusIn => {
                _ = try source.read2(.FocusIn);
                focused.* = true;
                damaged = true;
            },
            .FocusOut => {
                _ = try source.read2(.FocusOut);
                focused.* = false;
                damaged = true;
            },
            .KeyRelease => _ = try source.read2(.KeyRelease),
            .MappingNotify,
            .ReparentNotify,
            .MapNotify,
            .UnmapNotify,
            .DestroyNotify,
            .GravityNotify,
            .CirculateNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
        // Keep draining if the reader has buffered data
        if (source.reader.seek >= source.reader.end) break;
    }
    return damaged;
}

const ScrollbarDrag = terminal.ScrollbarDrag;

fn doRender(
    sink: *x11.RequestSink,
    window_id: x11.Window,
    gc: x11.GraphicsContext,
    depth: x11.Depth,
    font_dims: FontDims,
    font_width: u8,
    font_height: u8,
    pty_data: *const terminal.PtyData,
    cursor: terminal.Cursor,
    gc_state: *Gc,
    visible_rows: u16,
    scroll_back: u16,
    offscreen_pixmap: x11.Pixmap,
    win_width: u16,
    win_height: u16,
    dpi_scale: f32,
    focused: bool,
    maybe_ttf_font: ?*TtfFont,
) error{WriteFailed}!u16 {
    if (maybe_ttf_font) |ttf_font| {
        // Clear offscreen pixmap with background color (XRender path)
        try x11.render.FillRectangles(sink, ttf_font.render_ext_opcode, .{
            .picture_operation = .src,
            .dst_picture = ttf_font.dst_picture,
            .color = x11.render.Color.fromRgb24(mite.default_bg),
            .rects = .init(@ptrCast(&x11.Rectangle{ .x = 0, .y = 0, .width = win_width, .height = win_height }), 1),
        });
    } else {
        // Clear offscreen pixmap with background color (xfont path)
        try gc_state.update(sink, gc, depth, .{ .fg = mite.default_bg });
        try sink.PolyFillRectangle(offscreen_pixmap.drawable(), gc, .initAssume(&.{
            .{ .x = 0, .y = 0, .width = win_width, .height = win_height },
        }));
    }
    const drawable = offscreen_pixmap.drawable();

    var gr: GlyphRenderer = .{
        .sink = sink,
        .drawable = drawable,
        .gc = gc,
        .depth = depth,
        .font_dims = font_dims,
        .font_width = font_width,
        .font_height = font_height,
        .gc_state = gc_state,
        .maybe_ttf_font = maybe_ttf_font,
    };

    const data = if (pty_data.foo) |foo| foo.slice[0..foo.used] else "";
    const num_cols: u16 = win_width / font_width;

    // Pre-pass: compute the total visual row count and cursor visual position,
    // accounting for line wrapping at num_cols.
    const visual_info = terminal.computeVisualInfo(data, num_cols, cursor);

    // Compute scroll offset using visual rows so wrapping is accounted for
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
                // Parse SGR sequence: \x1b [ params m
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
                // Skip unknown escape sequences in buffer
                i += 1;
            },
            else => {
                // Skip UTF-8 continuation bytes (they don't start a new column)
                if (byte >= 0x80 and byte < 0xC0) {
                    i += 1;
                    continue;
                }
                // Wrap to next visual row if we've reached the column limit
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
                    const codepoint: u21 = if (byte < 0x80) byte else terminal.decodeUtf8(data[i..]).codepoint;
                    try gr.put(screen_row, visual_col, codepoint, char_fg, char_bg);
                    if (is_cursor and !focused) {
                        try gc_state.update(sink, gc, depth, .{ .fg = mite.default_fg });
                        const px: i16 = font_dims.font_left + @as(i16, @intCast(visual_col)) * @as(i16, @intCast(font_width));
                        const py: i16 = screen_row * @as(i16, @intCast(font_height));
                        try sink.PolyRectangle(drawable, gc, .initAssume(&.{
                            .{ .x = px, .y = py, .width = font_width -| 1, .height = font_height -| 1 },
                        }));
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
                try gr.put(cursor_screen_row, visual_info.cursor_visual_col, ' ', mite.default_bg, mite.default_fg);
            } else {
                try gc_state.update(sink, gc, depth, .{ .fg = mite.default_fg });
                const px: i16 = font_dims.font_left + @as(i16, @intCast(visual_info.cursor_visual_col)) * @as(i16, @intCast(font_width));
                const py: i16 = cursor_screen_row * @as(i16, @intCast(font_height));
                try sink.PolyRectangle(drawable, gc, .initAssume(&.{
                    .{ .x = px, .y = py, .width = font_width -| 1, .height = font_height -| 1 },
                }));
            }
        }
    }

    // Draw scrollbar
    const total_rows: u16 = visual_info.total_visual_rows;
    if (total_rows > visible_rows) {
        const scrollbar_width: u16 = @intFromFloat(@round(8.0 * dpi_scale));
        const scrollbar_x: i16 = @intCast(win_width -| scrollbar_width);

        // Track height proportional to visible/total ratio
        const min_track_height: u16 = @intFromFloat(@round(20.0 * dpi_scale));
        const track_height: u16 = @max(min_track_height, @as(u16, @intFromFloat(
            @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_rows)) * @as(f32, @floatFromInt(win_height)),
        )));

        // Track position: scroll_offset is where the viewport starts
        const max_offset = total_rows - visible_rows;
        const current_offset: u16 = @intCast(@max(0, scroll_offset));
        const track_y: i16 = @intCast(@as(u16, @intFromFloat(
            @as(f32, @floatFromInt(current_offset)) / @as(f32, @floatFromInt(max_offset)) * @as(f32, @floatFromInt(win_height -| track_height)),
        )));

        try gc_state.update(sink, gc, depth, .{ .fg = 0x666666 });
        try sink.PolyFillRectangle(drawable, gc, .initAssume(&.{
            .{ .x = scrollbar_x, .y = track_y, .width = scrollbar_width, .height = track_height },
        }));
    }

    // Swap: CopyArea offscreen pixmap to window
    try sink.CopyArea(.{
        .src_drawable = offscreen_pixmap.drawable(),
        .dst_drawable = window_id.drawable(),
        .gc = gc,
        .src_x = 0,
        .src_y = 0,
        .dst_x = 0,
        .dst_y = 0,
        .width = win_width,
        .height = win_height,
    });

    return visual_info.total_visual_rows;
}

fn keysymToCtrlBytes(keysym: x11.charset.Combined) []const u8 {
    const S = struct {
        var buf: [1]u8 = undefined;
    };
    const charset = keysym.charset();
    const code = keysym.code();
    if (charset == .latin1) {
        // Ctrl+letter: map a-z/A-Z to control codes 1-26
        if ((code >= 'a' and code <= 'z') or (code >= 'A' and code <= 'Z')) {
            S.buf[0] = code & 0x1f;
            return &S.buf;
        }
        // Ctrl+special characters that produce control codes
        // e.g. Ctrl+@ = 0x00, Ctrl+[ = 0x1b, Ctrl+\ = 0x1c, Ctrl+] = 0x1d, Ctrl+^ = 0x1e, Ctrl+_ = 0x1f
        if (code >= '@' and code <= '_') {
            S.buf[0] = code & 0x1f;
            return &S.buf;
        }
    }
    // For keys without a Ctrl mapping (e.g. function keys), fall through to normal handling
    return keysymToBytes(keysym);
}

fn keysymToBytes(keysym: x11.charset.Combined) []const u8 {
    const charset = keysym.charset();
    const code = keysym.code();
    switch (charset) {
        .latin1 => {
            // Latin1 codes 0-31 are control characters (e.g. Ctrl-C = 3)
            if (code < 32) return @as(*const [1]u8, &code);
            // Latin1 codes 32-126 are printable ASCII
            if (code <= 126) return @as(*const [1]u8, &code);
            // Latin1 codes 128-255 are extended latin
            if (code >= 128) return @as(*const [1]u8, &code);
            // Code 127 (DEL) - should not normally occur here
            std.debug.panic("unhandled latin1 code: {}", .{code});
        },
        .keyboard => {
            return switch (keysym) {
                .kbd_return_enter, .kbd_keypad_enter => "\r",
                .kbd_backspace_back_space_back_char => "\x7f",
                .kbd_tab => "\t",
                .kbd_escape => "\x1b",
                .kbd_delete_rubout => "\x1b[3~",
                .kbd_up => "\x1b[A",
                .kbd_down => "\x1b[B",
                .kbd_right => "\x1b[C",
                .kbd_left => "\x1b[D",
                .kbd_home => "\x1b[H",
                .kbd_end_eol => "\x1b[F",
                .kbd_page_up => "\x1b[5~",
                .kbd_page_down => "\x1b[6~",
                .kbd_insert_insert_here => "\x1b[2~",
                // Modifier-only keys produce no bytes
                .kbd_left_shift,
                .kbd_right_shift,
                .kbd_left_control,
                .kbd_right_control,
                .kbd_caps_lock,
                .kbd_shift_lock,
                .kbd_left_meta,
                .kbd_right_meta,
                .kbd_left_alt,
                .kbd_right_alt,
                .kbd_left_super,
                .kbd_right_super,
                .kbd_left_hyper,
                .kbd_right_hyper,
                .kbd_num_lock,
                .kbd_scroll_lock,
                => "",
                else => std.debug.panic("unhandled keyboard keysym: code={}", .{code}),
            };
        },
        else => std.debug.panic("unhandled keysym: charset={} code={}", .{ charset, code }),
    }
}

const FontName = struct {
    buf: [256]u8 = undefined,
    len: u8 = 0,

    fn constSlice(self: *const FontName) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Query X11 server for monospace fonts and pick one with the best pixel size for the given DPI scale.
/// Prefers cell-spaced ("c") fonts for guaranteed uniform width, falls back to monospace ("m").
fn findFont(sink: *x11.RequestSink, source: *x11.Source, dpi_scale: f32) !FontName {
    const target_pixel_size: u16 = @intFromFloat(@round(30.0 * dpi_scale));

    // Try cell-spaced first (guaranteed uniform width), then monospace
    const patterns = [_][]const u8{
        "-*-*-*-*-*--*-*-*-*-c-*-iso8859-1",
        "-*-*-*-*-*--*-*-*-*-m-*-iso8859-1",
    };

    for (patterns) |pattern| {
        if (try findBestFont(sink, source, pattern, target_pixel_size)) |name| {
            return name;
        }
    }
    std.debug.panic("no monospace font found", .{});
}

fn findBestFont(sink: *x11.RequestSink, source: *x11.Source, pattern: []const u8, target_pixel_size: u16) !?FontName {
    try sink.ListFonts(0xffff, .{ .ptr = pattern.ptr, .len = @intCast(pattern.len) });
    try sink.writer.flush();

    const fonts, _ = try source.readSynchronousReplyHeader(sink.sequence, .ListFonts);
    std.log.info("found {} fonts matching {s}", .{ fonts.count, pattern });

    var best_name: FontName = .{};
    var best_diff: u16 = std.math.maxInt(u16);

    for (0..fonts.count) |_| {
        const len = try source.takeReplyInt(u8);
        const name_data = try source.takeReply(len);

        if (parseXlfdPixelSize(name_data)) |pixel_size| {
            const diff = if (pixel_size > target_pixel_size)
                pixel_size - target_pixel_size
            else
                target_pixel_size - pixel_size;

            if (diff < best_diff and len <= 256) {
                best_diff = diff;
                best_name.len = len;
                @memcpy(best_name.buf[0..len], name_data);
            }
        }
    }

    const remaining = source.replyRemainingSize();
    try source.replyDiscard(remaining);

    if (best_name.len == 0) return null;
    return best_name;
}

/// Parse the pixel size (field 7) from an XLFD font name.
fn parseXlfdPixelSize(name: []const u8) ?u16 {
    if (name.len == 0 or name[0] != '-') return null;
    // Skip 6 dashes to reach field 7 (pixel size)
    var dashes: u8 = 0;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '-') {
            dashes += 1;
            if (dashes == 7) {
                i += 1;
                const start = i;
                while (i < name.len and name[i] != '-') : (i += 1) {}
                if (i == start) return null; // wildcard or empty
                return std.fmt.parseUnsigned(u16, name[start..i], 10) catch null;
            }
        }
    }
    return null;
}

fn readDpiScale(source: *x11.Source, value_format: u8) f32 {
    const prop_header = source.read3Header(.GetProperty) catch |err|
        std.debug.panic("failed to read GetProperty reply: {}", .{err});
    const result: f32 = blk: {
        if (value_format == 0) {
            // Property not found, use default scale
            std.log.info("RESOURCE_MANAGER property not found, defaulting to dpi_scale=1.0", .{});
            break :blk 1.0;
        }
        if (value_format != 8) {
            std.debug.panic("Xft.dpi unexpected format {}", .{value_format});
        }
        if (prop_header.value_size_in_format_units == 0) {
            std.log.info("RESOURCE_MANAGER property is empty, defaulting to dpi_scale=1.0", .{});
            break :blk 1.0;
        }
        const value_len: u35 = prop_header.value_size_in_format_units;
        const data = source.takeReply(value_len) catch |err|
            std.debug.panic("failed to take GetProperty reply data: {}", .{err});
        if (parseXftDpi(data)) |xft_dpi| {
            const scale = xft_dpi / 96.0;
            std.log.info("Xft.dpi={d:.2} scale={d:.2}", .{ xft_dpi, scale });
            break :blk scale;
        }
        std.log.info("Xft.dpi not found in RESOURCE_MANAGER, defaulting to dpi_scale=1.0", .{});
        break :blk 1.0;
    };
    source.discardRemaining() catch |err|
        std.debug.panic("failed to discard remaining GetProperty data: {}", .{err});
    return result;
}

const xft_dpi_prefix = "Xft.dpi:";
fn parseXftDpi(data: []const u8) ?f32 {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, xft_dpi_prefix)) {
            const value_str = std.mem.trimLeft(u8, trimmed[xft_dpi_prefix.len..], " \t");
            return std.fmt.parseFloat(f32, value_str) catch null;
        }
    }
    return null;
}

fn streamFonts(source: *x11.Source, sequence: u16, writer: *std.Io.Writer) !void {
    const fonts, _ = try source.readSynchronousReplyHeader(sequence, .ListFonts);
    for (0..fonts.count) |_| {
        const len = try source.takeReplyInt(u8);
        try source.streamReply(writer, len);
        try writer.writeByte('\n');
    }
    try source.replyDiscard(source.replyRemainingSize());
    try writer.flush();
}

const std = @import("std");
const x11 = @import("x11");
const mite = @import("mite.zig");
const Cmdline = @import("Cmdline.zig");
const terminal = @import("terminal.zig");
const TrueType = @import("Font").TrueType;
const posix = std.posix;
const linux = std.os.linux;
