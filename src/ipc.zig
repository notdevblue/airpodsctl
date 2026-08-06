const std = @import("std");
const battery = @import("battery");
const cli = @import("cli");
const command = @import("command");
const noise_control = @import("noise_control");
const smart_routing = @import("smart_routing");
const support = @import("support");
const transport = @import("transport");
const wear_detection = @import("wear_detection");

const c = support.c;
const request_magic_v1 = "APC1";
const request_magic_v2 = "APC2";
const request_magic_v3 = "APC3";
const response_magic_v1 = "APR1";
const response_magic_v2 = "APR2";
const response_magic_v3 = "APR3";
const socket_suffix = "/airpodsctl.sock";
const packet_size = 512;
const request_timeout_ms = 3000;

pub const Error = error{ Unavailable, IpcFailure };

pub const ProtocolVersion = enum {
    v1,
    v2,
    v3,
};

pub const SocketPath = struct {
    buffer: [108]u8 = undefined,
    len: usize,

    pub fn sentinel(self: *const SocketPath) [:0]const u8 {
        return self.buffer[0..self.len :0];
    }
};

pub const Request = struct {
    // The address slice borrows the received packet and is consumed before that buffer is reused.
    requested_address: ?[]const u8,
    operation: command.Operation,
    version: ProtocolVersion,
};

fn operationVersion(operation: command.Operation) ProtocolVersion {
    return switch (operation) {
        .noise_control, .battery => .v1,
        .wear_status => .v2,
        .switching => .v3,
    };
}

fn requestMagic(version: ProtocolVersion) *const [4]u8 {
    return switch (version) {
        .v1 => request_magic_v1,
        .v2 => request_magic_v2,
        .v3 => request_magic_v3,
    };
}

fn responseMagic(version: ProtocolVersion) *const [4]u8 {
    return switch (version) {
        .v1 => response_magic_v1,
        .v2 => response_magic_v2,
        .v3 => response_magic_v3,
    };
}

fn decodeRequestVersion(packet: []const u8) ?ProtocolVersion {
    if (packet.len < 4) return null;
    if (std.mem.eql(u8, packet[0..4], request_magic_v1)) return .v1;
    if (std.mem.eql(u8, packet[0..4], request_magic_v2)) return .v2;
    if (std.mem.eql(u8, packet[0..4], request_magic_v3)) return .v3;
    return null;
}

fn decodeResponseVersion(packet: []const u8) ?ProtocolVersion {
    if (packet.len < 4) return null;
    if (std.mem.eql(u8, packet[0..4], response_magic_v1)) return .v1;
    if (std.mem.eql(u8, packet[0..4], response_magic_v2)) return .v2;
    if (std.mem.eql(u8, packet[0..4], response_magic_v3)) return .v3;
    return null;
}

fn decodeMode(value: u8) ?noise_control.Mode {
    return switch (value) {
        @intFromEnum(noise_control.Mode.off) => .off,
        @intFromEnum(noise_control.Mode.noise_cancellation) => .noise_cancellation,
        @intFromEnum(noise_control.Mode.transparency) => .transparency,
        @intFromEnum(noise_control.Mode.adaptive) => .adaptive,
        else => null,
    };
}

fn encodeReading(buffer: []u8, reading: ?battery.Reading) void {
    if (reading) |value| {
        buffer[0] = 1;
        buffer[1] = value.level;
        buffer[2] = switch (value.state) {
            .unknown => 0,
            .charging => 1,
            .discharging => 2,
            .disconnected => 4,
        };
    } else {
        @memset(buffer[0..3], 0);
    }
}

fn decodeReading(buffer: []const u8) error{InvalidResponse}!?battery.Reading {
    if (buffer[0] == 0) return null;
    if (buffer[0] != 1 or buffer[1] > 100) return error.InvalidResponse;
    return .{
        .level = buffer[1],
        .state = switch (buffer[2]) {
            0 => .unknown,
            1 => .charging,
            2 => .discharging,
            4 => .disconnected,
            else => return error.InvalidResponse,
        },
    };
}

// Requests use magic, operation kind, address length/data, then a bounded typed payload.
pub fn encodeRequest(buffer: []u8, value: cli.Command) error{InvalidRequest}![]const u8 {
    if (value.requested_address) |address| {
        if (address.len != 17) return error.InvalidRequest;
    }

    const version = operationVersion(value.operation);
    @memcpy(buffer[0..4], requestMagic(version));
    buffer[5] = if (value.requested_address) |address| @intCast(address.len) else 0;
    if (value.requested_address) |address| @memcpy(buffer[6 .. 6 + address.len], address);
    const payload = 6 + buffer[5];

    switch (value.operation) {
        .noise_control => |noise_request| {
            if (noise_request.toggle_mode_count > command.max_toggle_modes or
                (noise_request.action != .toggle and noise_request.toggle_mode_count != 0))
            {
                return error.InvalidRequest;
            }
            buffer[4] = 1;
            buffer[payload] = switch (noise_request.action) {
                .status => 1,
                .anc => 2,
                .off => 3,
                .transparency => 4,
                .adaptive => 5,
                .toggle => 6,
            };
            buffer[payload + 1] = @intCast(noise_request.toggle_mode_count);
            for (noise_request.toggle_modes[0..noise_request.toggle_mode_count], 0..) |mode, index| {
                buffer[payload + 2 + index] = @intFromEnum(mode);
            }
            return buffer[0 .. payload + 2 + noise_request.toggle_mode_count];
        },
        .battery => |component| {
            buffer[4] = 2;
            buffer[payload] = if (component) |selected| @intFromEnum(selected) else 0;
            return buffer[0 .. payload + 1];
        },
        .wear_status => {
            buffer[4] = 4;
            buffer[payload] = 0;
            return buffer[0 .. payload + 1];
        },
        .switching => |switching_request| {
            buffer[4] = 5;
            buffer[payload] = switch (switching_request.action) {
                .status => 1,
                .take => 2,
                .release => 3,
            };
            buffer[payload + 1] = @intFromBool(switching_request.force);
            return buffer[0 .. payload + 2];
        },
    }
}

pub fn decodeRequest(packet: []const u8) error{InvalidRequest}!Request {
    if (packet.len < 7) return error.InvalidRequest;
    const version = decodeRequestVersion(packet) orelse return error.InvalidRequest;
    const address_len = packet[5];
    if (address_len != 0 and address_len != 17) return error.InvalidRequest;
    const payload = 6 + @as(usize, address_len);
    if (packet.len <= payload) return error.InvalidRequest;

    return .{
        .requested_address = if (address_len == 0) null else packet[6..payload],
        .version = version,
        .operation = switch (packet[4]) {
            1 => operation: {
                if (packet.len < payload + 2) return error.InvalidRequest;
                const mode_count = packet[payload + 1];
                if (mode_count > command.max_toggle_modes or packet.len != payload + 2 + mode_count) {
                    return error.InvalidRequest;
                }
                var noise_request = command.NoiseControl{
                    .action = switch (packet[payload]) {
                        1 => .status,
                        2 => .anc,
                        3 => .off,
                        4 => .transparency,
                        5 => .adaptive,
                        6 => .toggle,
                        else => return error.InvalidRequest,
                    },
                    .toggle_mode_count = mode_count,
                };
                if (noise_request.action != .toggle and mode_count != 0) {
                    return error.InvalidRequest;
                }
                for (packet[payload + 2 ..], 0..) |mode, index| {
                    noise_request.toggle_modes[index] = decodeMode(mode) orelse return error.InvalidRequest;
                    for (noise_request.toggle_modes[0..index]) |previous| {
                        if (previous == noise_request.toggle_modes[index]) return error.InvalidRequest;
                    }
                }
                break :operation .{ .noise_control = noise_request };
            },
            2 => operation: {
                if (packet.len != payload + 1) return error.InvalidRequest;
                break :operation .{ .battery = switch (packet[payload]) {
                    0 => null,
                    @intFromEnum(battery.Component.left) => .left,
                    @intFromEnum(battery.Component.right) => .right,
                    else => return error.InvalidRequest,
                } };
            },
            4 => operation: {
                if (version != .v2 or packet.len != payload + 1 or packet[payload] != 0) {
                    return error.InvalidRequest;
                }
                break :operation .wear_status;
            },
            5 => operation: {
                if (version != .v3 or packet.len != payload + 2 or packet[payload + 1] > 1) {
                    return error.InvalidRequest;
                }
                const action: command.SwitchingAction = switch (packet[payload]) {
                    1 => .status,
                    2 => .take,
                    3 => .release,
                    else => return error.InvalidRequest,
                };
                if (packet[payload + 1] != 0 and action != .take) return error.InvalidRequest;
                break :operation .{ .switching = .{
                    .action = action,
                    .force = packet[payload + 1] != 0,
                } };
            },
            else => return error.InvalidRequest,
        },
    };
}

// Responses carry either a typed result or a bounded diagnostic from the service.
pub fn encodeResultForVersion(buffer: []u8, result: command.Result, version: ProtocolVersion) []const u8 {
    @memcpy(buffer[0..4], responseMagic(version));
    buffer[4] = 0;

    switch (result) {
        .mode => |mode| {
            buffer[5] = 1;
            buffer[6] = @intFromEnum(mode);
            return buffer[0..7];
        },
        .battery => |value| {
            buffer[5] = 2;
            buffer[6] = if (value.component) |component| @intFromEnum(component) else 0;
            encodeReading(buffer[7..10], value.report.left);
            encodeReading(buffer[10..13], value.report.right);

            // Retain the retired case slot so v1 clients and already-running services remain compatible.
            @memset(buffer[13..16], 0);
            return buffer[0..16];
        },
        .wear_status => |report| {
            buffer[5] = 4;
            buffer[6] = @intFromEnum(report.primary);
            buffer[7] = @intFromEnum(report.secondary);
            return buffer[0..8];
        },
        .switching => |status| {
            buffer[5] = 5;
            buffer[6] = switch (status.hosts) {
                .local_only => 1,
                .local_and_remote => 2,
                .unknown => 3,
            };
            buffer[7] = switch (status.owner) {
                .linux => 1,
                .remote => 2,
                .none => 3,
                .unknown => 4,
            };
            buffer[8] = switch (status.remote_activity) {
                .idle => 1,
                .active => 2,
                .unknown => 3,
            };
            return buffer[0..9];
        },
    }
}

pub fn encodeResult(buffer: []u8, result: command.Result) []const u8 {
    return encodeResultForVersion(buffer, result, switch (result) {
        .mode, .battery => .v1,
        .wear_status => .v2,
        .switching => .v3,
    });
}

pub fn encodeFailureForVersion(buffer: []u8, message: []const u8, version: ProtocolVersion) []const u8 {
    const length = @min(message.len, buffer.len - 7);

    @memcpy(buffer[0..4], responseMagic(version));
    buffer[4] = 1;
    std.mem.writeInt(u16, buffer[5..7], @intCast(length), .little);
    @memcpy(buffer[7 .. 7 + length], message[0..length]);
    return buffer[0 .. 7 + length];
}

pub fn encodeFailure(buffer: []u8, message: []const u8) []const u8 {
    return encodeFailureForVersion(buffer, message, .v1);
}

pub fn decodeResultForVersion(
    packet: []const u8,
    expected_version: ?ProtocolVersion,
    failure: *support.ErrorMessage,
) error{ InvalidResponse, RemoteFailure, IncompatibleVersion }!command.Result {
    if (packet.len < 7) return error.InvalidResponse;
    const version = decodeResponseVersion(packet) orelse return error.InvalidResponse;
    if (expected_version) |expected| {
        if (version != expected) {
            failure.set(
                "running session service uses IPC {s}; restart it to use IPC {s} commands",
                .{ @tagName(version), @tagName(expected) },
            );
            return error.IncompatibleVersion;
        }
    }
    if (packet[4] == 1) {
        const length = std.mem.readInt(u16, packet[5..7], .little);
        if (packet.len != 7 + length) return error.InvalidResponse;
        failure.set("{s}", .{packet[7..]});
        return error.RemoteFailure;
    }
    if (packet[4] != 0) return error.InvalidResponse;

    return switch (packet[5]) {
        1 => if (packet.len == 7)
            .{ .mode = decodeMode(packet[6]) orelse return error.InvalidResponse }
        else
            error.InvalidResponse,
        2 => if (packet.len == 16) .{ .battery = .{
            .component = switch (packet[6]) {
                0 => null,
                @intFromEnum(battery.Component.left) => .left,
                @intFromEnum(battery.Component.right) => .right,
                else => return error.InvalidResponse,
            },
            .report = .{
                .left = try decodeReading(packet[7..10]),
                .right = try decodeReading(packet[10..13]),
            },
        } } else error.InvalidResponse,
        4 => if (version == .v2 and packet.len == 8) .{ .wear_status = .{
            .primary = @as(wear_detection.WearState, @enumFromInt(packet[6])),
            .secondary = @as(wear_detection.WearState, @enumFromInt(packet[7])),
        } } else error.InvalidResponse,
        5 => if (version == .v3 and packet.len == 9) .{ .switching = .{
            .hosts = switch (packet[6]) {
                1 => .local_only,
                2 => .local_and_remote,
                3 => .unknown,
                else => return error.InvalidResponse,
            },
            .owner = switch (packet[7]) {
                1 => .linux,
                2 => .remote,
                3 => .none,
                4 => .unknown,
                else => return error.InvalidResponse,
            },
            .remote_activity = switch (packet[8]) {
                1 => .idle,
                2 => .active,
                3 => .unknown,
                else => return error.InvalidResponse,
            },
        } } else error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

pub fn decodeResult(
    packet: []const u8,
    failure: *support.ErrorMessage,
) error{ InvalidResponse, RemoteFailure, IncompatibleVersion }!command.Result {
    return decodeResultForVersion(packet, null, failure);
}

pub fn getSocketPath(failure: *support.ErrorMessage) Error!SocketPath {
    const runtime = c.getenv("XDG_RUNTIME_DIR") orelse {
        failure.set("XDG_RUNTIME_DIR is not set", .{});
        return error.Unavailable;
    };
    const directory = std.mem.span(runtime);
    var path = SocketPath{ .len = directory.len + socket_suffix.len };

    if (directory.len == 0 or directory[0] != '/' or path.len >= path.buffer.len) {
        failure.set("XDG_RUNTIME_DIR cannot be used for the session socket", .{});
        return error.Unavailable;
    }
    @memcpy(path.buffer[0..directory.len], directory);
    @memcpy(path.buffer[directory.len..path.len], socket_suffix);
    path.buffer[path.len] = 0;
    return path;
}

fn socketAddress(path: *const SocketPath) c.struct_sockaddr_un {
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    const destination: [*]u8 = @ptrCast(&address.sun_path);
    @memcpy(destination[0..path.len], path.buffer[0..path.len]);
    return address;
}

fn waitForFd(fd: c_int, events: c_short, deadline_ms: i64, failure: *support.ErrorMessage) Error!void {
    var descriptor = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };

    while (true) {
        const remaining = deadline_ms - transport.nowMs();
        if (remaining <= 0) {
            failure.set("session service did not respond before the timeout", .{});
            return error.IpcFailure;
        }
        const ready = c.poll(&descriptor, 1, @intCast(@min(remaining, std.math.maxInt(c_int))));
        if (ready > 0) {
            if (descriptor.revents & events != 0) return;
            failure.set("session service closed the local connection", .{});
            return error.IpcFailure;
        }
        if (ready == 0) {
            failure.set("session service did not respond before the timeout", .{});
            return error.IpcFailure;
        }
        if (support.lastErrno() != c.EINTR) {
            failure.setSystem("session socket poll failed", support.lastErrno());
            return error.IpcFailure;
        }
    }
}

pub fn sendPacket(fd: c_int, packet: []const u8, deadline_ms: i64, failure: *support.ErrorMessage) Error!void {
    while (true) {
        try waitForFd(fd, c.POLLOUT, deadline_ms, failure);
        const sent = c.send(fd, packet.ptr, packet.len, c.MSG_NOSIGNAL);

        if (sent == packet.len) return;
        if (sent >= 0) {
            failure.set("session socket sent a partial message", .{});
            return error.IpcFailure;
        }
        if (support.lastErrno() != c.EAGAIN and
            support.lastErrno() != c.EWOULDBLOCK and
            support.lastErrno() != c.EINTR)
        {
            failure.setSystem("cannot write to the session socket", support.lastErrno());
            return error.IpcFailure;
        }
    }
}

pub fn receivePacket(fd: c_int, buffer: []u8, deadline_ms: i64, failure: *support.ErrorMessage) Error![]const u8 {
    var vector = c.struct_iovec{ .iov_base = buffer.ptr, .iov_len = buffer.len };
    var message: c.struct_msghdr = std.mem.zeroes(c.struct_msghdr);
    message.msg_iov = &vector;
    message.msg_iovlen = 1;

    while (true) {
        try waitForFd(fd, c.POLLIN, deadline_ms, failure);
        message.msg_flags = 0;
        const received = c.recvmsg(fd, &message, 0);

        if (received > 0 and message.msg_flags & c.MSG_TRUNC == 0) return buffer[0..@intCast(received)];
        if (received > 0) {
            failure.set("session socket message was too large", .{});
            return error.IpcFailure;
        }
        if (received == 0) {
            failure.set("session service closed the local connection", .{});
            return error.IpcFailure;
        }
        if (support.lastErrno() != c.EAGAIN and
            support.lastErrno() != c.EWOULDBLOCK and
            support.lastErrno() != c.EINTR)
        {
            failure.setSystem("cannot read from the session socket", support.lastErrno());
            return error.IpcFailure;
        }
    }
}

pub fn openListener(path: *const SocketPath, failure: *support.ErrorMessage) Error!c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (fd < 0) {
        failure.setSystem("cannot create the session socket", support.lastErrno());
        return error.IpcFailure;
    }
    errdefer _ = c.close(fd);

    var address = socketAddress(path);
    const previous_mask = c.umask(0o077);
    var bound = c.bind(fd, .{ .__sockaddr__ = @ptrCast(&address) }, @sizeOf(c.struct_sockaddr_un));
    var bind_error = if (bound == 0) @as(c_int, 0) else support.lastErrno();
    _ = c.umask(previous_mask);
    if (bound != 0 and bind_error == c.EADDRINUSE) {
        const probe = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
        if (probe < 0) {
            failure.setSystem("cannot inspect the existing session socket", support.lastErrno());
            return error.IpcFailure;
        }
        defer _ = c.close(probe);

        if (c.connect(probe, .{ .__sockaddr__ = @ptrCast(&address) }, @sizeOf(c.struct_sockaddr_un)) == 0 or
            support.lastErrno() == c.EINPROGRESS)
        {
            failure.set("a session service is already running", .{});
            return error.IpcFailure;
        }
        if (support.lastErrno() != c.ECONNREFUSED) {
            failure.setSystem("cannot inspect the existing session socket", support.lastErrno());
            return error.IpcFailure;
        }

        var information: c.struct_stat = undefined;
        if (c.lstat(path.sentinel().ptr, &information) != 0 or
            information.st_uid != c.getuid() or
            information.st_mode & c.S_IFMT != c.S_IFSOCK)
        {
            // Never replace an unexpected file merely because it occupies the configured pathname.
            failure.set("the session socket path is occupied by an unsafe file", .{});
            return error.IpcFailure;
        }
        if (c.unlink(path.sentinel().ptr) != 0) {
            failure.setSystem("cannot remove the stale session socket", support.lastErrno());
            return error.IpcFailure;
        }

        const retry_mask = c.umask(0o077);
        bound = c.bind(fd, .{ .__sockaddr__ = @ptrCast(&address) }, @sizeOf(c.struct_sockaddr_un));
        bind_error = if (bound == 0) 0 else support.lastErrno();
        _ = c.umask(retry_mask);
    }
    if (bound != 0) {
        failure.setSystem("cannot bind the session socket", bind_error);
        return error.IpcFailure;
    }
    if (c.chmod(path.sentinel().ptr, 0o600) != 0 or c.listen(fd, 8) != 0) {
        failure.setSystem("cannot prepare the session socket", support.lastErrno());
        _ = c.unlink(path.sentinel().ptr);
        return error.IpcFailure;
    }
    return fd;
}

pub fn acceptClient(fd: c_int, failure: *support.ErrorMessage) Error!c_int {
    const client = c.accept4(fd, .{ .__sockaddr__ = null }, null, c.SOCK_CLOEXEC | c.SOCK_NONBLOCK);
    if (client < 0) {
        failure.setSystem("cannot accept a session client", support.lastErrno());
        return error.IpcFailure;
    }
    errdefer _ = c.close(client);

    var credentials: c.struct_ucred = undefined;
    var size: c.socklen_t = @sizeOf(c.struct_ucred);
    if (c.getsockopt(client, c.SOL_SOCKET, c.SO_PEERCRED, &credentials, &size) != 0 or
        credentials.uid != c.getuid())
    {
        failure.set("session client is owned by another user", .{});
        return error.IpcFailure;
    }
    return client;
}

pub fn request(value: cli.Command, failure: *support.ErrorMessage) Error!command.Result {
    support.log(
        .debug,
        "Connecting to the session service for '{s}' because {s}.",
        .{
            value.operation.name(),
            if (value.backend == .automatic)
                "the automatic backend prefers the existing shared AirPods control connection"
            else
                "--session requires the running service",
        },
    );
    const path = try getSocketPath(failure);
    var address = socketAddress(&path);
    const deadline_ms = transport.nowMs() + request_timeout_ms;
    const fd = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (fd < 0) {
        failure.setSystem("cannot create a session client socket", support.lastErrno());
        return error.IpcFailure;
    }
    defer _ = c.close(fd);

    if (c.connect(fd, .{ .__sockaddr__ = @ptrCast(&address) }, @sizeOf(c.struct_sockaddr_un)) != 0) {
        if (support.lastErrno() == c.ENOENT or support.lastErrno() == c.ECONNREFUSED) {
            failure.set("session service is not running", .{});
            return error.Unavailable;
        }
        if (support.lastErrno() != c.EINPROGRESS) {
            failure.setSystem("cannot connect to the session service", support.lastErrno());
            return error.IpcFailure;
        }

        try waitForFd(fd, c.POLLOUT, deadline_ms, failure);
        var socket_error: c_int = 0;
        var socket_error_size: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &socket_error_size) != 0) {
            failure.setSystem("cannot inspect the session connection", support.lastErrno());
            return error.IpcFailure;
        }
        if (socket_error == c.ENOENT or socket_error == c.ECONNREFUSED) {
            failure.set("session service is not running", .{});
            return error.Unavailable;
        }
        if (socket_error != 0) {
            failure.setSystem("cannot connect to the session service", socket_error);
            return error.IpcFailure;
        }
    }
    support.log(.debug, "The session connection is ready because the local service accepted the client socket.", .{});

    var packet: [packet_size]u8 = undefined;
    const version = operationVersion(value.operation);
    try sendPacket(fd, encodeRequest(&packet, value) catch {
        failure.set("invalid Bluetooth address: {s}", .{value.requested_address.?});
        return error.IpcFailure;
    }, deadline_ms, failure);
    support.log(
        .debug,
        "Sent the '{s}' request because the session service owns the shared AirPods connection.",
        .{value.operation.name()},
    );

    const response = try receivePacket(fd, &packet, deadline_ms, failure);
    support.log(
        .debug,
        "Received the '{s}' response because the session service completed the requested operation.",
        .{value.operation.name()},
    );
    const result = decodeResultForVersion(response, version, failure) catch {
        if (failure.text().len == 0) failure.set("session service returned an invalid response", .{});
        return error.IpcFailure;
    };
    support.log(
        .debug,
        "Accepted the '{s}' response because its IPC version and typed payload were valid.",
        .{value.operation.name()},
    );
    return result;
}
