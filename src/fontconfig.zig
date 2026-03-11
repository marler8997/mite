pub fn match() error{Reported}!TrueType {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try fcMatchMono(&path_buf);
    std.log.info("loading '{s}'", .{path});
    const ttf_content = std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        path,
        100 * 1024 * 1024,
    ) catch |err| {
        std.log.err(
            "open font '{s}' failed with {t} (use --ttf to specify one)",
            .{ path, err },
        );
        return error.Reported;
    };
    return TrueType.load(ttf_content) catch |err| {
        std.log.err(
            "load font '{s}' failed with {t} (use --ttf to specify one)",
            .{ path, err },
        );
        return error.Reported;
    };
}

fn fcMatchMono(path_buf: *[std.fs.max_path_bytes]u8) error{Reported}![:0]const u8 {
    std.log.info("exec: fc-match --format=%{{file}} monospace:fontformat=TrueType", .{});
    var pipe = std.posix.pipe2(.{}) catch |e| {
        std.log.err(
            "failed to create pipe for fc-match with {t}",
            .{e},
        );
        return error.Reported;
    };
    defer {
        if (pipe[0] != -1) std.posix.close(pipe[0]);
        if (pipe[1] != -1) std.posix.close(pipe[1]);
    }
    const pid = std.posix.fork() catch |e| {
        std.log.err("fork for fc-match failed with {t}", .{e});
        return error.Reported;
    };
    if (pid == 0) {
        std.posix.close(pipe[0]);
        fcMatchNoReturn(pipe[1]);
    }

    std.posix.close(pipe[1]);
    pipe[1] = -1;

    var total: usize = 0;
    while (total < path_buf.len) {
        const n = std.posix.read(pipe[0], path_buf[total..]) catch |e| {
            std.log.err("read fc-match pipe failed with {t}", .{e});
            return error.Reported;
        };
        if (n == 0) break;
        total += n;
    } else try drainFd(pipe[0]); // path too long, drain so child doesn't block

    const wait = std.posix.waitpid(pid, 0);
    if (!std.posix.W.IFEXITED(wait.status)) {
        std.log.err("fc-match terminated abnormally (status=0x{x})", .{wait.status});
        return error.Reported;
    }
    const exit_code = std.posix.W.EXITSTATUS(wait.status);
    if (exit_code != 0) {
        std.log.err("fc-match exited with code {}", .{exit_code});
        return error.Reported;
    }
    if (total >= path_buf.len) {
        std.log.err("fc-match output too long", .{});
        return error.Reported;
    }
    if (total >= path_buf.len) {
        std.log.err("fc-match output too long", .{});
        return error.Reported;
    }
    path_buf[total] = 0;
    return path_buf[0..total :0];
}

fn fcMatchNoReturn(pipe: std.posix.fd_t) noreturn {
    fcMatchExec(pipe) catch |e| {
        std.log.err("error.{t}", .{e});
        if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
        std.process.exit(0xff);
    };
}
fn fcMatchExec(pipe: std.posix.fd_t) !noreturn {
    if (pipe != std.posix.STDOUT_FILENO) {
        std.posix.dup2(pipe, std.posix.STDOUT_FILENO) catch {
            std.process.exit(0xff);
        };
        std.posix.close(pipe);
    }
    const err = std.posix.execvpeZ_expandArg0(
        .no_expand,
        "fc-match",
        &.{ "fc-match", "--format=%{file}", "monospace", null },
        @ptrCast(std.os.environ.ptr),
    );
    std.log.err("exec fc-match failed with {t}", .{err});
    std.process.exit(0xff);
}

fn drainFd(fd: std.posix.fd_t) error{Reported}!void {
    var discard: [1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &discard) catch |err| {
            std.log.err("read from fc-match pipe failed with {t}", .{err});
            return error.Reported;
        };
        if (n == 0) break;
    }
}

const std = @import("std");
const TrueType = @import("TrueType");
