const c = @cImport({
    @cInclude("pipewire_route_shim.h");
});

pub const Error = error{Unavailable};

pub const RouteState = enum(c_int) {
    unknown = 0,
    selected = 1,
    other = 2,
};

pub const Monitor = struct {
    handle: ?*c.airpodsctl_route = null,

    pub fn init(self: *Monitor, selected_address: [17]u8) Error!void {
        self.handle = c.airpodsctl_route_create(&selected_address, selected_address.len) orelse
            return error.Unavailable;
    }

    pub fn deinit(self: *Monitor) void {
        c.airpodsctl_route_destroy(self.handle);
        self.handle = null;
    }

    pub fn fd(self: *Monitor) c_int {
        return c.airpodsctl_route_fd(self.handle);
    }

    pub fn dispatch(self: *Monitor) Error!void {
        if (c.airpodsctl_route_dispatch(self.handle) < 0) return error.Unavailable;
    }

    pub fn state(self: *const Monitor) RouteState {
        return @enumFromInt(c.airpodsctl_route_state(self.handle));
    }
};

pub fn classify(
    default_sink: [:0]const u8,
    node_name: [:0]const u8,
    node_address: [:0]const u8,
    profile_is_a2dp: bool,
    selected_address: [:0]const u8,
) RouteState {
    return @enumFromInt(c.airpodsctl_route_classify(
        default_sink,
        node_name,
        node_address,
        @intFromBool(profile_is_a2dp),
        selected_address,
    ));
}
