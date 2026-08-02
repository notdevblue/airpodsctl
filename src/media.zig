const std = @import("std");
const support = @import("support");
const transport = @import("transport");

const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("poll.h");
    @cInclude("stdlib.h");
    @cInclude("systemd/sd-bus.h");
});

const call_timeout_us = 100_000;
const operation_timeout_ms = 1000;
const max_players = 16;
const max_name = 255;
const player_prefix = "org.mpris.MediaPlayer2.";
const player_path = "/org/mpris/MediaPlayer2";
const player_interface = "org.mpris.MediaPlayer2.Player";

pub const Error = error{Unavailable};

pub const PlaybackUpdate = struct {
    playing: bool,
    play_edge: bool,
};

const PlaybackStatus = enum {
    playing,
    paused,
    stopped,
    invalid,
};

const Owner = struct {
    service: [max_name]u8,
    service_len: usize,
    unique: [max_name]u8,
    unique_len: usize,
};

fn copyName(destination: []u8, value: []const u8) ?usize {
    if (value.len == 0 or value.len > destination.len) return null;
    @memcpy(destination[0..value.len], value);
    return value.len;
}

fn parsePlaybackStatus(value: []const u8) PlaybackStatus {
    if (std.mem.eql(u8, value, "Playing")) return .playing;
    if (std.mem.eql(u8, value, "Paused")) return .paused;
    if (std.mem.eql(u8, value, "Stopped")) return .stopped;
    return .invalid;
}

pub const Controller = struct {
    bus: ?*c.sd_bus = null,
    properties_slot: ?*c.sd_bus_slot = null,
    owner_slot: ?*c.sd_bus_slot = null,
    owners: [max_players]Owner = undefined,
    owner_count: usize = 0,
    playback_initialized: bool = false,
    playing: bool = false,
    refresh_pending: bool = false,
    play_edge_pending: bool = false,
    pending_new_service: [max_name]u8 = undefined,
    pending_new_service_len: usize = 0,

    fn removeOwnedAt(self: *Controller, index: usize) void {
        self.owners[index] = self.owners[self.owner_count - 1];
        self.owner_count -= 1;
    }

    fn clearByUnique(self: *Controller, unique: []const u8) void {
        var index: usize = 0;
        while (index < self.owner_count) {
            const owner = self.owners[index];
            if (std.mem.eql(u8, owner.unique[0..owner.unique_len], unique)) {
                self.removeOwnedAt(index);
            } else {
                index += 1;
            }
        }
    }

    fn clearMessageSender(self: *Controller, message: ?*c.sd_bus_message) void {
        const sender = c.sd_bus_message_get_sender(message);
        if (sender != null) self.clearByUnique(std.mem.span(sender));
    }

    fn propertiesChanged(
        message: ?*c.sd_bus_message,
        context: ?*anyopaque,
        _: ?*c.sd_bus_error,
    ) callconv(.c) c_int {
        const self: *Controller = @ptrCast(@alignCast(context.?));
        var interface: [*c]const u8 = null;
        if (c.sd_bus_message_read(message, "s", &interface) < 0 or interface == null or
            !std.mem.eql(u8, std.mem.span(interface), player_interface))
        {
            return 0;
        }
        if (c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_ARRAY, "{sv}") < 0) return 0;

        while (c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_DICT_ENTRY, "sv") > 0) {
            var property: [*c]const u8 = null;
            if (c.sd_bus_message_read(message, "s", &property) < 0) return 0;
            if (property != null and std.mem.eql(u8, std.mem.span(property), "PlaybackStatus")) {
                self.refresh_pending = true;
                if (c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_VARIANT, "s") < 0) {
                    self.clearMessageSender(message);
                    return 0;
                }
                var status: [*c]const u8 = null;
                if (c.sd_bus_message_read(message, "s", &status) < 0) {
                    self.clearMessageSender(message);
                    return 0;
                }
                const playback_status = if (status == null)
                    PlaybackStatus.invalid
                else
                    parsePlaybackStatus(std.mem.span(status));
                if (playback_status == .playing) self.play_edge_pending = true;
                if (playback_status != .paused) {
                    self.clearMessageSender(message);
                }
                if (c.sd_bus_message_exit_container(message) < 0) return 0;
            } else if (c.sd_bus_message_skip(message, "v") < 0) {
                return 0;
            }
            if (c.sd_bus_message_exit_container(message) < 0) return 0;
        }
        if (c.sd_bus_message_exit_container(message) < 0 or
            c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_ARRAY, "s") < 0)
        {
            return 0;
        }
        while (true) {
            var invalidated: [*c]const u8 = null;
            const read = c.sd_bus_message_read(message, "s", &invalidated);
            if (read <= 0) break;
            if (invalidated != null and std.mem.eql(u8, std.mem.span(invalidated), "PlaybackStatus")) {
                self.clearMessageSender(message);
                self.refresh_pending = true;
            }
        }
        return 0;
    }

    fn nameOwnerChanged(
        message: ?*c.sd_bus_message,
        context: ?*anyopaque,
        _: ?*c.sd_bus_error,
    ) callconv(.c) c_int {
        const self: *Controller = @ptrCast(@alignCast(context.?));
        var service: [*c]const u8 = null;
        var previous: [*c]const u8 = null;
        var current: [*c]const u8 = null;
        if (c.sd_bus_message_read(message, "sss", &service, &previous, &current) < 0 or
            service == null or previous == null or current == null)
        {
            return 0;
        }

        const service_name = std.mem.span(service);
        if (std.mem.startsWith(u8, service_name, player_prefix)) {
            self.refresh_pending = true;
            if (std.mem.span(current).len != 0) {
                self.pending_new_service_len = copyName(&self.pending_new_service, service_name) orelse 0;
            }
        }

        var index: usize = 0;
        while (index < self.owner_count) {
            const owner = self.owners[index];
            if (std.mem.eql(u8, owner.service[0..owner.service_len], std.mem.span(service)) and
                std.mem.eql(u8, owner.unique[0..owner.unique_len], std.mem.span(previous)) and
                !std.mem.eql(u8, owner.unique[0..owner.unique_len], std.mem.span(current)))
            {
                self.removeOwnedAt(index);
            } else {
                index += 1;
            }
        }
        return 0;
    }

    fn disconnect(self: *Controller) void {
        self.properties_slot = c.sd_bus_slot_unref(self.properties_slot);
        self.owner_slot = c.sd_bus_slot_unref(self.owner_slot);
        self.bus = c.sd_bus_unref(self.bus);
        self.owner_count = 0;
        self.playback_initialized = false;
        self.playing = false;
        self.refresh_pending = false;
        self.play_edge_pending = false;
        self.pending_new_service_len = 0;
    }

    fn connect(self: *Controller) Error!void {
        if (self.bus != null) return;
        if (c.sd_bus_open_user(&self.bus) < 0) return error.Unavailable;
        errdefer self.disconnect();
        if (c.sd_bus_set_method_call_timeout(self.bus, call_timeout_us) < 0 or
            c.sd_bus_add_match(
                self.bus,
                &self.properties_slot,
                "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/mpris/MediaPlayer2'",
                propertiesChanged,
                self,
            ) < 0 or
            c.sd_bus_add_match(
                self.bus,
                &self.owner_slot,
                "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'",
                nameOwnerChanged,
                self,
            ) < 0)
        {
            return error.Unavailable;
        }
    }

    fn withinDeadline(deadline_ms: i64) bool {
        return transport.nowMs() < deadline_ms;
    }

    fn getPlaybackStatus(self: *Controller, service: [*:0]const u8) ?PlaybackStatus {
        var bus_error: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        var value: [*c]u8 = null;
        defer c.sd_bus_error_free(&bus_error);
        defer c.free(value);
        if (c.sd_bus_get_property_string(
            self.bus,
            service,
            player_path,
            player_interface,
            "PlaybackStatus",
            &bus_error,
            &value,
        ) < 0 or value == null) return null;
        return parsePlaybackStatus(std.mem.span(value));
    }

    fn getCapability(self: *Controller, service: [*:0]const u8, property: [*:0]const u8) bool {
        var bus_error: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        var value: c_int = 0;
        defer c.sd_bus_error_free(&bus_error);
        return c.sd_bus_get_property_trivial(
            self.bus,
            service,
            player_path,
            player_interface,
            property,
            &bus_error,
            c.SD_BUS_TYPE_BOOLEAN,
            &value,
        ) >= 0 and value != 0;
    }

    fn callPlayer(self: *Controller, service: [*:0]const u8, method: [*:0]const u8) bool {
        var bus_error: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        var reply: ?*c.sd_bus_message = null;
        defer c.sd_bus_error_free(&bus_error);
        defer _ = c.sd_bus_message_unref(reply);
        return c.sd_bus_call_method(
            self.bus,
            service,
            player_path,
            player_interface,
            method,
            &bus_error,
            &reply,
            "",
        ) >= 0;
    }

    fn getOwner(self: *Controller, service: [*:0]const u8, owner: *Owner) bool {
        var bus_error: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        var reply: ?*c.sd_bus_message = null;
        defer c.sd_bus_error_free(&bus_error);
        defer _ = c.sd_bus_message_unref(reply);
        if (c.sd_bus_call_method(
            self.bus,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetNameOwner",
            &bus_error,
            &reply,
            "s",
            service,
        ) < 0) return false;
        var value: [*c]const u8 = null;
        if (c.sd_bus_message_read(reply, "s", &value) < 0 or value == null) return false;
        owner.unique_len = copyName(&owner.unique, std.mem.span(value)) orelse return false;
        return true;
    }

    fn recordOwner(self: *Controller, service: []const u8, service_z: [*:0]const u8) void {
        if (self.owner_count == self.owners.len) return;
        for (self.owners[0..self.owner_count]) |owner| {
            if (std.mem.eql(u8, owner.service[0..owner.service_len], service)) return;
        }

        var owner: Owner = undefined;
        owner.service_len = copyName(&owner.service, service) orelse return;
        if (!self.getOwner(service_z, &owner)) return;
        self.owners[self.owner_count] = owner;
        self.owner_count += 1;
    }

    fn refreshPlayback(self: *Controller) Error!void {
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        var bus_error: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        var reply: ?*c.sd_bus_message = null;
        defer c.sd_bus_error_free(&bus_error);
        defer _ = c.sd_bus_message_unref(reply);
        if (c.sd_bus_call_method(
            self.bus,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            &bus_error,
            &reply,
            "",
        ) < 0 or c.sd_bus_message_enter_container(reply, c.SD_BUS_TYPE_ARRAY, "s") < 0) {
            return error.Unavailable;
        }

        var playing = false;
        var inspected: usize = 0;
        while (inspected < max_players and withinDeadline(deadline_ms)) {
            var service_pointer: [*c]const u8 = null;
            const read = c.sd_bus_message_read(reply, "s", &service_pointer);
            if (read <= 0) break;
            if (service_pointer == null) continue;
            const service = std.mem.span(service_pointer);
            if (!std.mem.startsWith(u8, service, player_prefix) or service.len > max_name) continue;

            const status = self.getPlaybackStatus(@ptrCast(service_pointer));
            inspected += 1;
            if (status == .playing) {
                playing = true;
                if (self.pending_new_service_len != 0 and std.mem.eql(
                    u8,
                    self.pending_new_service[0..self.pending_new_service_len],
                    service,
                )) self.play_edge_pending = true;
            }
        }
        self.playing = playing;
        self.playback_initialized = true;
        self.refresh_pending = false;
        self.pending_new_service_len = 0;
    }

    fn currentPlaybackUpdate(self: *Controller) PlaybackUpdate {
        const update = PlaybackUpdate{
            .playing = self.playing,
            .play_edge = self.playing and self.play_edge_pending,
        };
        self.play_edge_pending = false;
        return update;
    }

    pub fn deinit(self: *Controller) void {
        self.disconnect();
    }

    pub fn clear(self: *Controller) void {
        self.owner_count = 0;
    }

    pub fn hasOwnership(self: *const Controller) bool {
        return self.owner_count != 0;
    }

    pub fn fd(self: *const Controller) c_int {
        return if (self.bus) |bus| c.sd_bus_get_fd(bus) else -1;
    }

    pub fn events(self: *const Controller) c_short {
        return if (self.bus) |bus| @intCast(c.sd_bus_get_events(bus)) else 0;
    }

    pub fn dispatch(self: *Controller) Error!void {
        const bus = self.bus orelse return;
        while (true) {
            const result = c.sd_bus_process(bus, null);
            if (result < 0) {
                self.disconnect();
                return error.Unavailable;
            }
            if (result == 0) return;
        }
    }

    pub fn monitorPlayback(self: *Controller) Error!PlaybackUpdate {
        try self.connect();
        if (!self.playback_initialized or self.refresh_pending) try self.refreshPlayback();
        return self.currentPlaybackUpdate();
    }

    pub fn pausePlayers(self: *Controller) Error!void {
        try self.connect();
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        var bus_error: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        var reply: ?*c.sd_bus_message = null;
        defer c.sd_bus_error_free(&bus_error);
        defer _ = c.sd_bus_message_unref(reply);
        if (c.sd_bus_call_method(
            self.bus,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            &bus_error,
            &reply,
            "",
        ) < 0 or c.sd_bus_message_enter_container(reply, c.SD_BUS_TYPE_ARRAY, "s") < 0) {
            return error.Unavailable;
        }

        while (self.owner_count < self.owners.len and withinDeadline(deadline_ms)) {
            var service_pointer: [*c]const u8 = null;
            const read = c.sd_bus_message_read(reply, "s", &service_pointer);
            if (read <= 0) break;
            if (service_pointer == null) continue;
            const service = std.mem.span(service_pointer);
            if (!std.mem.startsWith(u8, service, player_prefix) or service.len > max_name) continue;
            const service_z: [*:0]const u8 = @ptrCast(service_pointer);
            if (self.getPlaybackStatus(service_z) != .playing or !self.getCapability(service_z, "CanPause")) {
                continue;
            }
            if (self.callPlayer(service_z, "Pause") and self.getPlaybackStatus(service_z) == .paused) {
                self.recordOwner(service, service_z);
            }
        }
        self.refresh_pending = true;
    }

    pub fn resumePlayers(self: *Controller) Error!void {
        try self.connect();
        const deadline_ms = transport.nowMs() + operation_timeout_ms;
        while (self.owner_count != 0 and withinDeadline(deadline_ms)) {
            const owner = self.owners[self.owner_count - 1];
            var service: [max_name + 1]u8 = undefined;
            @memcpy(service[0..owner.service_len], owner.service[0..owner.service_len]);
            service[owner.service_len] = 0;
            const service_z = service[0..owner.service_len :0];
            var current_owner: Owner = undefined;
            current_owner.service_len = owner.service_len;
            @memcpy(current_owner.service[0..owner.service_len], owner.service[0..owner.service_len]);

            const eligible = self.getOwner(service_z, &current_owner) and
                std.mem.eql(u8, current_owner.unique[0..current_owner.unique_len], owner.unique[0..owner.unique_len]) and
                self.getPlaybackStatus(service_z) == .paused and
                self.getCapability(service_z, "CanPlay");
            self.owner_count -= 1;
            if (eligible) _ = self.callPlayer(service_z, "Play");
        }
        self.owner_count = 0;
        self.refresh_pending = true;
    }
};
