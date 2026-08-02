const std = @import("std");
const aacp = @import("aacp");
const control_command = @import("control_command");

const setting_identifier = 0x0a;
const frame_prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00 };
const wear_opcode = 0x06;

pub const Error = aacp.Error;

pub const Setting = enum(u8) {
    on = 1,
    off = 2,

    pub fn name(self: Setting) []const u8 {
        return switch (self) {
            .on => "on",
            .off => "off",
        };
    }
};

pub const Action = enum {
    status,
    on,
    off,

    pub fn parse(value: []const u8) ?Action {
        if (std.mem.eql(u8, value, "status")) return .status;
        if (std.mem.eql(u8, value, "on")) return .on;
        if (std.mem.eql(u8, value, "off")) return .off;
        return null;
    }
};

pub const WearState = enum(u8) {
    in_ear = 0,
    out_of_ear = 1,
    in_case = 2,
    _,

    pub fn name(self: WearState) []const u8 {
        return switch (self) {
            .in_ear => "in-ear",
            .out_of_ear => "out-of-ear",
            .in_case => "in-case",
            else => "unknown",
        };
    }

    pub fn isKnown(self: WearState) bool {
        return switch (self) {
            .in_ear, .out_of_ear, .in_case => true,
            else => false,
        };
    }
};

pub const WearReport = struct {
    primary: WearState,
    secondary: WearState,

    pub fn inEarCount(self: WearReport) ?u8 {
        if (!self.primary.isKnown() or !self.secondary.isKnown()) return null;

        return @as(u8, @intFromBool(self.primary == .in_ear)) +
            @as(u8, @intFromBool(self.secondary == .in_ear));
    }
};

pub fn parseSetting(state: control_command.State) error{InvalidSettingPacket}!?Setting {
    if (state.identifier != setting_identifier) return null;
    if (!std.mem.allEqual(u8, state.values[1..], 0)) return error.InvalidSettingPacket;

    return switch (state.values[0]) {
        @intFromEnum(Setting.on) => .on,
        @intFromEnum(Setting.off) => .off,
        else => error.InvalidSettingPacket,
    };
}

pub fn parseWearPacket(packet: []const u8) error{InvalidWearPacket}!?WearReport {
    if (packet.len < frame_prefix.len or !std.mem.eql(u8, packet[0..frame_prefix.len], &frame_prefix)) {
        return null;
    }
    if (packet.len < 5) return error.InvalidWearPacket;
    if (packet[4] != wear_opcode) return null;
    if (packet.len != 8 or packet[5] != 0) return error.InvalidWearPacket;

    return .{
        .primary = @enumFromInt(packet[6]),
        .secondary = @enumFromInt(packet[7]),
    };
}

pub fn targetSetting(action: Action, current: Setting) Setting {
    return switch (action) {
        .status => current,
        .on => .on,
        .off => .off,
    };
}

pub fn setSetting(session: *aacp.Session, setting: Setting) Error!void {
    const packet = control_command.encode(setting_identifier, &.{@intFromEnum(setting)}) catch unreachable;
    try session.send(&packet);
}
