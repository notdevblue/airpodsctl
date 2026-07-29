const support = @import("support");
const transport = @import("transport");

// Bound inbound datagrams well above known frames so oversized responses are rejected.
const packet_size = 1024;

// AirPods expect these observed AACP frames verbatim during protocol initialization.
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

pub const Error = transport.Error;

pub const Session = struct {
    channel: transport.Channel,
    packet: [packet_size]u8 = undefined,

    pub fn send(self: *Session, packet: []const u8) Error!void {
        try self.channel.send(packet);
    }

    pub fn receive(self: *Session) Error![]const u8 {
        return self.channel.receive(&self.packet);
    }

    pub fn initialize(
        fd: c_int,
        deadline_ms: i64,
        delay_ms: u32,
        failure: *support.ErrorMessage,
    ) Error!Session {
        var session = Session{
            .channel = .{
                .fd = fd,
                .deadline_ms = deadline_ms,
                .failure = failure,
            },
        };

        try session.send(&handshake_packet);
        try session.channel.delay(delay_ms);

        // AirPods expect a pause between the handshake and feature negotiation packets.
        try session.send(&feature_flags_packet);
        try session.channel.delay(delay_ms);

        // Feature modules consume the notifications relevant to their own operation.
        try session.send(&notification_request_packet);
        return session;
    }
};
