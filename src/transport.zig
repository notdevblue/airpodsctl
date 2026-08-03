const std = @import("std");
const support = @import("support");

const c = support.c;

pub const Error = error{ProtocolFailure};

// Use a monotonic clock so wall-clock corrections cannot extend an invocation.
pub fn nowMs() i64 {
    var now: c.struct_timespec = undefined;

    if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return 0;
    return @as(i64, @intCast(now.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(now.tv_nsec)), 1_000_000);
}

fn waitForFd(
    fd: c_int,
    events: c_short,
    deadline_ms: i64,
    failure: *support.ErrorMessage,
) Error!void {
    var descriptor = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };

    while (true) {
        // poll accepts c_int milliseconds, so clamp unusually distant deadlines safely.
        const timeout: c_int = @intCast(std.math.clamp(
            deadline_ms - nowMs(),
            0,
            std.math.maxInt(c_int),
        ));
        if (timeout == 0) {
            failure.set("AirPods did not respond before the timeout", .{});
            return error.ProtocolFailure;
        }

        const ready = c.poll(&descriptor, 1, timeout);
        if (ready > 0) {
            if (descriptor.revents & (c.POLLERR | c.POLLNVAL) != 0) {
                failure.set("AirPods transport reported an I/O error", .{});
                return error.ProtocolFailure;
            }
            if (descriptor.revents & events != 0) return;
            if (descriptor.revents & c.POLLHUP != 0) {
                failure.set("AirPods closed the control connection", .{});
                return error.ProtocolFailure;
            }
            continue;
        }
        if (ready == 0) {
            failure.set("AirPods did not respond before the timeout", .{});
            return error.ProtocolFailure;
        }
        if (support.lastErrno() != c.EINTR) {
            failure.setSystem("poll failed", support.lastErrno());
            return error.ProtocolFailure;
        }
    }
}

pub const Channel = struct {
    fd: c_int,
    deadline_ms: i64,
    failure: *support.ErrorMessage,

    pub fn delay(self: *Channel, delay_ms: u32) Error!void {
        var remaining_delay = c.struct_timespec{
            .tv_sec = @intCast(delay_ms / 1000),
            .tv_nsec = @intCast((delay_ms % 1000) * 1_000_000),
        };

        if (@as(i64, delay_ms) > self.deadline_ms - nowMs()) {
            self.failure.set("AirPods initialization exceeded the timeout", .{});
            return error.ProtocolFailure;
        }
        while (c.nanosleep(&remaining_delay, &remaining_delay) != 0) {
            if (support.lastErrno() != c.EINTR) {
                self.failure.setSystem("initialization delay failed", support.lastErrno());
                return error.ProtocolFailure;
            }
        }
    }

    pub fn send(self: *Channel, packet: []const u8) Error!void {
        while (true) {
            try waitForFd(self.fd, c.POLLOUT, self.deadline_ms, self.failure);

            const sent = c.send(self.fd, packet.ptr, packet.len, c.MSG_NOSIGNAL);
            if (sent == packet.len) return;
            if (sent >= 0) {
                self.failure.set("AirPods transport sent a partial packet", .{});
                return error.ProtocolFailure;
            }
            if (support.lastErrno() != c.EAGAIN and
                support.lastErrno() != c.EWOULDBLOCK and
                support.lastErrno() != c.EINTR)
            {
                self.failure.setSystem("send failed", support.lastErrno());
                return error.ProtocolFailure;
            }
        }
    }

    pub fn receive(self: *Channel, packet: []u8) Error![]const u8 {
        var vector = c.struct_iovec{ .iov_base = packet.ptr, .iov_len = packet.len };
        var message: c.struct_msghdr = std.mem.zeroes(c.struct_msghdr);

        // recvmsg exposes MSG_TRUNC, which plain recv cannot use to reject oversized packets.
        message.msg_iov = &vector;
        message.msg_iovlen = 1;

        while (true) {
            try waitForFd(self.fd, c.POLLIN, self.deadline_ms, self.failure);

            const received = c.recvmsg(self.fd, &message, 0);
            if (received > 0) {
                if (message.msg_flags & c.MSG_TRUNC != 0) {
                    self.failure.set("AirPods response exceeded the packet buffer", .{});
                    return error.ProtocolFailure;
                }
                return packet[0..@intCast(received)];
            }
            if (received == 0) {
                self.failure.set("AirPods closed the control connection", .{});
                return error.ProtocolFailure;
            }
            if (support.lastErrno() != c.EAGAIN and
                support.lastErrno() != c.EWOULDBLOCK and
                support.lastErrno() != c.EINTR)
            {
                self.failure.setSystem("receive failed", support.lastErrno());
                return error.ProtocolFailure;
            }
        }
    }
};
