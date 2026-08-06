const std = @import("std");

pub const LogLevel = enum {
    @"error",
    warn,
    info,
    debug,
};

pub const ColorMode = enum {
    auto,
    always,
    never,
};

var configured_level: LogLevel = .warn;
var configured_color: ColorMode = .auto;

// Translate declarations without glibc's compiler-specific fortified inline wrappers.
pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

// Fixed storage keeps error reporting available even when allocation would be unsafe.
pub const ErrorMessage = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *ErrorMessage, comptime format: []const u8, arguments: anytype) void {
        const rendered = std.fmt.bufPrint(&self.buffer, format, arguments) catch {
            const fallback = "operation failed because its error message was too long";
            @memcpy(self.buffer[0..fallback.len], fallback);
            self.len = fallback.len;
            return;
        };
        self.len = rendered.len;
    }

    pub fn setSystem(self: *ErrorMessage, prefix: []const u8, number: c_int) void {
        self.set("{s}: {s}", .{ prefix, std.mem.span(c.strerror(number)) });
    }

    pub fn text(self: *const ErrorMessage) []const u8 {
        return self.buffer[0..self.len];
    }
};

// Centralize errno access because libc exposes it through a thread-local pointer.
pub fn lastErrno() c_int {
    return c.__errno_location().*;
}

pub fn configureLogging(level: LogLevel, color: ColorMode) void {
    configured_level = level;
    configured_color = color;
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = c.write(fd, remaining.ptr, remaining.len);
        if (written > 0) {
            remaining = remaining[@intCast(written)..];
        } else if (written < 0 and lastErrno() == c.EINTR) {
            continue;
        } else {
            return;
        }
    }
}

fn allows(level: LogLevel) bool {
    return @intFromEnum(level) <= @intFromEnum(configured_level);
}

fn writeLog(level: LogLevel, message: []const u8) void {
    if (!allows(level)) return;

    const no_color = c.getenv("NO_COLOR");
    const term = c.getenv("TERM");
    const use_color = switch (configured_color) {
        .always => true,
        .never => false,
        .auto => c.isatty(c.STDERR_FILENO) == 1 and
            (no_color == null or std.mem.span(no_color).len == 0) and
            (term == null or !std.mem.eql(u8, std.mem.span(term), "dumb")),
    };
    const label = switch (level) {
        .debug => "DEBUG",
        .info => "INFO ",
        .warn => "WARN ",
        .@"error" => "ERROR",
    };

    writeAll(c.STDERR_FILENO, "airpodsctl: ");
    if (use_color) writeAll(c.STDERR_FILENO, switch (level) {
        .debug => "\x1b[2m",
        .info => "\x1b[36m",
        .warn => "\x1b[33m",
        .@"error" => "\x1b[1;31m",
    });
    writeAll(c.STDERR_FILENO, label);
    if (use_color) writeAll(c.STDERR_FILENO, "\x1b[0m");
    writeAll(c.STDERR_FILENO, "  ");
    writeAll(c.STDERR_FILENO, message);
    writeAll(c.STDERR_FILENO, "\n");
}

pub fn emit(level: LogLevel, value: []const u8) void {
    writeLog(level, value);
}

pub fn log(level: LogLevel, comptime format: []const u8, arguments: anytype) void {
    if (!allows(level)) return;

    var buffer: [512]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buffer, format, arguments) catch
        "The diagnostic could not be rendered because its formatted message exceeded 512 bytes.";
    writeLog(level, rendered);
}

pub fn warn(message: []const u8) void {
    writeLog(.warn, message);
}
