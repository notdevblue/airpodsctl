const aacp = @import("aacp");
const battery = @import("battery");
const command = @import("command");
const noise_control = @import("noise_control");

pub const Error = aacp.Error;

pub const State = struct {
    listening_mode: ?noise_control.Mode = null,
    listening_mode_generation: u64 = 0,
    battery: battery.Report = .{},
    battery_generation: u64 = 0,
};

pub const Controller = struct {
    session: aacp.Session,
    state: State = .{},

    pub fn receiveOne(self: *Controller) Error!void {
        const packet = try self.session.receive();

        if (noise_control.parsePacket(packet) catch {
            self.session.channel.failure.set("AirPods returned an invalid listening-mode response", .{});
            return error.ProtocolFailure;
        }) |mode| {
            self.state.listening_mode = mode;
            self.state.listening_mode_generation +%= 1;
            return;
        }
        if (battery.parsePacket(packet) catch {
            self.session.channel.failure.set("AirPods returned an invalid battery response", .{});
            return error.ProtocolFailure;
        }) |report| {
            // A notification may contain only one earbud, so preserve the other cached reading.
            if (report.left) |reading| self.state.battery.left = reading;
            if (report.right) |reading| self.state.battery.right = reading;
            if (report.left != null or report.right != null) self.state.battery_generation +%= 1;
        }
    }

    pub fn run(
        self: *Controller,
        operation: command.Operation,
        deadline_ms: i64,
    ) Error!command.Result {
        self.session.channel.deadline_ms = deadline_ms;

        return switch (operation) {
            .noise_control => |request| result: {
                while (self.state.listening_mode == null) try self.receiveOne();
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
                        self.receiveOne() catch |failure| {
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
                        self.receiveOne() catch |failure| {
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
        };
    }
};
