const std = @import("std");
const aacp = @import("aacp");
const control_command = @import("control_command");

const listening_mode_identifier = 0x0d;

pub const Error = aacp.Error;

// Explicit values are the AACP wire codes inserted into and read from mode packets.
pub const Mode = enum(u8) {
    off = 1,
    noise_cancellation = 2,
    transparency = 3,
    adaptive = 4,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .off => "off",
            .noise_cancellation => "noise-cancellation",
            .transparency => "transparency",
            .adaptive => "adaptive",
        };
    }

    pub fn parse(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "anc")) return .noise_cancellation;
        if (std.mem.eql(u8, value, "off")) return .off;
        if (std.mem.eql(u8, value, "transparency")) return .transparency;
        if (std.mem.eql(u8, value, "adaptive")) return .adaptive;
        return null;
    }
};

pub const Action = enum {
    status,
    anc,
    off,
    transparency,
    adaptive,
    toggle,

    pub fn parse(value: []const u8) ?Action {
        if (std.mem.eql(u8, value, "status")) return .status;
        if (std.mem.eql(u8, value, "toggle")) return .toggle;
        return switch (Mode.parse(value) orelse return null) {
            .noise_cancellation => .anc,
            .off => .off,
            .transparency => .transparency,
            .adaptive => .adaptive,
        };
    }
};

pub fn parseCommand(state: control_command.State) error{InvalidModePacket}!?Mode {
    if (state.identifier != listening_mode_identifier) return null;
    if (!std.mem.allEqual(u8, state.values[1..], 0) or
        state.values[0] < @intFromEnum(Mode.off) or
        state.values[0] > @intFromEnum(Mode.adaptive))
    {
        return error.InvalidModePacket;
    }

    return @enumFromInt(state.values[0]);
}

// Retain the feature-level parser for packet fixtures while sharing the generic frame codec.
pub fn parsePacket(packet: []const u8) (error{ InvalidControlCommand, InvalidModePacket })!?Mode {
    return parseCommand((try control_command.parsePacket(packet)) orelse return null);
}

pub fn targetMode(action: Action, current_mode: Mode, custom_modes: []const Mode) Mode {
    const default_modes = [_]Mode{ .noise_cancellation, .off };

    // An empty list preserves the original cycle; an unlisted current mode selects its first entry.
    const modes = if (custom_modes.len == 0) &default_modes else custom_modes;

    return switch (action) {
        .anc => .noise_cancellation,
        .off => .off,
        .transparency => .transparency,
        .adaptive => .adaptive,
        .status => current_mode,
        .toggle => for (modes, 0..) |mode, index| {
            if (mode == current_mode) break modes[(index + 1) % modes.len];
        } else modes[0],
    };
}

pub fn setMode(session: *aacp.Session, mode: Mode) Error!void {
    const packet = control_command.encode(listening_mode_identifier, &.{@intFromEnum(mode)}) catch unreachable;
    try session.send(&packet);
}
