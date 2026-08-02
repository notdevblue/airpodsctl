const std = @import("std");

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

pub fn warn(message: []const u8) void {
    writeAll(c.STDERR_FILENO, "airpodsctl: warning: ");
    writeAll(c.STDERR_FILENO, message);
    writeAll(c.STDERR_FILENO, "\n");
}
