const std = @import("std");
const aacp = @import("aacp");

const listening_mode_prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0d };

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

// Distinguish unrelated AACP traffic from malformed listening-mode notifications.
pub fn parsePacket(packet: []const u8) error{InvalidModePacket}!?Mode {
    if (packet.len < 4 or !std.mem.eql(u8, packet[0..4], listening_mode_prefix[0..4])) return null;
    if (packet.len < 5) return error.InvalidModePacket;
    if (packet[4] != listening_mode_prefix[4]) return null;
    if (packet.len < listening_mode_prefix.len) return error.InvalidModePacket;
    if (packet[5] != listening_mode_prefix[5] or packet[6] != listening_mode_prefix[6]) return null;
    if (packet.len < listening_mode_prefix.len + 1) return error.InvalidModePacket;
    if (packet[7] < @intFromEnum(Mode.off) or packet[7] > @intFromEnum(Mode.adaptive)) {
        return error.InvalidModePacket;
    }
    return @enumFromInt(packet[7]);
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
    const packet = [_]u8{
        0x04,               0x00, 0x04, 0x00, 0x09, 0x00, 0x0d,
        @intFromEnum(mode), 0x00, 0x00, 0x00,
    };
    try session.send(&packet);
}
