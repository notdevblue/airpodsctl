const aacp = @import("aacp");
const battery = @import("battery");
const command = @import("command");
const control_command = @import("control_command");
const noise_control = @import("noise_control");
const smart_routing = @import("smart_routing");
const support = @import("support");
const wear_detection = @import("wear_detection");

pub const Error = aacp.Error;

pub const State = struct {
    listening_mode: ?noise_control.Mode = null,
    listening_mode_generation: u64 = 0,
    battery: battery.Report = .{},
    battery_generation: u64 = 0,
    wear: ?wear_detection.WearReport = null,
    wear_generation: u64 = 0,
    routing: smart_routing.State = .{},
    routing_generation: u64 = 0,
    connected_devices_generation: u64 = 0,
    ownership_generation: u64 = 0,
};

pub const Event = union(enum) {
    listening_mode: noise_control.Mode,
    battery: battery.Report,
    wear: wear_detection.WearReport,
    routing: smart_routing.Status,
};

fn ignoreEvent(_: ?*anyopaque, _: Event) void {}

pub const EventObserver = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Event) void = ignoreEvent,

    pub fn notify(self: EventObserver, event: ?Event) void {
        if (event) |value| self.callback(self.context, value);
    }
};

fn loggedEvent(event: Event) Event {
    switch (event) {
        .listening_mode => |mode| support.log(
            .debug,
            "The listening mode is now '{s}' because the AirPods sent a valid control-command notification.",
            .{mode.name()},
        ),
        .battery => |report| {
            if (report.left) |reading| support.log(
                .debug,
                "The left earbud reports {d}% and {s}.",
                .{ reading.level, reading.state.name() },
            );
            if (report.right) |reading| support.log(
                .debug,
                "The right earbud reports {d}% and {s}.",
                .{ reading.level, reading.state.name() },
            );
        },
        .wear => |report| support.log(
            .debug,
            "The wear state is primary '{s}', secondary '{s}' because the AirPods sent a valid wear notification.",
            .{ report.primary.name(), report.secondary.name() },
        ),
        .routing => |status| support.log(
            .debug,
            "Routing is '{s}', hosts '{s}', owner '{s}', remote activity '{s}' because the AirPods routing state changed.",
            .{
                status.multipointName(),
                status.hosts.name(),
                status.owner.name(),
                status.remote_activity.name(),
            },
        ),
    }
    return event;
}

pub const Controller = struct {
    session: aacp.Session,
    local_address: ?smart_routing.Address = null,
    state: State = .{},

    pub fn receiveOne(self: *Controller) Error!?Event {
        const packet = try self.session.receive();

        if (control_command.parsePacket(packet) catch {
            self.session.channel.failure.set("AirPods returned an invalid control-command response", .{});
            return error.ProtocolFailure;
        }) |control_state| {
            if (noise_control.parseCommand(control_state) catch {
                self.session.channel.failure.set("AirPods returned an invalid listening-mode response", .{});
                return error.ProtocolFailure;
            }) |mode| {
                self.state.listening_mode = mode;
                self.state.listening_mode_generation +%= 1;
                return loggedEvent(.{ .listening_mode = mode });
            }
            if (smart_routing.parseOwnership(control_state) catch {
                self.session.channel.failure.set("AirPods returned an invalid routing-ownership response", .{});
                return error.ProtocolFailure;
            }) |owns| {
                self.state.routing.updateOwnership(owns);
                self.state.ownership_generation +%= 1;
                self.state.routing_generation +%= 1;
                return loggedEvent(.{ .routing = self.state.routing.status() });
            }
            return null;
        }
        if (smart_routing.parsePacket(packet) catch {
            self.session.channel.failure.set("AirPods returned an invalid smart-routing response", .{});
            return error.ProtocolFailure;
        }) |routing_packet| {
            switch (routing_packet) {
                .audio_source => |source| if (self.local_address) |local| {
                    self.state.routing.updateAudioSource(source, local);
                },
                .connected_devices => |devices| {
                    if (self.local_address) |local| {
                        self.state.routing.updateConnectedDevices(devices, local);
                    }
                    self.state.connected_devices_generation +%= 1;
                },
            }
            self.state.routing_generation +%= 1;
            return loggedEvent(.{ .routing = self.state.routing.status() });
        }
        if (wear_detection.parseWearPacket(packet) catch {
            self.session.channel.failure.set("AirPods returned an invalid wear-state response", .{});
            return error.ProtocolFailure;
        }) |report| {
            self.state.wear = report;
            self.state.wear_generation +%= 1;
            return loggedEvent(.{ .wear = report });
        }
        if (battery.parsePacket(packet) catch {
            self.session.channel.failure.set("AirPods returned an invalid battery response", .{});
            return error.ProtocolFailure;
        }) |report| {
            // A notification may contain only one earbud, so preserve the other cached reading.
            if (report.left) |reading| self.state.battery.left = reading;
            if (report.right) |reading| self.state.battery.right = reading;
            if (report.left != null or report.right != null) {
                self.state.battery_generation +%= 1;
                return loggedEvent(.{ .battery = report });
            }
        }
        return null;
    }

    fn receiveObserved(self: *Controller, observer: EventObserver) Error!void {
        observer.notify(try self.receiveOne());
    }

    fn refreshRouting(self: *Controller, observer: EventObserver) Error!smart_routing.Status {
        if (self.local_address == null) {
            self.session.channel.failure.set("cannot determine the local Bluetooth address for switching", .{});
            return error.ProtocolFailure;
        }

        const previous_generation = self.state.connected_devices_generation;
        try smart_routing.requestStatus(&self.session);
        while (self.state.connected_devices_generation == previous_generation) {
            try self.receiveObserved(observer);
        }
        return self.state.routing.status();
    }

    fn runSwitching(
        self: *Controller,
        request: command.Switching,
        observer: EventObserver,
    ) Error!command.Result {
        var status = try self.refreshRouting(observer);
        switch (request.action) {
            .status => return .{ .switching = status },
            .take => {
                if (status.hosts != .local_and_remote) {
                    self.session.channel.failure.set(
                        "AirPods multipoint is not ready; connect the iPhone and verify the BlueZ DeviceID setup",
                        .{},
                    );
                    return error.ProtocolFailure;
                }
                if (status.owner == .linux) return .{ .switching = status };
                if (!request.force and (status.owner == .unknown or status.remote_activity != .idle)) {
                    self.session.channel.failure.set(
                        "remote AirPods activity is not confirmed idle; use switching take --force to override it",
                        .{},
                    );
                    return error.ProtocolFailure;
                }
            },
            .release => {
                if (status.owner == .remote or status.owner == .none) return .{ .switching = status };
                if (status.owner == .unknown) {
                    self.session.channel.failure.set("AirPods routing ownership is unknown", .{});
                    return error.ProtocolFailure;
                }
            },
        }

        const target_owns = request.action == .take;
        const previous_generation = self.state.ownership_generation;
        try smart_routing.setOwnership(&self.session, target_owns);
        while (self.state.ownership_generation == previous_generation or
            self.state.routing.local_owns == null or self.state.routing.local_owns.? != target_owns)
        {
            self.receiveObserved(observer) catch |failure| {
                self.session.channel.failure.set(
                    "AirPods did not acknowledge switching ownership {s} before the timeout",
                    .{if (target_owns) "take" else "release"},
                );
                return failure;
            };
        }
        status = self.state.routing.status();
        return .{ .switching = status };
    }

    pub fn requestRoutingStatus(self: *Controller, deadline_ms: i64) Error!void {
        self.session.channel.deadline_ms = deadline_ms;
        try smart_routing.requestStatus(&self.session);
    }

    pub fn runWithObserver(
        self: *Controller,
        operation: command.Operation,
        deadline_ms: i64,
        observer: EventObserver,
    ) Error!command.Result {
        self.session.channel.deadline_ms = deadline_ms;

        return switch (operation) {
            .noise_control => |request| result: {
                while (self.state.listening_mode == null) try self.receiveObserved(observer);
                const final_mode = noise_control.targetMode(
                    request.action,
                    self.state.listening_mode.?,
                    request.toggle_modes[0..request.toggle_mode_count],
                );
                if (request.action != .status) {
                    const previous_generation = self.state.listening_mode_generation;
                    try noise_control.setMode(&self.session, final_mode);

                    // A newer matching event is the acknowledgement; cached state cannot confirm a write.
                    while (self.state.listening_mode_generation == previous_generation or
                        self.state.listening_mode.? != final_mode)
                    {
                        self.receiveObserved(observer) catch |failure| {
                            if (self.state.listening_mode_generation != previous_generation) {
                                self.session.channel.failure.set(
                                    "AirPods did not acknowledge {s}; the last reported mode was {s}",
                                    .{ final_mode.name(), self.state.listening_mode.?.name() },
                                );
                            }
                            return failure;
                        };
                    }
                }
                break :result .{ .mode = final_mode };
            },
            .battery => |component| .{ .battery = .{
                .component = component,
                .report = if ((component == null and self.state.battery_generation != 0) or
                    (component != null and self.state.battery.get(component.?) != null))
                    self.state.battery
                else report: {
                    var saw_report = self.state.battery_generation != 0;

                    while (component == null or self.state.battery.get(component.?) == null) {
                        self.receiveObserved(observer) catch |failure| {
                            if (saw_report and component != null) {
                                self.session.channel.failure.set(
                                    "AirPods did not report the {s} battery before the timeout",
                                    .{component.?.name()},
                                );
                            }
                            return failure;
                        };
                        saw_report = saw_report or self.state.battery_generation != 0;
                        if (component == null and saw_report) break;
                    }
                    break :report self.state.battery;
                },
            } },
            .wear_status => result: {
                while (self.state.wear == null) try self.receiveObserved(observer);
                break :result .{ .wear_status = self.state.wear.? };
            },
            .switching => |request| try self.runSwitching(request, observer),
        };
    }

    pub fn run(self: *Controller, operation: command.Operation, deadline_ms: i64) Error!command.Result {
        return self.runWithObserver(operation, deadline_ms, .{});
    }
};
