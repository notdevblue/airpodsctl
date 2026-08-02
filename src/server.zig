const std = @import("std");
const aacp = @import("aacp");
const bluez = @import("bluez");
const cli = @import("cli");
const controller = @import("controller");
const ipc = @import("ipc");
const media = @import("media");
const pipewire_route = @import("pipewire_route");
const support = @import("support");
const switching_policy = @import("switching_policy");
const transport = @import("transport");
const wear_policy = @import("wear_policy");

const c = support.c;
const operation_timeout_ms = 3000;
const initialization_delay_ms = 150;
const idle_poll_ms = 1000;
const max_reconnect_delay_ms = 30_000;

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
    wear: wear_policy.Policy,
    switching: switching_policy.Policy,
    connection: ?Connection = null,
    players: media.Controller = .{},
    media_retry_at_ms: i64 = 0,
    route: ?pipewire_route.Monitor = null,
    route_retry_at_ms: i64 = 0,
    reconnect_at_ms: i64 = 0,
    reconnect_delay_ms: i64 = idle_poll_ms,
    failure: support.ErrorMessage = .{},

    fn disconnect(self: *Server) void {
        if (self.connection) |connection| bluez.close(connection.fd);
        self.connection = null;
        self.wear.reset();
        self.switching.remoteTakeover();
        self.players.clear();
        if (self.switching.mode == .mpris) {
            self.reconnect_at_ms = transport.nowMs() + self.reconnect_delay_ms;
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, max_reconnect_delay_ms);
        }
    }

    fn warnMedia(_: *Server, message: []const u8) void {
        support.warn(message);
    }

    fn closeRoute(self: *Server) void {
        if (self.route) |*route| route.deinit();
        self.route = null;
        self.route_retry_at_ms = transport.nowMs() + idle_poll_ms;
        self.players.clear();
    }

    fn ensureRoute(self: *Server) void {
        if ((self.wear.mode == .off and self.switching.mode == .off) or
            self.route != null or self.connection == null or
            transport.nowMs() < self.route_retry_at_ms)
        {
            return;
        }
        self.route = .{};
        self.route.?.init(self.connection.?.address.text) catch {
            self.route = null;
            self.route_retry_at_ms = transport.nowMs() + idle_poll_ms;
            return;
        };
    }

    fn selectedRoute(self: *const Server) bool {
        return if (self.route) |*route| route.state() == .selected else false;
    }

    fn switchingEligibility(self: *const Server) switching_policy.Eligibility {
        const status = if (self.connection) |connection|
            connection.control.state.routing.status()
        else
            return .{ .route_selected = false, .multipoint_ready = false, .remote_idle = false };

        return .{
            .route_selected = self.selectedRoute(),
            .multipoint_ready = status.isReady(),
            .remote_idle = status.remote_activity == .idle,
        };
    }

    fn handleControllerEvent(self: *Server, event: controller.Event) void {
        switch (event) {
            .automatic_ear_detection => |setting| {
                self.wear.updateSetting(
                    setting,
                    if (self.connection) |*connection| connection.control.state.wear else null,
                );
                if (setting == .off) self.players.clear();
            },
            .wear => |report| {
                switch (self.wear.updateWear(report, self.players.hasOwnership())) {
                    .none => {},
                    .pause_media => {
                        if (!self.selectedRoute()) return;
                        self.players.pausePlayers() catch {
                            self.warnMedia("cannot pause MPRIS media players");
                        };
                    },
                    .resume_media => {
                        if (!self.selectedRoute()) {
                            self.players.clear();
                            return;
                        }
                        self.players.resumePlayers() catch {
                            self.players.clear();
                            self.warnMedia("cannot resume MPRIS media players");
                        };
                    },
                }
            },
            .routing => |status| {
                if (self.switching.service_owns and status.owner != .linux) {
                    self.switching.remoteTakeover();
                }
            },
            .listening_mode, .battery => {},
        }
    }

    fn observeControllerEvent(context: ?*anyopaque, event: controller.Event) void {
        const self: *Server = @ptrCast(@alignCast(context.?));
        self.handleControllerEvent(event);
    }

    fn connect(self: *Server) !void {
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        const address = try bluez.discover(self.requested_address, &self.failure);
        const fd = try bluez.openControlChannel(address, deadline_ms, &self.failure);
        errdefer bluez.close(fd);

        var control = controller.Controller{
            .session = try aacp.Session.initialize(
                fd,
                deadline_ms,
                initialization_delay_ms,
                &self.failure,
            ),
            .local_address = try bluez.localAddress(fd, &self.failure),
        };
        if (self.switching.mode == .mpris) try control.requestRoutingStatus(deadline_ms);

        self.connection = .{
            .fd = fd,
            .address = address,
            .control = control,
        };
        self.reconnect_at_ms = 0;
        self.reconnect_delay_ms = idle_poll_ms;
        self.ensureRoute();
    }

    fn ensureConnection(self: *Server) void {
        if (self.connection != null or self.switching.mode != .mpris or
            transport.nowMs() < self.reconnect_at_ms)
        {
            return;
        }
        self.connect() catch {
            self.reconnect_at_ms = transport.nowMs() + self.reconnect_delay_ms;
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, max_reconnect_delay_ms);
            self.failure.len = 0;
        };
    }

    fn performSwitching(self: *Server, action: switching_policy.Action) void {
        if (action == .none) return;
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        const connection = if (self.connection) |*value| value else {
            self.switching.operationFailed();
            return;
        };
        _ = connection.control.runWithObserver(.{ .switching = .{
            .action = if (action == .take) .take else .release,
        } }, deadline_ms, .{
            .context = self,
            .callback = observeControllerEvent,
        }) catch {
            self.switching.operationFailed();
            self.warnMedia("automatic AirPods switching failed");
            self.failure.len = 0;
            self.disconnect();
            return;
        };

        if (action == .take) {
            self.switching.takeSucceeded(transport.nowMs());
        } else {
            self.switching.releaseSucceeded();
        }
    }

    fn handlePlayback(self: *Server, update: media.PlaybackUpdate) void {
        self.performSwitching(self.switching.updatePlayback(
            transport.nowMs(),
            update.playing,
            update.play_edge,
            self.switchingEligibility(),
        ));
    }

    fn ensurePlayback(self: *Server) void {
        if ((self.switching.mode == .off and !self.switching.service_owns) or
            transport.nowMs() < self.media_retry_at_ms)
        {
            return;
        }

        self.handlePlayback(self.players.monitorPlayback() catch {
            self.media_retry_at_ms = transport.nowMs() + idle_poll_ms;
            if (self.switching.service_owns) {
                _ = self.switching.updatePlayback(
                    transport.nowMs(),
                    false,
                    false,
                    .{ .route_selected = false, .multipoint_ready = false, .remote_idle = false },
                );
            }
            return;
        });
        self.media_retry_at_ms = 0;
    }

    fn replyFailure(
        self: *Server,
        client: c_int,
        deadline_ms: i64,
        version: ipc.ProtocolVersion,
    ) void {
        var packet: [512]u8 = undefined;
        var ignored = support.ErrorMessage{};

        ipc.sendPacket(
            client,
            ipc.encodeFailureForVersion(&packet, self.failure.text(), version),
            deadline_ms,
            &ignored,
        ) catch {};
    }

    fn handleClient(self: *Server, client: c_int) void {
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        var packet: [512]u8 = undefined;
        const request = ipc.decodeRequest(
            ipc.receivePacket(client, &packet, deadline_ms, &self.failure) catch {
                self.replyFailure(client, deadline_ms, .v1);
                return;
            },
        ) catch {
            self.failure.set("session client sent an invalid request", .{});
            self.replyFailure(client, deadline_ms, .v1);
            return;
        };

        if (self.connection == null) self.connect() catch {
            self.replyFailure(client, deadline_ms, request.version);
            return;
        };
        if (request.requested_address) |requested| {
            if (!std.ascii.eqlIgnoreCase(requested, &self.connection.?.address.text)) {
                self.failure.set(
                    "session owns AirPods {s}, not {s}",
                    .{ self.connection.?.address.text, requested },
                );
                self.replyFailure(client, deadline_ms, request.version);
                return;
            }
        }

        const result = self.connection.?.control.runWithObserver(request.operation, deadline_ms, .{
            .context = self,
            .callback = observeControllerEvent,
        }) catch {
            self.replyFailure(client, deadline_ms, request.version);

            // A protocol failure leaves the stream and cached state unreliable; reconnect on demand.
            self.disconnect();
            return;
        };
        if (request.operation == .switching) switch (request.operation.switching.action) {
            .status => {},
            .take => self.switching.takeSucceeded(transport.nowMs()),
            .release => self.switching.releaseSucceeded(),
        };
        ipc.sendPacket(client, ipc.encodeResultForVersion(
            &packet,
            result,
            request.version,
        ), deadline_ms, &self.failure) catch {};
    }

    fn run(self: *Server, listener: c_int) Error!void {
        // Connect eagerly for fast first use, but remain available while the AirPods are absent.
        self.connect() catch {
            self.failure.len = 0;
            if (self.switching.mode == .mpris) {
                self.reconnect_at_ms = transport.nowMs() + self.reconnect_delay_ms;
            }
        };

        while ((@as(*volatile c.sig_atomic_t, &stop_requested)).* == 0) {
            self.ensureConnection();
            self.ensureRoute();
            self.ensurePlayback();
            var descriptors = [_]c.struct_pollfd{
                .{ .fd = listener, .events = c.POLLIN, .revents = 0 },
                .{
                    .fd = if (self.connection) |connection| connection.fd else -1,
                    .events = c.POLLIN,
                    .revents = 0,
                },
                .{
                    .fd = self.players.fd(),
                    .events = self.players.events(),
                    .revents = 0,
                },
                .{
                    .fd = if (self.route) |*route| route.fd() else -1,
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
                const event = self.connection.?.control.receiveOne() catch {
                    self.disconnect();
                    continue;
                };
                if (event) |value| self.handleControllerEvent(value);
            } else if (descriptors[1].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) {
                self.disconnect();
            }
            if (descriptors[2].revents != 0) {
                self.players.dispatch() catch {
                    self.warnMedia("lost the user D-Bus media connection");
                    self.media_retry_at_ms = transport.nowMs() + idle_poll_ms;
                };
                self.ensurePlayback();
            }
            if (descriptors[3].revents & c.POLLIN != 0) {
                if (self.route) |*route| route.dispatch() catch {
                    self.closeRoute();
                };
                if (!self.selectedRoute()) self.players.clear();
            } else if (descriptors[3].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) {
                self.closeRoute();
            }
            if (descriptors[0].revents & c.POLLIN != 0) {
                // Handle one bounded request at a time so setter acknowledgements remain ordered.
                const client = ipc.acceptClient(listener, &self.failure) catch continue;
                defer _ = c.close(client);
                self.handleClient(client);
            }
            self.performSwitching(self.switching.tick(transport.nowMs()));
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

    var service = Server{
        .requested_address = configuration.requested_address,
        .wear = .{ .mode = configuration.pause_on_removal },
        .switching = .{ .mode = configuration.auto_switch },
    };
    defer {
        service.disconnect();
        service.closeRoute();
        service.players.deinit();
    }
    service.run(listener) catch {
        failure.* = service.failure;
        return error.ServerFailure;
    };
}
