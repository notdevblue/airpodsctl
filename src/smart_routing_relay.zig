const std = @import("std");

const frame_prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00 };
const opcode_offset = frame_prefix.len;
const address_offset = opcode_offset + @sizeOf(u16);
const payload_length_offset = address_offset + 6;
const metadata_offset = payload_length_offset + @sizeOf(u16);
const payload_offset = metadata_offset + 1;
const max_packet_size = 1024;

pub const Address = [6]u8;
pub const max_payload_size = max_packet_size - payload_offset;

pub const Opcode = enum(u16) {
    send = 0x0010,
    receive = 0x0011,

    pub fn name(self: Opcode) []const u8 {
        return switch (self) {
            .send => "send",
            .receive => "receive",
        };
    }
};

pub const Message = struct {
    opcode: Opcode,
    // Preserve wire order until a Mac capture proves how the relay identifies its peer.
    address: Address,
    metadata: u8,
    // The slice borrows the AACP receive buffer and remains valid only until the next receive.
    payload: []const u8,
};

pub const Frame = struct {
    bytes: [max_packet_size]u8 = undefined,
    len: usize,

    pub fn packet(self: *const Frame) []const u8 {
        return self.bytes[0..self.len];
    }
};

// Return null for unrelated traffic and an error only after the frame identifies a relay opcode.
pub fn parse(packet: []const u8) error{InvalidRelayPacket}!?Message {
    if (packet.len < frame_prefix.len or !std.mem.eql(u8, packet[0..frame_prefix.len], &frame_prefix)) {
        return null;
    }
    if (packet.len < address_offset) return error.InvalidRelayPacket;

    const opcode: Opcode = switch (std.mem.readInt(u16, packet[opcode_offset..address_offset], .little)) {
        @intFromEnum(Opcode.send) => .send,
        @intFromEnum(Opcode.receive) => .receive,
        else => return null,
    };
    if (packet.len < payload_offset) return error.InvalidRelayPacket;

    const payload_length = std.mem.readInt(
        u16,
        packet[payload_length_offset..metadata_offset],
        .little,
    );
    if (payload_length > max_payload_size or packet.len != payload_offset + payload_length) {
        return error.InvalidRelayPacket;
    }

    return .{
        .opcode = opcode,
        .address = packet[address_offset..payload_length_offset].*,
        .metadata = packet[metadata_offset],
        .payload = packet[payload_offset..],
    };
}

pub fn encode(
    opcode: Opcode,
    address: Address,
    metadata: u8,
    payload: []const u8,
) error{RelayPayloadTooLarge}!Frame {
    if (payload.len > max_payload_size) return error.RelayPayloadTooLarge;

    var frame = Frame{ .len = payload_offset + payload.len };
    @memcpy(frame.bytes[0..frame_prefix.len], &frame_prefix);
    std.mem.writeInt(u16, frame.bytes[opcode_offset..address_offset], @intFromEnum(opcode), .little);
    @memcpy(frame.bytes[address_offset..payload_length_offset], &address);
    std.mem.writeInt(u16, frame.bytes[payload_length_offset..metadata_offset], @intCast(payload.len), .little);
    frame.bytes[metadata_offset] = metadata;
    @memcpy(frame.bytes[payload_offset..frame.len], payload);
    return frame;
}
