const std = @import("std");
const aacp = @import("aacp");
const bluez = @import("bluez");
const cli = @import("cli");
const controller = @import("controller");
const ipc = @import("ipc");
const support = @import("support");
const transport = @import("transport");

const c = support.c;
const operation_timeout_ms = 3000;
const initialization_delay_ms = 150;
const idle_poll_ms = 1000;

pub const Error = error{ServerFailure};

var stop_requested: c.sig_atomic_t = 0;

fn handleSignal(_: c_int) callconv(.c) void {
    const flag: *volatile c.sig_atomic_t = &stop_requested;
    flag.* = 1;
}

const Connection = struct {
    fd: c_int,
    address: bluez.Address,
    control: controller.Controller,
};

const Server = struct {
    requested_address: ?[]const u8,
    connection: ?Connection = null,
    failure: support.ErrorMessage = .{},

    fn disconnect(self: *Server) void {
        if (self.connection) |connection| bluez.close(connection.fd);
        self.connection = null;
    }

    fn connect(self: *Server) !void {
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        const address = try bluez.discover(self.requested_address, &self.failure);
        const fd = try bluez.openControlChannel(address, deadline_ms, &self.failure);
        errdefer bluez.close(fd);

        self.connection = .{
            .fd = fd,
            .address = address,
            .control = .{
                .session = try aacp.Session.initialize(
                    fd,
                    deadline_ms,
                    initialization_delay_ms,
                    &self.failure,
                ),
            },
        };
    }

    fn replyFailure(self: *Server, client: c_int, deadline_ms: i64) void {
        var packet: [512]u8 = undefined;
        var ignored = support.ErrorMessage{};

        ipc.sendPacket(
            client,
            ipc.encodeFailure(&packet, self.failure.text()),
            deadline_ms,
            &ignored,
        ) catch {};
    }

    fn handleClient(self: *Server, client: c_int) void {
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        var packet: [512]u8 = undefined;
        const request = ipc.decodeRequest(
            ipc.receivePacket(client, &packet, deadline_ms, &self.failure) catch {
                self.replyFailure(client, deadline_ms);
                return;
            },
        ) catch {
            self.failure.set("session client sent an invalid request", .{});
            self.replyFailure(client, deadline_ms);
            return;
        };

        if (self.connection == null) self.connect() catch {
            self.replyFailure(client, deadline_ms);
            return;
        };
        if (request.requested_address) |requested| {
            if (!std.ascii.eqlIgnoreCase(requested, &self.connection.?.address.text)) {
                self.failure.set(
                    "session owns AirPods {s}, not {s}",
                    .{ self.connection.?.address.text, requested },
                );
                self.replyFailure(client, deadline_ms);
                return;
            }
        }

        ipc.sendPacket(client, ipc.encodeResult(
            &packet,
            self.connection.?.control.run(request.operation, deadline_ms) catch {
                self.replyFailure(client, deadline_ms);

                // A protocol failure leaves the stream and cached state unreliable; reconnect on demand.
                self.disconnect();
                return;
            },
        ), deadline_ms, &self.failure) catch {};
    }

    fn run(self: *Server, listener: c_int) Error!void {
        // Connect eagerly for fast first use, but remain available while the AirPods are absent.
        self.connect() catch {
            self.failure.len = 0;
        };

        while ((@as(*volatile c.sig_atomic_t, &stop_requested)).* == 0) {
            var descriptors = [_]c.struct_pollfd{
                .{ .fd = listener, .events = c.POLLIN, .revents = 0 },
                .{
                    .fd = if (self.connection) |connection| connection.fd else -1,
                    .events = c.POLLIN,
                    .revents = 0,
                },
            };
            if (c.poll(&descriptors, descriptors.len, idle_poll_ms) < 0) {
                if (support.lastErrno() == c.EINTR) continue;
                self.failure.setSystem("session service poll failed", support.lastErrno());
                return error.ServerFailure;
            }

            // Drain unsolicited AACP events here so feature handlers never race to read the channel.
            if (descriptors[1].revents & c.POLLIN != 0) {
                self.connection.?.control.session.channel.deadline_ms = transport.nowMs() + operation_timeout_ms;
                self.connection.?.control.receiveOne() catch self.disconnect();
            } else if (descriptors[1].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) {
                self.disconnect();
            }
            if (descriptors[0].revents & c.POLLIN != 0) {
                // Handle one bounded request at a time so setter acknowledgements remain ordered.
                const client = ipc.acceptClient(listener, &self.failure) catch continue;
                defer _ = c.close(client);
                self.handleClient(client);
            }
        }
    }
};

pub fn run(configuration: cli.ServeCommand, failure: *support.ErrorMessage) Error!void {
    const path = ipc.getSocketPath(failure) catch return error.ServerFailure;
    const listener = ipc.openListener(&path, failure) catch return error.ServerFailure;
    defer _ = c.close(listener);
    defer _ = c.unlink(path.sentinel().ptr);

    stop_requested = 0;
    _ = c.signal(c.SIGINT, handleSignal);
    _ = c.signal(c.SIGTERM, handleSignal);

    var service = Server{ .requested_address = configuration.requested_address };
    defer service.disconnect();
    service.run(listener) catch {
        failure.* = service.failure;
        return error.ServerFailure;
    };
}
