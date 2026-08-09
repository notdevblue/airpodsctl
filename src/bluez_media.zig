const std = @import("std");

pub const State = enum {
    absent,
    idle,
    pending,
    active,
    unknown,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .absent => "absent",
            .idle => "idle",
            .pending => "pending",
            .active => "active",
            .unknown => "unknown",
        };
    }

    pub fn isUsable(self: State) bool {
        return self == .active;
    }

    pub fn parse(value: []const u8) State {
        if (std.mem.eql(u8, value, "idle")) return .idle;
        if (std.mem.eql(u8, value, "pending")) return .pending;
        if (std.mem.eql(u8, value, "active")) return .active;
        return .unknown;
    }

    fn rank(self: State) u8 {
        return switch (self) {
            .absent => 0,
            .unknown => 1,
            .idle => 2,
            .pending => 3,
            .active => 4,
        };
    }

    pub fn merge(self: State, other: State) State {
        return if (other.rank() > self.rank()) other else self;
    }
};

pub const RecoveryDecision = enum {
    none,
    wait,
    connect_profile,
    reset_profile,
    fail_closed,
};

pub fn recoveryDecision(
    state: State,
    playback_active: bool,
    settlement_elapsed: bool,
    explicit_take: bool,
) RecoveryDecision {
    if (state.isUsable()) return .none;
    if (state == .absent and explicit_take and !playback_active) return .connect_profile;
    if (!playback_active) return .none;
    if (!settlement_elapsed) return .wait;

    return switch (state) {
        .absent => .connect_profile,
        .idle, .pending => .reset_profile,
        .active => .none,
        .unknown => .fail_closed,
    };
}
