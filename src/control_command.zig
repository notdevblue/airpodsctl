const std = @import("std");

const frame_prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00 };
const opcode = 0x09;

pub const State = struct {
    identifier: u8,
    values: [4]u8,
};

pub fn encode(identifier: u8, values: []const u8) error{TooMuchData}![11]u8 {
    if (values.len > 4) return error.TooMuchData;

    var packet = [_]u8{ 0x04, 0x00, 0x04, 0x00, opcode, 0x00, identifier, 0x00, 0x00, 0x00, 0x00 };
    @memcpy(packet[7 .. 7 + values.len], values);
    return packet;
}

// Return null for unrelated traffic and an error only after the frame identifies this opcode.
pub fn parsePacket(packet: []const u8) error{InvalidControlCommand}!?State {
    if (packet.len < frame_prefix.len or !std.mem.eql(u8, packet[0..frame_prefix.len], &frame_prefix)) {
        return null;
    }
    if (packet.len < 5) return error.InvalidControlCommand;
    if (packet[4] != opcode) return null;
    if (packet.len != 11 or packet[5] != 0) return error.InvalidControlCommand;

    return .{
        .identifier = packet[6],
        .values = packet[7..11].*,
    };
}
