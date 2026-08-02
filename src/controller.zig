const aacp = @import("aacp");
const battery = @import("battery");
const command = @import("command");
const control_command = @import("control_command");
const ear_detection = @import("ear_detection");
const noise_control = @import("noise_control");

pub const Error = aacp.Error;

pub const State = struct {
    listening_mode: ?noise_control.Mode = null,
    listening_mode_generation: u64 = 0,
    battery: battery.Report = .{},
    battery_generation: u64 = 0,
    automatic_ear_detection: ?ear_detection.Setting = null,
    automatic_ear_detection_generation: u64 = 0,
    wear: ?ear_detection.WearReport = null,
    wear_generation: u64 = 0,
};

pub const Event = union(enum) {
    listening_mode: noise_control.Mode,
    battery: battery.Report,
    automatic_ear_detection: ear_detection.Setting,
    wear: ear_detection.WearReport,
};

fn ignoreEvent(_: ?*anyopaque, _: Event) void {}

pub const EventObserver = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Event) void = ignoreEvent,

    pub fn notify(self: EventObserver, event: ?Event) void {
        if (event) |value| self.callback(self.context, value);
    }
};

pub const Controller = struct {
    session: aacp.Session,
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
                return .{ .listening_mode = mode };
            }
            if (ear_detection.parseSetting(control_state) catch {
                self.session.channel.failure.set("AirPods returned an invalid Automatic Ear Detection response", .{});
                return error.ProtocolFailure;
            }) |setting| {
                self.state.automatic_ear_detection = setting;
                self.state.automatic_ear_detection_generation +%= 1;
                return .{ .automatic_ear_detection = setting };
            }
            return null;
        }
        if (ear_detection.parseWearPacket(packet) catch {
            self.session.channel.failure.set("AirPods returned an invalid wear-state response", .{});
            return error.ProtocolFailure;
        }) |report| {
            self.state.wear = report;
            self.state.wear_generation +%= 1;
            return .{ .wear = report };
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
                return .{ .battery = report };
            }
        }
        return null;
    }

    fn receiveObserved(self: *Controller, observer: EventObserver) Error!void {
        observer.notify(try self.receiveOne());
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
            .automatic_ear_detection => |action| result: {
                while (self.state.automatic_ear_detection == null) try self.receiveObserved(observer);
                const final_setting = ear_detection.targetSetting(action, self.state.automatic_ear_detection.?);
                if (action != .status) {
                    const previous_generation = self.state.automatic_ear_detection_generation;
                    try ear_detection.setSetting(&self.session, final_setting);

                    while (self.state.automatic_ear_detection_generation == previous_generation) {
                        self.receiveObserved(observer) catch |failure| {
                            self.session.channel.failure.set(
                                "AirPods did not acknowledge Automatic Ear Detection {s} before the timeout",
                                .{final_setting.name()},
                            );
                            return failure;
                        };
                    }
                    if (self.state.automatic_ear_detection.? != final_setting) {
                        self.session.channel.failure.set(
                            "AirPods did not acknowledge Automatic Ear Detection {s}; the last reported setting was {s}",
                            .{ final_setting.name(), self.state.automatic_ear_detection.?.name() },
                        );
                        return error.ProtocolFailure;
                    }
                }
                break :result .{ .automatic_ear_detection = final_setting };
            },
            .wear_status => result: {
                while (self.state.wear == null) try self.receiveObserved(observer);
                break :result .{ .wear_status = self.state.wear.? };
            },
        };
    }

    pub fn run(self: *Controller, operation: command.Operation, deadline_ms: i64) Error!command.Result {
        return self.runWithObserver(operation, deadline_ms, .{});
    }
};
