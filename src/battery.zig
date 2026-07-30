const std = @import("std");

const battery_prefix = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x04, 0x00 };
const record_size = 5;

// Explicit component values are the identifiers used in AACP battery records.
pub const Component = enum(u8) {
    right = 0x02,
    left = 0x04,
    case = 0x08,

    pub fn name(self: Component) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?Component {
        if (std.mem.eql(u8, value, "left")) return .left;
        if (std.mem.eql(u8, value, "right")) return .right;
        if (std.mem.eql(u8, value, "case")) return .case;
        return null;
    }
};

pub const State = enum {
    unknown,
    charging,
    discharging,
    disconnected,

    pub fn name(self: State) []const u8 {
        return @tagName(self);
    }
};

pub const Reading = struct {
    level: u8,
    state: State,
};

pub const Report = struct {
    left: ?Reading = null,
    right: ?Reading = null,
    case: ?Reading = null,

    pub fn get(self: Report, component: Component) ?Reading {
        return switch (component) {
            .left => self.left,
            .right => self.right,
            .case => self.case,
        };
    }
};

// Distinguish unrelated AACP traffic from malformed battery notifications.
pub fn parsePacket(packet: []const u8) error{InvalidBatteryPacket}!?Report {
    if (packet.len < 4 or !std.mem.eql(u8, packet[0..4], battery_prefix[0..4])) return null;
    if (packet.len < 5) return error.InvalidBatteryPacket;
    if (packet[4] != battery_prefix[4]) return null;
    if (packet.len < battery_prefix.len or packet[5] != battery_prefix[5]) return error.InvalidBatteryPacket;
    if (packet.len < battery_prefix.len + 1) return error.InvalidBatteryPacket;

    const count = packet[battery_prefix.len];
    if (packet.len != battery_prefix.len + 1 + @as(usize, count) * record_size) {
        return error.InvalidBatteryPacket;
    }

    var report = Report{};

    // Fixed marker bytes frame each [component, level, state] record on the wire.
    for (0..count) |index| {
        const offset = battery_prefix.len + 1 + index * record_size;
        if (packet[offset + 1] != 0x01 or packet[offset + 4] != 0x01 or packet[offset + 2] > 100) {
            return error.InvalidBatteryPacket;
        }
        const state: State = switch (packet[offset + 3]) {
            0x00 => .unknown,
            0x01 => .charging,
            0x02 => .discharging,
            0x04 => .disconnected,
            else => return error.InvalidBatteryPacket,
        };
        const reading = Reading{ .level = packet[offset + 2], .state = state };

        // Unknown component IDs are ignored so new hardware does not hide known readings.
        switch (packet[offset]) {
            @intFromEnum(Component.left) => {
                if (report.left != null) return error.InvalidBatteryPacket;
                report.left = reading;
            },
            @intFromEnum(Component.right) => {
                if (report.right != null) return error.InvalidBatteryPacket;
                report.right = reading;
            },
            @intFromEnum(Component.case) => {
                if (report.case != null) return error.InvalidBatteryPacket;
                report.case = reading;
            },
            else => {},
        }
    }
    return report;
}
