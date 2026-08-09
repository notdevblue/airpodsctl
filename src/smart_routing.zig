const std = @import("std");
const aacp = @import("aacp");
const control_command = @import("control_command");

const frame_prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00 };
const ownership_identifier = 0x06;
const audio_source_request_opcode = 0x0d;
const audio_source_response_opcode = 0x0e;
const connected_devices_request_opcode = 0x2d;
const connected_devices_response_opcode = 0x2e;
const max_hosts = 2;

pub const Error = aacp.Error;
pub const Address = [6]u8;

pub const Hosts = enum {
    local_only,
    local_and_remote,
    unknown,

    pub fn name(self: Hosts) []const u8 {
        return switch (self) {
            .local_only => "local-only",
            .local_and_remote => "local-and-remote",
            .unknown => "unknown",
        };
    }
};

pub const Owner = enum {
    linux,
    remote,
    none,
    unknown,

    pub fn name(self: Owner) []const u8 {
        return switch (self) {
            .linux => "linux",
            .remote => "remote",
            .none => "none",
            .unknown => "unknown",
        };
    }
};

pub const RemoteActivity = enum {
    idle,
    active,
    unknown,

    pub fn name(self: RemoteActivity) []const u8 {
        return switch (self) {
            .idle => "idle",
            .active => "active",
            .unknown => "unknown",
        };
    }
};

pub const AudioSourceState = enum(u8) {
    idle = 0,
    in_call = 1,
    playing = 2,
    _,

    pub fn remoteActivity(self: AudioSourceState) RemoteActivity {
        return switch (self) {
            .idle => .idle,
            .in_call, .playing => .active,
            else => .unknown,
        };
    }
};

pub const AudioSource = struct {
    address: Address,
    state: AudioSourceState,
};

pub const ConnectedDevices = struct {
    metadata: [2]u8,
    addresses: [max_hosts]Address = undefined,
    count: usize,
};

pub const Packet = union(enum) {
    audio_source: AudioSource,
    connected_devices: ConnectedDevices,
};

pub const Status = struct {
    hosts: Hosts,
    owner: Owner,
    remote_activity: RemoteActivity,

    pub fn multipointName(self: Status) []const u8 {
        return if (self.isReady()) "ready" else "unverified";
    }

    pub fn isReady(self: Status) bool {
        return self.hosts == .local_and_remote and self.owner != .unknown and
            self.remote_activity != .unknown;
    }
};

pub const State = struct {
    hosts: Hosts = .unknown,
    local_owns: ?bool = null,
    remote_activity: RemoteActivity = .unknown,

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    pub fn updateOwnership(self: *State, owns: bool) void {
        self.local_owns = owns;
    }

    pub fn updateConnectedDevices(
        self: *State,
        devices: ConnectedDevices,
        local_address: Address,
    ) void {
        var local_count: usize = 0;

        for (devices.addresses[0..devices.count]) |address| {
            if (std.mem.eql(u8, &address, &local_address)) local_count += 1;
        }
        self.hosts = if (local_count != 1)
            .unknown
        else if (devices.count == 1)
            .local_only
        else
            .local_and_remote;
        if (self.hosts != .local_and_remote) self.remote_activity = .unknown;
    }

    pub fn updateAudioSource(self: *State, source: AudioSource, local_address: Address) void {
        const source_is_local = std.mem.eql(u8, &source.address, &local_address);

        // The reported source identifies the single host currently selected by AirPods routing.
        self.local_owns = source_is_local;
        self.remote_activity = if (source_is_local) .idle else source.state.remoteActivity();
    }

    pub fn status(self: State) Status {
        return .{
            .hosts = self.hosts,
            .owner = if (self.local_owns) |owns|
                if (owns) .linux else if (self.hosts == .local_and_remote) .remote else .none
            else
                .unknown,
            .remote_activity = self.remote_activity,
        };
    }
};

fn encodeEmpty(opcode: u16) [6]u8 {
    return .{
        frame_prefix[0],
        frame_prefix[1],
        frame_prefix[2],
        frame_prefix[3],
        @truncate(opcode),
        @truncate(opcode >> 8),
    };
}

pub fn parseOwnership(state: control_command.State) error{InvalidOwnershipPacket}!?bool {
    if (state.identifier != ownership_identifier) return null;
    if (!std.mem.allEqual(u8, state.values[1..], 0)) return error.InvalidOwnershipPacket;

    return switch (state.values[0]) {
        0 => false,
        1 => true,
        else => error.InvalidOwnershipPacket,
    };
}

// Return null for unrelated traffic and an error only after the frame identifies a routing opcode.
pub fn parsePacket(packet: []const u8) error{InvalidRoutingPacket}!?Packet {
    if (packet.len < frame_prefix.len or !std.mem.eql(u8, packet[0..frame_prefix.len], &frame_prefix)) {
        return null;
    }
    if (packet.len < 6) return error.InvalidRoutingPacket;

    const opcode = std.mem.readInt(u16, packet[4..6], .little);
    if (opcode == audio_source_response_opcode) {
        if (packet.len != 13) return error.InvalidRoutingPacket;

        var address = packet[6..12].*;

        // Audio-source responses use Bluetooth byte order, unlike connected-device entries.
        std.mem.reverse(u8, &address);
        return .{ .audio_source = .{
            .address = address,
            .state = @enumFromInt(packet[12]),
        } };
    }
    if (opcode != connected_devices_response_opcode) return null;
    if (packet.len < 9 or packet[8] > max_hosts or packet.len != 9 + @as(usize, packet[8]) * 8) {
        return error.InvalidRoutingPacket;
    }

    var devices = ConnectedDevices{
        .metadata = packet[6..8].*,
        .count = packet[8],
    };
    for (0..devices.count) |index| {
        const offset = 9 + index * 8;
        devices.addresses[index] = packet[offset..][0..6].*;
    }
    return .{ .connected_devices = devices };
}

pub fn requestStatus(session: *aacp.Session) Error!void {
    const connected_devices = encodeEmpty(connected_devices_request_opcode);
    const audio_source = encodeEmpty(audio_source_request_opcode);

    // Send the connected-device request last so its response bounds the status snapshot.
    try session.send(&audio_source);
    try session.send(&connected_devices);
}

pub fn setOwnership(session: *aacp.Session, owns: bool) Error!void {
    const packet = control_command.encode(ownership_identifier, &.{@intFromBool(owns)}) catch unreachable;
    try session.send(&packet);
}
