const std = @import("std");
const aacp = @import("aacp");
const battery = @import("battery");
const cli = @import("cli");
const control_command = @import("control_command");
const controller = @import("controller");
const ear_detection = @import("ear_detection");
const ipc = @import("ipc");
const noise_control = @import("noise_control");
const operations = @import("command");
const pipewire_route = @import("pipewire_route");
const support = @import("support");
const transport = @import("transport");
const wear_policy = @import("wear_policy");

const c = support.c;

// Mirror the observed frames so the emulator verifies exact protocol bytes and ordering.
const handshake_packet = [_]u8{
    0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
const feature_flags_packet = [_]u8{
    0x04, 0x00, 0x04, 0x00, 0x4d, 0x00, 0xff,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
const notification_request_packet = [_]u8{
    0x04, 0x00, 0x04, 0x00, 0x0f, 0x00, 0xff, 0xff, 0xff, 0xff,
};
const battery_report_packet = [_]u8{
    0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x03,
    0x02, 0x01, 100,  0x02, 0x01, 0x04, 0x01,
    99,   0x01, 0x01, 0x08, 0x01, 17,   0x02,
    0x01,
};

const ResponseBehavior = enum {
    normal,
    mismatch,
    truncated,
    unknown,
    timeout,
};

const NoiseExchange = struct {
    action: noise_control.Action,
    current_mode: noise_control.Mode,
    target_mode: noise_control.Mode,
    behavior: ResponseBehavior,
    toggle_modes: []const noise_control.Mode = &.{},
};

const NoiseEmulatorContext = struct {
    fd: c_int,
    exchange: *const NoiseExchange,
    status: u8 = 0,
};

const NoiseExchangeResult = struct {
    result: ?noise_control.Mode,
    failure: support.ErrorMessage,
};

const BatteryEmulatorContext = struct {
    fd: c_int,
    status: u8 = 0,
};

const BatteryExchangeResult = struct {
    report: ?battery.Report,
    failure: support.ErrorMessage,
};

const PersistentEmulatorContext = struct {
    fd: c_int,
    status: u8 = 0,
};

const EarExchange = struct {
    action: ear_detection.Action,
    current: ear_detection.Setting,
    target: ear_detection.Setting,
    mismatch: bool = false,
};

const EarEmulatorContext = struct {
    fd: c_int,
    exchange: *const EarExchange,
    status: u8 = 0,
};

const EarExchangeResult = struct {
    result: ?ear_detection.Setting,
    observed_wear_events: usize,
    failure: support.ErrorMessage,
};

const EarObserverContext = struct {
    wear_events: usize = 0,
};

fn receiveExpected(fd: c_int, expected: []const u8) bool {
    var packet: [128]u8 = undefined;
    const received = c.recv(fd, &packet, packet.len, 0);

    return received == expected.len and std.mem.eql(u8, packet[0..@intCast(received)], expected);
}

fn receiveInitialization(fd: c_int) bool {
    return receiveExpected(fd, &handshake_packet) and
        receiveExpected(fd, &feature_flags_packet) and
        receiveExpected(fd, &notification_request_packet);
}

fn sendMode(fd: c_int, mode_value: u8) bool {
    const packet = [_]u8{
        0x04,       0x00, 0x04, 0x00, 0x09, 0x00, 0x0d,
        mode_value, 0x00, 0x00, 0x00,
    };

    return c.send(fd, &packet, packet.len, 0) == packet.len;
}

fn sendInitialNoiseResponse(fd: c_int, exchange: *const NoiseExchange) bool {
    const unrelated_packet = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00 };
    const truncated_packet = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x09 };

    switch (exchange.behavior) {
        .timeout => {
            // Outlive the client's 50 ms deadline so its receive path must time out.
            var delay = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 100_000_000 };
            _ = c.nanosleep(&delay, null);
            return true;
        },
        .truncated => return c.send(fd, &truncated_packet, truncated_packet.len, 0) == truncated_packet.len,
        .unknown => return sendMode(fd, 9),
        else => {},
    }

    // Prepend unrelated AACP traffic to verify the feature filters notifications correctly.
    if (c.send(fd, &unrelated_packet, unrelated_packet.len, 0) != unrelated_packet.len) return false;
    return sendMode(fd, @intFromEnum(exchange.current_mode));
}

fn emulateNoiseExchange(fd: c_int, exchange: *const NoiseExchange) u8 {
    const command = [_]u8{
        0x04,                               0x00, 0x04, 0x00, 0x09, 0x00, 0x0d,
        @intFromEnum(exchange.target_mode), 0x00, 0x00, 0x00,
    };

    if (!receiveInitialization(fd) or !sendInitialNoiseResponse(fd, exchange)) return 1;
    if (exchange.behavior == .timeout or
        exchange.behavior == .truncated or
        exchange.behavior == .unknown or
        exchange.action == .status)
    {
        return 0;
    }
    if (!receiveExpected(fd, &command)) return 2;
    return if (sendMode(
        fd,
        @intFromEnum(if (exchange.behavior == .mismatch) exchange.current_mode else exchange.target_mode),
    )) 0 else 3;
}

fn runNoiseEmulator(context: *NoiseEmulatorContext) void {
    // Thread.join has no return value, so publish the emulator result through shared context.
    context.status = emulateNoiseExchange(context.fd, context.exchange);
    _ = c.close(context.fd);
}

fn runNoiseExchange(exchange: *const NoiseExchange) !NoiseExchangeResult {
    var sockets: [2]c_int = undefined;

    // SOCK_SEQPACKET preserves L2CAP-like packet boundaries without requiring Bluetooth hardware.
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, &sockets));

    var context = NoiseEmulatorContext{ .fd = sockets[1], .exchange = exchange };
    const emulator = try std.Thread.spawn(.{}, runNoiseEmulator, .{&context});
    var exchange_result = NoiseExchangeResult{ .result = null, .failure = .{} };
    const deadline_ms = transport.nowMs() + @as(i64, if (exchange.behavior == .timeout) 50 else 1000);
    var control = controller.Controller{ .session = aacp.Session.initialize(
        sockets[0],
        deadline_ms,
        0,
        &exchange_result.failure,
    ) catch |failure| {
        _ = c.close(sockets[0]);
        emulator.join();
        return failure;
    } };
    var operation = operations.NoiseControl{
        .action = exchange.action,
        .toggle_mode_count = exchange.toggle_modes.len,
    };
    @memcpy(operation.toggle_modes[0..exchange.toggle_modes.len], exchange.toggle_modes);
    if (control.run(
        .{ .noise_control = operation },
        deadline_ms,
    ) catch null) |result| exchange_result.result = result.mode;
    _ = c.close(sockets[0]);
    emulator.join();

    try std.testing.expectEqual(@as(u8, 0), context.status);
    return exchange_result;
}

fn emulateBatteryExchange(fd: c_int) u8 {
    if (!receiveInitialization(fd)) return 1;

    // A listening-mode event arriving first must not be mistaken for a battery response.
    if (!sendMode(fd, @intFromEnum(noise_control.Mode.adaptive))) return 2;
    return if (c.send(fd, &battery_report_packet, battery_report_packet.len, 0) == battery_report_packet.len) 0 else 3;
}

fn runBatteryEmulator(context: *BatteryEmulatorContext) void {
    context.status = emulateBatteryExchange(context.fd);
    _ = c.close(context.fd);
}

fn runBatteryExchange(component: ?battery.Component) !BatteryExchangeResult {
    var sockets: [2]c_int = undefined;

    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, &sockets));

    var context = BatteryEmulatorContext{ .fd = sockets[1] };
    const emulator = try std.Thread.spawn(.{}, runBatteryEmulator, .{&context});
    var exchange_result = BatteryExchangeResult{ .report = null, .failure = .{} };
    const deadline_ms = transport.nowMs() + 1000;
    var control = controller.Controller{ .session = aacp.Session.initialize(
        sockets[0],
        deadline_ms,
        0,
        &exchange_result.failure,
    ) catch |failure| {
        _ = c.close(sockets[0]);
        emulator.join();
        return failure;
    } };
    if (control.run(.{ .battery = component }, deadline_ms) catch null) |result| {
        exchange_result.report = result.battery.report;
    }
    _ = c.close(sockets[0]);
    emulator.join();

    try std.testing.expectEqual(@as(u8, 0), context.status);
    return exchange_result;
}

fn runPersistentEmulator(context: *PersistentEmulatorContext) void {
    const anc_command = [_]u8{
        0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0d,
        0x02, 0x00, 0x00, 0x00,
    };

    // Distinct statuses identify which expected stage failed after the single initialization.
    context.status = if (!receiveInitialization(context.fd))
        1
    else if (c.send(context.fd, &battery_report_packet, battery_report_packet.len, 0) != battery_report_packet.len)
        2
    else if (!sendMode(context.fd, @intFromEnum(noise_control.Mode.off)))
        3
    else if (!receiveExpected(context.fd, &anc_command))
        4
    else if (!sendMode(context.fd, @intFromEnum(noise_control.Mode.noise_cancellation)))
        5
    else
        0;
    _ = c.close(context.fd);
}

fn sendSetting(fd: c_int, setting: ear_detection.Setting) bool {
    const packet = [_]u8{
        0x04,                  0x00, 0x04, 0x00, 0x09, 0x00, 0x0a,
        @intFromEnum(setting), 0x00, 0x00, 0x00,
    };
    return c.send(fd, &packet, packet.len, 0) == packet.len;
}

fn emulateEarExchange(fd: c_int, exchange: *const EarExchange) u8 {
    const command_packet = [_]u8{
        0x04,                          0x00, 0x04, 0x00, 0x09, 0x00, 0x0a,
        @intFromEnum(exchange.target), 0x00, 0x00, 0x00,
    };
    const wear_packet = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x06, 0x00, 0x00, 0x01 };

    if (!receiveInitialization(fd) or !sendSetting(fd, exchange.current)) return 1;
    if (exchange.action == .status) return 0;
    if (!receiveExpected(fd, &command_packet)) return 2;
    if (c.send(fd, &wear_packet, wear_packet.len, 0) != wear_packet.len) return 3;
    return if (sendSetting(fd, if (exchange.mismatch) exchange.current else exchange.target)) 0 else 4;
}

fn runEarEmulator(context: *EarEmulatorContext) void {
    context.status = emulateEarExchange(context.fd, context.exchange);
    _ = c.close(context.fd);
}

fn observeEarEvent(context: ?*anyopaque, event: controller.Event) void {
    const observer: *EarObserverContext = @ptrCast(@alignCast(context.?));
    if (event == .wear) observer.wear_events += 1;
}

fn runEarExchange(exchange: *const EarExchange) !EarExchangeResult {
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, &sockets));

    var context = EarEmulatorContext{ .fd = sockets[1], .exchange = exchange };
    const emulator = try std.Thread.spawn(.{}, runEarEmulator, .{&context});
    var exchange_result = EarExchangeResult{
        .result = null,
        .observed_wear_events = 0,
        .failure = .{},
    };
    const deadline_ms = transport.nowMs() + 1000;
    var observer = EarObserverContext{};
    var control = controller.Controller{ .session = aacp.Session.initialize(
        sockets[0],
        deadline_ms,
        0,
        &exchange_result.failure,
    ) catch |failure| {
        _ = c.close(sockets[0]);
        emulator.join();
        return failure;
    } };
    if (control.runWithObserver(
        .{ .automatic_ear_detection = exchange.action },
        deadline_ms,
        .{ .context = &observer, .callback = observeEarEvent },
    ) catch null) |result| exchange_result.result = result.automatic_ear_detection;
    exchange_result.observed_wear_events = observer.wear_events;
    _ = c.close(sockets[0]);
    emulator.join();

    try std.testing.expectEqual(@as(u8, 0), context.status);
    return exchange_result;
}

test "noise-control names and command parsing" {
    try std.testing.expectEqualStrings("off", noise_control.Mode.off.name());
    try std.testing.expectEqualStrings("noise-cancellation", noise_control.Mode.noise_cancellation.name());
    try std.testing.expectEqualStrings("transparency", noise_control.Mode.transparency.name());
    try std.testing.expectEqualStrings("adaptive", noise_control.Mode.adaptive.name());

    // Standalone commands and custom toggle modes intentionally share spellings.
    try std.testing.expectEqual(noise_control.Action.status, noise_control.Action.parse("status").?);
    try std.testing.expectEqual(noise_control.Action.anc, noise_control.Action.parse("anc").?);
    try std.testing.expectEqual(noise_control.Action.off, noise_control.Action.parse("off").?);
    try std.testing.expectEqual(noise_control.Action.transparency, noise_control.Action.parse("transparency").?);
    try std.testing.expectEqual(noise_control.Action.adaptive, noise_control.Action.parse("adaptive").?);
    try std.testing.expectEqual(noise_control.Action.toggle, noise_control.Action.parse("toggle").?);
    try std.testing.expect(noise_control.Action.parse("invalid") == null);
    try std.testing.expectEqual(noise_control.Mode.noise_cancellation, noise_control.Mode.parse("anc").?);
    try std.testing.expectEqual(noise_control.Mode.off, noise_control.Mode.parse("off").?);
    try std.testing.expectEqual(noise_control.Mode.transparency, noise_control.Mode.parse("transparency").?);
    try std.testing.expectEqual(noise_control.Mode.adaptive, noise_control.Mode.parse("adaptive").?);
    try std.testing.expect(noise_control.Mode.parse("invalid") == null);
}

test "listening-mode packet parsing" {
    const unrelated = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00 };
    const truncated = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x09 };
    var listening_mode = [_]u8{
        0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0d, 0x01, 0x00, 0x00, 0x00,
    };

    try std.testing.expect(try noise_control.parsePacket(&unrelated) == null);
    try std.testing.expectError(error.InvalidControlCommand, noise_control.parsePacket(&truncated));
    for (1..5) |value| {
        listening_mode[7] = @intCast(value);
        try std.testing.expectEqual(
            @as(noise_control.Mode, @enumFromInt(value)),
            (try noise_control.parsePacket(&listening_mode)).?,
        );
    }
    listening_mode[7] = 9;
    try std.testing.expectError(error.InvalidModePacket, noise_control.parsePacket(&listening_mode));
}

test "successful noise-control exchanges" {
    const custom_modes = [_]noise_control.Mode{ .off, .transparency, .adaptive };
    const test_cases = [_]NoiseExchange{
        .{ .action = .status, .current_mode = .adaptive, .target_mode = .adaptive, .behavior = .normal },
        .{ .action = .anc, .current_mode = .off, .target_mode = .noise_cancellation, .behavior = .normal },
        .{ .action = .off, .current_mode = .noise_cancellation, .target_mode = .off, .behavior = .normal },
        .{ .action = .transparency, .current_mode = .off, .target_mode = .transparency, .behavior = .normal },
        .{ .action = .adaptive, .current_mode = .transparency, .target_mode = .adaptive, .behavior = .normal },
        .{ .action = .toggle, .current_mode = .noise_cancellation, .target_mode = .off, .behavior = .normal },
        .{ .action = .toggle, .current_mode = .transparency, .target_mode = .noise_cancellation, .behavior = .normal },
        .{ .action = .toggle, .current_mode = .off, .target_mode = .transparency, .behavior = .normal, .toggle_modes = &custom_modes },
        .{ .action = .toggle, .current_mode = .transparency, .target_mode = .adaptive, .behavior = .normal, .toggle_modes = &custom_modes },
        .{ .action = .toggle, .current_mode = .adaptive, .target_mode = .off, .behavior = .normal, .toggle_modes = &custom_modes },
        .{ .action = .toggle, .current_mode = .noise_cancellation, .target_mode = .off, .behavior = .normal, .toggle_modes = &custom_modes },
        .{ .action = .toggle, .current_mode = .adaptive, .target_mode = .adaptive, .behavior = .normal, .toggle_modes = &.{.adaptive} },
    };

    for (&test_cases) |*exchange| {
        const exchange_result = try runNoiseExchange(exchange);
        try std.testing.expect(exchange_result.result != null);
        try std.testing.expectEqual(exchange.target_mode, exchange_result.result.?);
    }
}

test "invalid noise-control responses fail with a message" {
    const test_cases = [_]NoiseExchange{
        .{ .action = .off, .current_mode = .noise_cancellation, .target_mode = .off, .behavior = .mismatch },
        .{ .action = .status, .current_mode = .off, .target_mode = .off, .behavior = .truncated },
        .{ .action = .status, .current_mode = .off, .target_mode = .off, .behavior = .unknown },
        .{ .action = .status, .current_mode = .off, .target_mode = .off, .behavior = .timeout },
    };

    for (&test_cases) |*exchange| {
        const exchange_result = try runNoiseExchange(exchange);
        try std.testing.expect(exchange_result.result == null);
        try std.testing.expect(exchange_result.failure.text().len != 0);
    }
}

test "battery component parsing" {
    try std.testing.expectEqual(battery.Component.left, battery.Component.parse("left").?);
    try std.testing.expectEqual(battery.Component.right, battery.Component.parse("right").?);
    try std.testing.expect(battery.Component.parse("case") == null);
    try std.testing.expect(battery.Component.parse("invalid") == null);
    try std.testing.expectEqualStrings("left", battery.Component.left.name());
}

test "battery command parsing" {
    const aggregate = cli.parseInvocation(&.{ "airpodsctl", "battery" });
    const selected = cli.parseInvocation(&.{ "airpodsctl", "battery", "right" });

    try std.testing.expect(aggregate == .execute);
    try std.testing.expect(aggregate.execute.operation == .battery);
    try std.testing.expect(aggregate.execute.operation.battery == null);
    try std.testing.expect(selected == .execute);
    try std.testing.expectEqual(battery.Component.right, selected.execute.operation.battery.?);
    try std.testing.expect(cli.parseInvocation(&.{ "airpodsctl", "battery", "case" }) == .usage);
}

test "session command parsing" {
    const serve = cli.parseInvocation(&.{ "airpodsctl", "--device", "18:3F:70:6F:A1:06", "serve" });
    const required = cli.parseInvocation(&.{ "airpodsctl", "battery", "left", "--session" });
    const direct = cli.parseInvocation(&.{ "airpodsctl", "--direct", "status" });

    try std.testing.expect(serve == .serve);
    try std.testing.expectEqualStrings("18:3F:70:6F:A1:06", serve.serve.requested_address.?);
    try std.testing.expectEqual(cli.Backend.session, required.execute.backend);
    try std.testing.expectEqual(cli.Backend.direct, direct.execute.backend);
    try std.testing.expect(cli.parseInvocation(&.{ "airpodsctl", "--session", "--direct", "status" }) == .usage);
    try std.testing.expect(cli.parseInvocation(&.{ "airpodsctl", "--session", "serve" }) == .usage);
}

test "IPC request and response encoding" {
    var packet: [512]u8 = undefined;
    var noise_request = operations.NoiseControl{ .action = .toggle, .toggle_mode_count = 2 };
    noise_request.toggle_modes[0] = .off;
    noise_request.toggle_modes[1] = .adaptive;
    const decoded_request = try ipc.decodeRequest(try ipc.encodeRequest(&packet, .{
        .requested_address = "18:3F:70:6F:A1:06",
        .backend = .session,
        .operation = .{ .noise_control = noise_request },
    }));

    try std.testing.expectEqualStrings("18:3F:70:6F:A1:06", decoded_request.requested_address.?);
    try std.testing.expectEqual(noise_control.Action.toggle, decoded_request.operation.noise_control.action);
    try std.testing.expectEqual(@as(usize, 2), decoded_request.operation.noise_control.toggle_mode_count);
    try std.testing.expectEqual(noise_control.Mode.adaptive, decoded_request.operation.noise_control.toggle_modes[1]);

    var failure = support.ErrorMessage{};
    _ = ipc.encodeResult(&packet, .{ .battery = .{
        .component = .right,
        .report = .{ .right = .{ .level = 38, .state = .discharging } },
    } });

    // A previous v1 service may populate the retired case slot; new clients must ignore it.
    @memcpy(packet[13..16], &[_]u8{ 1, 17, 2 });
    const decoded_result = try ipc.decodeResult(packet[0..16], &failure);
    try std.testing.expectEqual(@as(u8, 38), decoded_result.battery.report.right.?.level);
    try std.testing.expectEqual(battery.State.discharging, decoded_result.battery.report.right.?.state);

    try std.testing.expectError(
        error.RemoteFailure,
        ipc.decodeResult(ipc.encodeFailure(&packet, "AirPods are unavailable"), &failure),
    );
    try std.testing.expectEqualStrings("AirPods are unavailable", failure.text());
    try std.testing.expectError(error.InvalidRequest, ipc.encodeRequest(&packet, .{
        .requested_address = "invalid",
        .backend = .session,
        .operation = .{ .battery = .left },
    }));
    try std.testing.expectError(error.InvalidRequest, ipc.decodeRequest("invalid"));
}

test "IPC packet transport preserves and bounds messages" {
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, &sockets));
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);

    var failure = support.ErrorMessage{};
    var received: [32]u8 = undefined;
    const deadline_ms = transport.nowMs() + 1000;
    try ipc.sendPacket(sockets[0], "request", deadline_ms, &failure);
    try std.testing.expectEqualStrings(
        "request",
        try ipc.receivePacket(sockets[1], &received, deadline_ms, &failure),
    );

    const oversized = [_]u8{0xaa} ** 64;
    try ipc.sendPacket(sockets[0], &oversized, deadline_ms, &failure);
    try std.testing.expectError(
        error.IpcFailure,
        ipc.receivePacket(sockets[1], &received, deadline_ms, &failure),
    );
    try std.testing.expectEqualStrings("session socket message was too large", failure.text());
}

test "earbud battery packet parsing" {
    const unrelated = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0d, 0x02 };
    const case_only = [_]u8{
        0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x01,
        0x08, 0x01, 17,   0x02, 0x01,
    };

    try std.testing.expect(try battery.parsePacket(&unrelated) == null);
    const report = (try battery.parsePacket(&battery_report_packet)).?;
    try std.testing.expectEqual(@as(u8, 99), report.left.?.level);
    try std.testing.expectEqual(battery.State.charging, report.left.?.state);
    try std.testing.expectEqual(@as(u8, 100), report.right.?.level);
    try std.testing.expectEqual(battery.State.discharging, report.right.?.state);
    const ignored_case = (try battery.parsePacket(&case_only)).?;
    try std.testing.expect(ignored_case.left == null);
    try std.testing.expect(ignored_case.right == null);
}

test "malformed battery packets are rejected" {
    const truncated = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x01, 0x02 };
    const invalid_level = [_]u8{
        0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x01,
        0x02, 0x01, 101,  0x02, 0x01,
    };
    const duplicate = [_]u8{
        0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x02,
        0x04, 0x01, 90,   0x02, 0x01, 0x04, 0x01,
        89,   0x02, 0x01,
    };

    try std.testing.expectError(error.InvalidBatteryPacket, battery.parsePacket(&truncated));
    try std.testing.expectError(error.InvalidBatteryPacket, battery.parsePacket(&invalid_level));
    try std.testing.expectError(error.InvalidBatteryPacket, battery.parsePacket(&duplicate));
}

test "battery exchange filters other feature notifications" {
    const exchange_result = try runBatteryExchange(.left);

    try std.testing.expect(exchange_result.report != null);
    try std.testing.expectEqual(@as(u8, 99), exchange_result.report.?.left.?.level);
    try std.testing.expectEqual(@as(usize, 0), exchange_result.failure.text().len);
}

test "one initialized controller serves sequential cached operations" {
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, &sockets));

    var context = PersistentEmulatorContext{ .fd = sockets[1] };
    const emulator = try std.Thread.spawn(.{}, runPersistentEmulator, .{&context});
    var failure = support.ErrorMessage{};
    const deadline_ms = transport.nowMs() + 1000;
    var control = controller.Controller{ .session = try aacp.Session.initialize(
        sockets[0],
        deadline_ms,
        0,
        &failure,
    ) };

    try std.testing.expectEqual(
        @as(u8, 99),
        (try control.run(.{ .battery = .left }, deadline_ms)).battery.report.left.?.level,
    );
    try std.testing.expectEqual(
        noise_control.Mode.off,
        (try control.run(.{ .noise_control = .{ .action = .status } }, deadline_ms)).mode,
    );
    try std.testing.expectEqual(
        noise_control.Mode.noise_cancellation,
        (try control.run(.{ .noise_control = .{ .action = .anc } }, deadline_ms)).mode,
    );
    try std.testing.expectEqual(
        @as(u8, 100),
        (try control.run(.{ .battery = .right }, deadline_ms)).battery.report.right.?.level,
    );

    _ = c.close(sockets[0]);
    emulator.join();
    try std.testing.expectEqual(@as(u8, 0), context.status);
}

test "generic control-command framing is exact and bounded" {
    const expected = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0a, 0x01, 0x00, 0x00, 0x00 };
    const encoded = try control_command.encode(0x0a, &.{0x01});
    const disabled = try control_command.encode(0x0a, &.{0x02});
    const parsed = (try control_command.parsePacket(&encoded)).?;

    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0a, 0x02, 0x00, 0x00, 0x00 },
        &disabled,
    );
    try std.testing.expectEqual(@as(u8, 0x0a), parsed.identifier);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x00, 0x00 }, &parsed.values);
    try std.testing.expectError(error.TooMuchData, control_command.encode(1, &.{ 1, 2, 3, 4, 5 }));

    for (0..4) |length| try std.testing.expect((try control_command.parsePacket(expected[0..length])) == null);
    for (4..expected.len) |length| {
        try std.testing.expectError(error.InvalidControlCommand, control_command.parsePacket(expected[0..length]));
    }
    const oversized = expected ++ [_]u8{0};
    try std.testing.expectError(error.InvalidControlCommand, control_command.parsePacket(&oversized));
    var invalid_reserved = expected;
    invalid_reserved[5] = 1;
    try std.testing.expectError(error.InvalidControlCommand, control_command.parsePacket(&invalid_reserved));
    var unknown_identifier = expected;
    unknown_identifier[6] = 0xfe;
    try std.testing.expectEqual(@as(u8, 0xfe), (try control_command.parsePacket(&unknown_identifier)).?.identifier);
}

test "automatic ear detection setting and wear packets are typed" {
    var setting_packet = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0a, 0x01, 0x00, 0x00, 0x00 };
    const on_state = (try control_command.parsePacket(&setting_packet)).?;

    try std.testing.expectEqual(ear_detection.Setting.on, (try ear_detection.parseSetting(on_state)).?);
    setting_packet[7] = 2;
    try std.testing.expectEqual(
        ear_detection.Setting.off,
        (try ear_detection.parseSetting((try control_command.parsePacket(&setting_packet)).?)).?,
    );
    setting_packet[8] = 1;
    try std.testing.expectError(
        error.InvalidSettingPacket,
        ear_detection.parseSetting((try control_command.parsePacket(&setting_packet)).?),
    );
    setting_packet[8] = 0;
    setting_packet[7] = 0xff;
    try std.testing.expectError(
        error.InvalidSettingPacket,
        ear_detection.parseSetting((try control_command.parsePacket(&setting_packet)).?),
    );

    const wear_packet = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x06, 0x00, 0x00, 0x02 };
    const wear = (try ear_detection.parseWearPacket(&wear_packet)).?;
    try std.testing.expectEqual(ear_detection.WearState.in_ear, wear.primary);
    try std.testing.expectEqual(ear_detection.WearState.in_case, wear.secondary);
    try std.testing.expectEqual(@as(?u8, 1), wear.inEarCount());

    var unknown_wear = wear_packet;
    unknown_wear[7] = 0xfe;
    const unknown = (try ear_detection.parseWearPacket(&unknown_wear)).?;
    try std.testing.expectEqualStrings("unknown", unknown.secondary.name());
    try std.testing.expectEqual(@as(?u8, null), unknown.inEarCount());
    for (0..3) |value| {
        var primary = wear_packet;
        primary[6] = @intCast(value);
        try std.testing.expectEqual(@as(ear_detection.WearState, @enumFromInt(value)), (try ear_detection.parseWearPacket(&primary)).?.primary);
        var secondary = wear_packet;
        secondary[7] = @intCast(value);
        try std.testing.expectEqual(@as(ear_detection.WearState, @enumFromInt(value)), (try ear_detection.parseWearPacket(&secondary)).?.secondary);
    }
    for (0..4) |length| try std.testing.expect((try ear_detection.parseWearPacket(wear_packet[0..length])) == null);
    for (4..wear_packet.len) |length| {
        try std.testing.expectError(error.InvalidWearPacket, ear_detection.parseWearPacket(wear_packet[0..length]));
    }
    const oversized_wear = wear_packet ++ [_]u8{0};
    try std.testing.expectError(error.InvalidWearPacket, ear_detection.parseWearPacket(&oversized_wear));
    var reserved_wear = wear_packet;
    reserved_wear[5] = 1;
    try std.testing.expectError(error.InvalidWearPacket, ear_detection.parseWearPacket(&reserved_wear));
    var unrelated_wear = wear_packet;
    unrelated_wear[0] = 0xff;
    try std.testing.expect((try ear_detection.parseWearPacket(&unrelated_wear)) == null);
    unrelated_wear = wear_packet;
    unrelated_wear[4] = 0x04;
    try std.testing.expect((try ear_detection.parseWearPacket(&unrelated_wear)) == null);
}

test "automatic ear detection exchanges require a newer matching acknowledgement" {
    const exchanges = [_]EarExchange{
        .{ .action = .status, .current = .on, .target = .on },
        .{ .action = .on, .current = .off, .target = .on },
        .{ .action = .on, .current = .on, .target = .on },
        .{ .action = .off, .current = .on, .target = .off },
    };

    for (&exchanges) |*exchange| {
        const result = try runEarExchange(exchange);
        try std.testing.expectEqual(exchange.target, result.result.?);
        try std.testing.expectEqual(@as(usize, if (exchange.action == .status) 0 else 1), result.observed_wear_events);
        try std.testing.expectEqual(@as(usize, 0), result.failure.text().len);
    }

    const mismatch = try runEarExchange(&.{
        .action = .on,
        .current = .off,
        .target = .on,
        .mismatch = true,
    });
    try std.testing.expect(mismatch.result == null);
    try std.testing.expect(std.mem.indexOf(u8, mismatch.failure.text(), "did not acknowledge") != null);
}

test "automatic ear detection CLI and IPC variants are explicit" {
    const status = cli.parseInvocation(&.{ "airpodsctl", "automatic-ear-detection", "status" });
    const wear = cli.parseInvocation(&.{ "airpodsctl", "--session", "wear-status" });
    const serve = cli.parseInvocation(&.{ "airpodsctl", "serve", "--pause-on-removal=both" });
    var packet: [512]u8 = undefined;

    try std.testing.expect(status == .execute);
    try std.testing.expectEqual(ear_detection.Action.status, status.execute.operation.automatic_ear_detection);
    try std.testing.expect(wear.execute.operation == .wear_status);
    try std.testing.expectEqual(cli.Backend.session, wear.execute.backend);
    try std.testing.expectEqual(operations.PauseOnRemoval.both, serve.serve.pause_on_removal);
    try std.testing.expect(cli.parseInvocation(&.{ "airpodsctl", "status", "--pause-on-removal=one" }) == .usage);
    try std.testing.expect(cli.parseInvocation(&.{ "airpodsctl", "automatic-ear-detection", "toggle" }) == .usage);

    const encoded = try ipc.encodeRequest(&packet, status.execute);
    try std.testing.expectEqualStrings("APC2", encoded[0..4]);
    const decoded = try ipc.decodeRequest(encoded);
    try std.testing.expectEqual(ipc.ProtocolVersion.v2, decoded.version);
    try std.testing.expectEqual(ear_detection.Action.status, decoded.operation.automatic_ear_detection);

    var failure = support.ErrorMessage{};
    const decoded_setting = try ipc.decodeResult(
        ipc.encodeResult(&packet, .{ .automatic_ear_detection = .off }),
        &failure,
    );
    try std.testing.expectEqual(ear_detection.Setting.off, decoded_setting.automatic_ear_detection);
    const decoded_wear = try ipc.decodeResult(ipc.encodeResult(&packet, .{ .wear_status = .{
        .primary = .in_ear,
        .secondary = .out_of_ear,
    } }), &failure);
    try std.testing.expectEqual(ear_detection.WearState.out_of_ear, decoded_wear.wear_status.secondary);

    _ = ipc.encodeFailureForVersion(&packet, "unsupported operation", .v1);
    try std.testing.expectError(
        error.IncompatibleVersion,
        ipc.decodeResultForVersion(packet[0 .. 7 + "unsupported operation".len], .v2, &failure),
    );
    try std.testing.expect(std.mem.indexOf(u8, failure.text(), "restart") != null);
}

test "wear policy initializes, transitions, and resets conservatively" {
    const both_in = ear_detection.WearReport{ .primary = .in_ear, .secondary = .in_ear };
    const one_in = ear_detection.WearReport{ .primary = .in_ear, .secondary = .out_of_ear };
    const none_in = ear_detection.WearReport{ .primary = .out_of_ear, .secondary = .in_case };
    const unknown = ear_detection.WearReport{
        .primary = .in_ear,
        .secondary = @enumFromInt(0xfe),
    };
    var one = wear_policy.Policy{ .mode = .one };

    one.updateSetting(.on, null);
    try std.testing.expectEqual(wear_policy.Decision.none, one.updateWear(both_in, false));
    try std.testing.expectEqual(wear_policy.Decision.none, one.updateWear(.{
        .primary = both_in.secondary,
        .secondary = both_in.primary,
    }, false));
    try std.testing.expectEqual(wear_policy.Decision.pause_media, one.updateWear(one_in, false));
    try std.testing.expectEqual(wear_policy.Decision.none, one.updateWear(one_in, true));
    try std.testing.expectEqual(wear_policy.Decision.resume_media, one.updateWear(both_in, true));
    try std.testing.expectEqual(wear_policy.Decision.none, one.updateWear(unknown, true));
    try std.testing.expectEqual(wear_policy.Decision.none, one.updateWear(one_in, true));
    one.updateSetting(.off, one_in);
    try std.testing.expectEqual(wear_policy.Decision.none, one.updateWear(both_in, true));

    var both = wear_policy.Policy{ .mode = .both };
    both.updateSetting(.on, both_in);
    try std.testing.expectEqual(wear_policy.Decision.none, both.updateWear(one_in, false));
    try std.testing.expectEqual(wear_policy.Decision.pause_media, both.updateWear(none_in, false));
    try std.testing.expectEqual(wear_policy.Decision.resume_media, both.updateWear(one_in, true));
    both.reset();
    try std.testing.expectEqual(wear_policy.Decision.none, both.updateWear(none_in, true));

    var off = wear_policy.Policy{ .mode = .off };
    off.updateSetting(.on, both_in);
    try std.testing.expectEqual(wear_policy.Decision.none, off.updateWear(none_in, true));
}

test "PipeWire route classification requires the exact selected A2DP sink" {
    try std.testing.expectEqual(
        pipewire_route.RouteState.selected,
        pipewire_route.classify(
            "bluez_output.airpods",
            "bluez_output.airpods",
            "18:3F:70:6F:A1:06",
            true,
            "18:3f:70:6f:a1:06",
        ),
    );
    try std.testing.expectEqual(
        pipewire_route.RouteState.other,
        pipewire_route.classify(
            "bluez_output.other",
            "bluez_output.other",
            "AA:BB:CC:DD:EE:FF",
            true,
            "18:3F:70:6F:A1:06",
        ),
    );
    try std.testing.expectEqual(
        pipewire_route.RouteState.other,
        pipewire_route.classify(
            "bluez_output.airpods",
            "bluez_output.airpods",
            "18:3F:70:6F:A1:06",
            false,
            "18:3F:70:6F:A1:06",
        ),
    );
    try std.testing.expectEqual(
        pipewire_route.RouteState.unknown,
        pipewire_route.classify(
            "virtual_filter",
            "bluez_output.airpods",
            "18:3F:70:6F:A1:06",
            true,
            "18:3F:70:6F:A1:06",
        ),
    );
}
