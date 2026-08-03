const std = @import("std");

const frame_prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00 };
const wear_opcode = 0x06;

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
