const aacp = @import("aacp");
const battery = @import("battery");
const bluez = @import("bluez");
const cli = @import("cli");
const noise_control = @import("noise_control");
const support = @import("support");
const transport = @import("transport");

const timeout_ms = 3000;

// AirPods need time to settle between the handshake and feature-negotiation frames.
const initialization_delay_ms = 150;

pub const Error = aacp.Error || bluez.Error;

pub const BatteryResult = struct {
    component: ?battery.Component,
    report: battery.Report,
};

pub const Result = union(enum) {
    mode: noise_control.Mode,
    battery: BatteryResult,
};

// Discover, connect, initialize AACP, and delegate exactly one feature operation.
pub fn run(command: cli.Command, failure: *support.ErrorMessage) Error!Result {
    // Start the shared budget before discovery so later phases inherit time already spent.
    const deadline_ms = transport.nowMs() + timeout_ms;
    const fd = try bluez.openControlChannel(
        try bluez.discover(command.requested_address, failure),
        deadline_ms,
        failure,
    );
    defer bluez.close(fd);

    var session = try aacp.Session.initialize(fd, deadline_ms, initialization_delay_ms, failure);
    return switch (command.operation) {
        .noise_control => |operation| .{ .mode = (try noise_control.run(
            &session,
            operation.action,
            operation.toggle_modes[0..operation.toggle_mode_count],
        )).final_mode },
        .battery => |component| .{ .battery = .{
            .component = component,
            .report = try battery.get(&session, component),
        } },
    };
}
