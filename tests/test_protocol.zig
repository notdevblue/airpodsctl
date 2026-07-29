const std = @import("std");
const aacp = @import("aacp");
const battery = @import("battery");
const cli = @import("cli");
const noise_control = @import("noise_control");
const support = @import("support");
const transport = @import("transport");

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
    result: ?noise_control.Result,
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
    var session = aacp.Session.initialize(
        sockets[0],
        transport.nowMs() + @as(i64, if (exchange.behavior == .timeout) 50 else 1000),
        0,
        &exchange_result.failure,
    ) catch |failure| {
        _ = c.close(sockets[0]);
        emulator.join();
        return failure;
    };
    exchange_result.result = noise_control.run(
        &session,
        exchange.action,
        exchange.toggle_modes,
    ) catch null;
    _ = c.close(sockets[0]);
    emulator.join();

    try std.testing.expectEqual(@as(u8, 0), context.status);
    return exchange_result;
}

fn emulateBatteryExchange(fd: c_int) u8 {
    const report = [_]u8{
        0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x03,
        0x02, 0x01, 100,  0x02, 0x01, 0x04, 0x01,
        99,   0x01, 0x01, 0x08, 0x01, 17,   0x02,
        0x01,
    };

    if (!receiveInitialization(fd)) return 1;

    // A listening-mode event arriving first must not be mistaken for a battery response.
    if (!sendMode(fd, @intFromEnum(noise_control.Mode.adaptive))) return 2;
    return if (c.send(fd, &report, report.len, 0) == report.len) 0 else 3;
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
    var session = aacp.Session.initialize(
        sockets[0],
        transport.nowMs() + 1000,
        0,
        &exchange_result.failure,
    ) catch |failure| {
        _ = c.close(sockets[0]);
        emulator.join();
        return failure;
    };
    exchange_result.report = battery.get(&session, component) catch null;
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
    try std.testing.expectError(error.InvalidModePacket, noise_control.parsePacket(&truncated));
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
        try std.testing.expectEqual(exchange.current_mode, exchange_result.result.?.initial_mode);
        try std.testing.expectEqual(exchange.target_mode, exchange_result.result.?.final_mode);
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
    try std.testing.expectEqual(battery.Component.case, battery.Component.parse("case").?);
    try std.testing.expect(battery.Component.parse("invalid") == null);
    try std.testing.expectEqualStrings("left", battery.Component.left.name());
}

test "battery command parsing" {
    const aggregate = cli.parseInvocation(&.{ "airpodsctl", "battery" });
    const selected = cli.parseInvocation(&.{ "airpodsctl", "battery", "case" });

    try std.testing.expect(aggregate == .execute);
    try std.testing.expect(aggregate.execute.operation == .battery);
    try std.testing.expect(aggregate.execute.operation.battery == null);
    try std.testing.expect(selected == .execute);
    try std.testing.expectEqual(battery.Component.case, selected.execute.operation.battery.?);
}

test "battery packet parsing" {
    const unrelated = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0d, 0x02 };
    const packet = [_]u8{
        0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x03,
        0x02, 0x01, 100,  0x02, 0x01, 0x04, 0x01,
        99,   0x01, 0x01, 0x08, 0x01, 17,   0x02,
        0x01,
    };

    try std.testing.expect(try battery.parsePacket(&unrelated) == null);
    const report = (try battery.parsePacket(&packet)).?;
    try std.testing.expectEqual(@as(u8, 99), report.left.?.level);
    try std.testing.expectEqual(battery.State.charging, report.left.?.state);
    try std.testing.expectEqual(@as(u8, 100), report.right.?.level);
    try std.testing.expectEqual(battery.State.discharging, report.right.?.state);
    try std.testing.expectEqual(@as(u8, 17), report.case.?.level);
    try std.testing.expectEqual(battery.State.discharging, report.case.?.state);
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
