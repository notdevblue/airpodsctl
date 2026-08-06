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
    media_available: ?bool = null,
    logged_playing: ?bool = null,
    media_retry_at_ms: i64 = 0,
    route: ?pipewire_route.Monitor = null,
    route_available: ?bool = null,
    logged_route_state: ?pipewire_route.RouteState = null,
    route_retry_at_ms: i64 = 0,
    reconnect_at_ms: i64 = 0,
    reconnect_delay_ms: i64 = idle_poll_ms,
    failure: support.ErrorMessage = .{},

    fn needsPersistentConnection(self: *const Server) bool {
        return self.wear.mode != .off or self.switching.mode == .mpris;
    }

    fn disconnect(self: *Server) void {
        if (self.connection) |connection| {
            bluez.close(connection.fd);
            support.log(.debug, "Closed the AirPods control connection because its cached protocol state is no longer valid.", .{});
        }
        self.connection = null;
        self.wear.reset();
        self.switching.remoteTakeover();
        self.players.clear();
        if (self.needsPersistentConnection()) {
            self.reconnect_at_ms = transport.nowMs() + self.reconnect_delay_ms;
            if ((@as(*volatile c.sig_atomic_t, &stop_requested)).* == 0) support.log(
                .info,
                "Retrying the AirPods connection in {d} ms because enabled host policies require continuous AACP wear or routing notifications.",
                .{self.reconnect_delay_ms},
            );
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, max_reconnect_delay_ms);
        }
    }

    fn warnMedia(_: *Server, message: []const u8) void {
        support.warn(message);
    }

    fn logRouteState(self: *Server) void {
        const state = if (self.route) |*route| route.state() else return;
        if (self.logged_route_state != null and self.logged_route_state.? == state) return;

        self.logged_route_state = state;
        switch (state) {
            .selected => support.log(
                .info,
                "AirPods are the active audio output because PipeWire reports their exact A2DP sink as the default.",
                .{},
            ),
            .other => support.log(
                .info,
                "Automatic switching is suppressed because PipeWire reports a different default audio output.",
                .{},
            ),
            .unknown => support.log(
                .info,
                "Automatic switching is suppressed because PipeWire cannot identify an exact default AirPods A2DP sink.",
                .{},
            ),
        }
    }

    fn closeRoute(self: *Server) void {
        if (self.route) |*route| {
            route.deinit();
            support.log(
                .debug,
                "Closed the PipeWire route monitor because its state is no longer reliable for automatic switching.",
                .{},
            );
        }
        self.route = null;
        self.route_available = false;
        self.logged_route_state = null;
        self.route_retry_at_ms = transport.nowMs() + idle_poll_ms;
    }

    fn ensureRoute(self: *Server) void {
        if (self.switching.mode != .mpris or self.route != null or self.connection == null or
            transport.nowMs() < self.route_retry_at_ms)
        {
            return;
        }
        if (self.route_available == null or self.route_available.?) {
            support.log(
                .debug,
                "Starting PipeWire route monitoring because automatic switching requires an exact default AirPods A2DP sink.",
                .{},
            );
        }
        self.route = .{};
        self.route.?.init(self.connection.?.address.text) catch {
            self.route = null;
            self.route_retry_at_ms = transport.nowMs() + idle_poll_ms;
            if (self.route_available == null or self.route_available.?) support.log(
                .warn,
                "PipeWire route monitoring is unavailable, so automatic switching is suppressed; retrying in {d} ms.",
                .{idle_poll_ms},
            );
            self.route_available = false;
            return;
        };
        if (self.route_available == null or !self.route_available.?) {
            support.log(
                .debug,
                "PipeWire route monitoring is available because the registry and default-sink listeners initialized successfully.",
                .{},
            );
        }
        self.route_available = true;
        self.logRouteState();
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
            .wear => |report| {
                const owns_media = self.players.hasOwnership();
                const evaluation = self.wear.evaluateWear(report, owns_media);
                switch (evaluation.reason) {
                    .disabled => support.log(
                        .debug,
                        "Ignored the wear update because pause-on-removal is disabled.",
                        .{},
                    ),
                    .incomplete_state => support.log(
                        .info,
                        "Suppressed pause-on-removal and reset its baseline because at least one protocol role has an unknown wear state.",
                        .{},
                    ),
                    .baseline => support.log(
                        .info,
                        "Recorded {d} in-ear earbuds as the baseline because the first complete wear snapshot after connecting or resetting must never change media.",
                        .{evaluation.current_count.?},
                    ),
                    .unchanged => support.log(
                        .debug,
                        "Took no media action because the in-ear count remained {d}, so no policy threshold was crossed.",
                        .{evaluation.current_count.?},
                    ),
                    .pause_threshold => support.log(
                        .debug,
                        "Selected pause because the in-ear count changed from {d} to {d}, crossing the '{s}' removal threshold ({s}).",
                        .{
                            evaluation.previous_count.?,
                            evaluation.current_count.?,
                            @tagName(self.wear.mode),
                            if (self.wear.mode == .one) "2 to fewer than 2" else "at least 1 to 0",
                        },
                    ),
                    .resume_threshold => support.log(
                        .debug,
                        "Selected resume because the in-ear count changed from {d} to {d}, crossing the '{s}' insertion threshold ({s}), and airpodsctl owns confirmed MPRIS pauses.",
                        .{
                            evaluation.previous_count.?,
                            evaluation.current_count.?,
                            @tagName(self.wear.mode),
                            if (self.wear.mode == .one) "fewer than 2 to 2" else "0 to at least 1",
                        },
                    ),
                    .resume_not_owned => support.log(
                        .info,
                        "Did not resume media after the in-ear count changed from {d} to {d}, crossing the '{s}' insertion threshold, because airpodsctl owns no confirmed MPRIS pause transitions.",
                        .{
                            evaluation.previous_count.?,
                            evaluation.current_count.?,
                            @tagName(self.wear.mode),
                        },
                    ),
                    .transition_irrelevant => support.log(
                        .debug,
                        "Took no media action because the in-ear count changed from {d} to {d} without crossing the '{s}' policy threshold.",
                        .{
                            evaluation.previous_count.?,
                            evaluation.current_count.?,
                            @tagName(self.wear.mode),
                        },
                    ),
                }

                switch (evaluation.decision) {
                    .none => {},
                    .pause_media => {
                        support.log(
                            .info,
                            "Pausing eligible MPRIS players because the in-ear count changed from {d} to {d}, crossing the enabled '{s}' removal threshold.",
                            .{
                                evaluation.previous_count.?,
                                evaluation.current_count.?,
                                @tagName(self.wear.mode),
                            },
                        );
                        self.players.pausePlayers() catch {
                            self.warnMedia("MPRIS players could not be paused because the user D-Bus operation failed; no automatic-resume ownership was recorded.");
                            return;
                        };
                        if (self.players.hasOwnership()) {
                            support.log(
                                .info,
                                "Automatic resume is armed because at least one MPRIS player confirmed its transition from Playing to Paused.",
                                .{},
                            );
                        } else {
                            support.log(
                                .info,
                                "Automatic resume is not armed because no eligible MPRIS player confirmed a transition from Playing to Paused.",
                                .{},
                            );
                        }
                    },
                    .resume_media => {
                        support.log(
                            .info,
                            "Resuming owned MPRIS players because the in-ear count changed from {d} to {d}, crossing the enabled '{s}' insertion threshold, and airpodsctl still owns their confirmed pause transitions.",
                            .{
                                evaluation.previous_count.?,
                                evaluation.current_count.?,
                                @tagName(self.wear.mode),
                            },
                        );
                        self.players.resumePlayers() catch {
                            self.players.clear();
                            self.warnMedia("MPRIS players could not be resumed because the user D-Bus operation failed; stale automatic-resume ownership was cleared.");
                            return;
                        };
                        support.log(
                            .info,
                            "Automatic resume completed because every still-eligible MPRIS player was evaluated and ownership was cleared.",
                            .{},
                        );
                    },
                }
            },
            .routing => |status| {
                if (self.switching.service_owns and status.owner != .linux) {
                    support.log(
                        .info,
                        "Cleared Linux switching ownership because an AirPods routing notification reports that Linux no longer owns audio.",
                        .{},
                    );
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
        support.log(
            .debug,
            "Looking for connected AirPods because the service needs a live control session for client requests and enabled policies.",
            .{},
        );
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        const address = try bluez.discover(self.requested_address, &self.failure);
        const fd = try bluez.openControlChannel(address, deadline_ms, &self.failure);
        errdefer bluez.close(fd);
        support.log(
            .debug,
            "The Bluetooth control channel is connected because the selected AirPods accepted the AACP L2CAP connection.",
            .{},
        );

        var control = controller.Controller{
            .session = try aacp.Session.initialize(
                fd,
                deadline_ms,
                initialization_delay_ms,
                &self.failure,
            ),
            .local_address = try bluez.localAddress(fd, &self.failure),
        };
        support.log(
            .info,
            "The AirPods control session is ready because its handshake and notification subscription completed.",
            .{},
        );
        if (self.switching.mode == .mpris) {
            support.log(
                .debug,
                "Requesting initial AirPods routing state because automatic switching must prove multipoint readiness and remote idleness.",
                .{},
            );
            try control.requestRoutingStatus(deadline_ms);
        }

        self.connection = .{
            .fd = fd,
            .address = address,
            .control = control,
        };
        self.reconnect_at_ms = 0;
        self.reconnect_delay_ms = idle_poll_ms;
        support.log(
            .debug,
            "The service connection is usable because Bluetooth, AACP, local-address discovery, and required routing initialization succeeded.",
            .{},
        );
        self.ensureRoute();
    }

    fn ensureConnection(self: *Server) void {
        if (self.connection != null or !self.needsPersistentConnection() or
            transport.nowMs() < self.reconnect_at_ms)
        {
            return;
        }
        self.connect() catch {
            support.log(
                .warn,
                "The AirPods reconnect attempt failed because discovery or control-session initialization did not complete; retrying in {d} ms.",
                .{self.reconnect_delay_ms},
            );
            self.reconnect_at_ms = transport.nowMs() + self.reconnect_delay_ms;
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, max_reconnect_delay_ms);
            self.failure.len = 0;
        };
    }

    fn performSwitching(self: *Server, action: switching_policy.Action) void {
        if (action == .none) return;
        support.emit(
            .info,
            if (action == .take)
                "Requesting AirPods audio ownership because a new MPRIS Playing edge satisfied the route, multipoint, remote-idle, and suppression checks."
            else
                "Releasing AirPods audio ownership because all tracked MPRIS players remained idle for 30 seconds after an automatic take.",
        );
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        const connection = if (self.connection) |*value| value else {
            self.switching.operationFailed();
            support.log(
                .warn,
                "Automatic switching was suppressed because the AirPods control connection disappeared before the ownership request could be sent.",
                .{},
            );
            return;
        };
        _ = connection.control.runWithObserver(.{ .switching = .{
            .action = if (action == .take) .take else .release,
        } }, deadline_ms, .{
            .context = self,
            .callback = observeControllerEvent,
        }) catch {
            self.switching.operationFailed();
            self.warnMedia("Automatic switching was suppressed because the AirPods did not return a valid ownership acknowledgement before the operation deadline.");
            self.failure.len = 0;
            self.disconnect();
            return;
        };

        if (action == .take) {
            self.switching.takeSucceeded(transport.nowMs());
        } else {
            self.switching.releaseSucceeded();
        }
        support.emit(
            .info,
            if (action == .take)
                "Linux now owns AirPods audio because the ownership acknowledgement confirmed the automatic take."
            else
                "Linux released AirPods audio because the ownership acknowledgement confirmed the automatic release.",
        );
    }

    fn handlePlayback(self: *Server, update: media.PlaybackUpdate) void {
        if (self.logged_playing == null or self.logged_playing.? != update.playing) {
            self.logged_playing = update.playing;
            support.emit(
                .debug,
                if (update.playing)
                    "MPRIS playback is active because at least one tracked player reports Playing."
                else
                    "MPRIS playback is idle because no tracked player reports Playing.",
            );
        }

        const previous_release = self.switching.release_at_ms;
        const eligibility = self.switchingEligibility();
        const action = self.switching.updatePlayback(
            transport.nowMs(),
            update.playing,
            update.play_edge,
            eligibility,
        );
        if (update.play_edge) support.log(
            .debug,
            "Evaluated a new MPRIS Playing edge: AirPods route {s}, multipoint {s}, remote host {s}; decision '{s}' because automatic take requires all three conditions and no active suppression.",
            .{
                if (eligibility.route_selected) "selected" else "not selected",
                if (eligibility.multipoint_ready) "ready" else "not ready",
                if (eligibility.remote_idle) "idle" else "active or unknown",
                @tagName(action),
            },
        );
        if (previous_release == null and self.switching.release_at_ms != null) {
            support.log(
                .info,
                "Scheduled AirPods ownership release in 30 seconds because Linux owns an automatic take and every tracked MPRIS player is idle.",
                .{},
            );
        } else if (previous_release != null and self.switching.release_at_ms == null and update.playing) {
            support.log(
                .info,
                "Cancelled the pending AirPods ownership release because MPRIS playback became active before the 30-second idle deadline.",
                .{},
            );
        }
        self.performSwitching(action);
    }

    fn ensurePlayback(self: *Server) void {
        if ((self.switching.mode == .off and !self.switching.service_owns) or
            transport.nowMs() < self.media_retry_at_ms)
        {
            return;
        }

        const update = self.players.monitorPlayback() catch {
            if (self.media_available == null or self.media_available.?) support.log(
                .warn,
                "MPRIS monitoring is unavailable because the user D-Bus connection or playback refresh failed; retrying in {d} ms.",
                .{idle_poll_ms},
            );
            self.media_available = false;
            self.logged_playing = null;
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
        };
        if (self.media_available == null or !self.media_available.?) {
            support.log(
                .debug,
                "MPRIS monitoring is available because the user D-Bus subscriptions and initial playback snapshot succeeded.",
                .{},
            );
        }
        self.media_available = true;
        self.media_retry_at_ms = 0;
        self.handlePlayback(update);
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
                support.log(
                    .warn,
                    "Rejected a session client because its request could not be received before the bounded IPC deadline.",
                    .{},
                );
                self.replyFailure(client, deadline_ms, .v1);
                return;
            },
        ) catch {
            self.failure.set("session client sent an invalid request", .{});
            support.log(
                .warn,
                "Rejected a session client because its packet did not decode as a supported versioned operation.",
                .{},
            );
            self.replyFailure(client, deadline_ms, .v1);
            return;
        };
        support.log(
            .debug,
            "Accepted the session client's '{s}' request because its IPC version, operation, and bounded payload were valid.",
            .{request.operation.name()},
        );

        if (self.connection == null) self.connect() catch {
            support.log(
                .warn,
                "The session client's '{s}' request could not run because no AirPods control session could be initialized.",
                .{request.operation.name()},
            );
            self.replyFailure(client, deadline_ms, request.version);
            return;
        };
        if (request.requested_address) |requested| {
            if (!std.ascii.eqlIgnoreCase(requested, &self.connection.?.address.text)) {
                self.failure.set(
                    "session owns AirPods {s}, not {s}",
                    .{ self.connection.?.address.text, requested },
                );
                support.log(
                    .warn,
                    "Rejected the session client because its requested device does not match the AirPods pair owned by this service.",
                    .{},
                );
                self.replyFailure(client, deadline_ms, request.version);
                return;
            }
        }

        const result = self.connection.?.control.runWithObserver(request.operation, deadline_ms, .{
            .context = self,
            .callback = observeControllerEvent,
        }) catch {
            support.log(
                .warn,
                "The session client's '{s}' request failed because the AirPods protocol exchange did not produce a valid acknowledgement before the deadline.",
                .{request.operation.name()},
            );
            self.replyFailure(client, deadline_ms, request.version);

            // A protocol failure leaves the stream and cached state unreliable; let policy recovery reconnect it.
            self.disconnect();
            return;
        };
        if (request.operation == .switching) switch (request.operation.switching.action) {
            .status => {},
            .take => {
                self.switching.takeSucceeded(transport.nowMs());
                support.log(
                    .debug,
                    "Recorded Linux switching ownership because the explicit take received a valid AirPods acknowledgement.",
                    .{},
                );
            },
            .release => {
                self.switching.releaseSucceeded();
                support.log(
                    .debug,
                    "Cleared Linux switching ownership because the explicit release received a valid AirPods acknowledgement.",
                    .{},
                );
            },
        };
        ipc.sendPacket(client, ipc.encodeResultForVersion(
            &packet,
            result,
            request.version,
        ), deadline_ms, &self.failure) catch {
            support.log(
                .warn,
                "The '{s}' result could not be returned because the session client closed or stopped reading its local socket.",
                .{request.operation.name()},
            );
            return;
        };
        support.log(
            .debug,
            "Completed the session client's '{s}' request because its typed result was encoded and sent successfully.",
            .{request.operation.name()},
        );
    }

    fn run(self: *Server, listener: c_int) Error!void {
        // Connect eagerly for fast first use, but remain available while the AirPods are absent.
        self.connect() catch {
            support.log(
                .warn,
                "The initial AirPods connection is unavailable because discovery or control-session initialization failed; the session listener remains ready for later requests.",
                .{},
            );
            self.failure.len = 0;
            if (self.needsPersistentConnection()) {
                self.reconnect_at_ms = transport.nowMs() + self.reconnect_delay_ms;
                support.log(
                    .info,
                    "Retrying the AirPods connection in {d} ms because enabled host policies require continuous AACP wear or routing notifications.",
                    .{self.reconnect_delay_ms},
                );
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
                    support.log(
                        .warn,
                        "Discarding the AirPods control session because an unsolicited AACP packet could not be received or decoded safely.",
                        .{},
                    );
                    self.disconnect();
                    continue;
                };
                if (event) |value| self.handleControllerEvent(value);
            } else if (descriptors[1].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) {
                support.log(
                    .warn,
                    "Discarding the AirPods control session because poll reported an error or hangup on the Bluetooth channel.",
                    .{},
                );
                self.disconnect();
            }
            if (descriptors[2].revents != 0) {
                self.players.dispatch() catch {
                    self.warnMedia("MPRIS monitoring was reset because the user D-Bus dispatcher failed; retrying after the bounded media backoff.");
                    self.media_available = false;
                    self.logged_playing = null;
                    self.media_retry_at_ms = transport.nowMs() + idle_poll_ms;
                };
                self.ensurePlayback();
            }
            if (descriptors[3].revents & c.POLLIN != 0) {
                if (self.route) |*route| route.dispatch() catch {
                    support.log(
                        .warn,
                        "PipeWire route monitoring was reset because dispatch failed; automatic switching remains suppressed until monitoring recovers.",
                        .{},
                    );
                    self.closeRoute();
                };
                self.logRouteState();
            } else if (descriptors[3].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) {
                support.log(
                    .warn,
                    "PipeWire route monitoring was reset because poll reported an error or hangup; automatic switching remains suppressed until monitoring recovers.",
                    .{},
                );
                self.closeRoute();
            }
            if (descriptors[0].revents & c.POLLIN != 0) {
                // Handle one bounded request at a time so setter acknowledgements remain ordered.
                const client = ipc.acceptClient(listener, &self.failure) catch {
                    support.log(
                        .warn,
                        "Rejected a session client because accept or same-user credential validation failed.",
                        .{},
                    );
                    continue;
                };
                defer _ = c.close(client);
                self.handleClient(client);
            }
            self.performSwitching(self.switching.tick(transport.nowMs()));
        }
        support.log(.info, "Stopping the session service because SIGINT or SIGTERM requested an orderly shutdown.", .{});
    }
};

pub fn run(configuration: cli.ServeCommand, failure: *support.ErrorMessage) Error!void {
    support.log(
        .info,
        "Starting the session service with pause-on-removal '{s}' and automatic switching '{s}' because those policies were selected on the command line.",
        .{ @tagName(configuration.pause_on_removal), @tagName(configuration.auto_switch) },
    );
    const path = ipc.getSocketPath(failure) catch return error.ServerFailure;
    const listener = ipc.openListener(&path, failure) catch return error.ServerFailure;
    defer _ = c.close(listener);
    defer _ = c.unlink(path.sentinel().ptr);
    support.log(
        .debug,
        "The session listener is ready because its owner-only SOCK_SEQPACKET socket was bound with same-user peer validation.",
        .{},
    );

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
