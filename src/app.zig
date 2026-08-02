const aacp = @import("aacp");
const bluez = @import("bluez");
const cli = @import("cli");
const controller = @import("controller");
const operations = @import("command");
const support = @import("support");
const transport = @import("transport");

const timeout_ms = 3000;

// AirPods need time to settle between the handshake and feature-negotiation frames.
const initialization_delay_ms = 150;

pub const Error = aacp.Error || bluez.Error;
pub const Result = operations.Result;

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

    var control = controller.Controller{
        .session = try aacp.Session.initialize(fd, deadline_ms, initialization_delay_ms, failure),
        .local_address = if (command.operation == .switching)
            try bluez.localAddress(fd, failure)
        else
            null,
    };
    return control.run(command.operation, deadline_ms);
}
