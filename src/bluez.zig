const std = @import("std");
const bluez_media = @import("bluez_media");
const support = @import("support");
const transport = @import("transport");

// Translate declarations without glibc's compiler-specific fortified inline wrappers.
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("bluetooth/bluetooth.h");
    @cInclude("bluetooth/l2cap.h");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("sys/socket.h");
    @cInclude("systemd/sd-bus.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const max_devices = 8;
const max_object_path = 512;
const control_psm = 0x1001;
const a2dp_source_uuid = "0000110a-0000-1000-8000-00805f9b34fb";
const a2dp_sink_uuid = "0000110b-0000-1000-8000-00805f9b34fb";

pub const Error = error{ BluezFailure, TransportFailure };
pub const MediaTransportState = bluez_media.State;

pub const Address = struct {
    text: [17]u8,
    bytes: [6]u8,
    object_path: [max_object_path]u8,
    object_path_len: usize = 0,

    fn hexValue(character: u8) ?u8 {
        return switch (character) {
            '0'...'9' => character - '0',
            'a'...'f' => character - 'a' + 10,
            'A'...'F' => character - 'A' + 10,
            else => null,
        };
    }

    fn parse(value: []const u8) ?Address {
        const digits = "0123456789ABCDEF";
        var address = Address{
            .text = undefined,
            .bytes = undefined,
            .object_path = undefined,
        };

        if (value.len != address.text.len) return null;
        for (0..6) |index| {
            const offset = index * 3;
            const high = hexValue(value[offset]) orelse return null;
            const low = hexValue(value[offset + 1]) orelse return null;
            if (index < 5 and value[offset + 2] != ':') return null;

            // BlueZ stores Bluetooth addresses least-significant byte first.
            address.bytes[5 - index] = high << 4 | low;
            address.text[offset] = digits[high];
            address.text[offset + 1] = digits[low];
            if (index < 5) address.text[offset + 2] = ':';
        }
        return address;
    }
};

const Device = struct {
    connected: bool = false,
    has_device_interface: bool = false,
    address: [17]u8 = undefined,
    address_len: usize = 0,
    alias: [128]u8 = undefined,
    alias_len: usize = 0,
    name: [128]u8 = undefined,
    name_len: usize = 0,
    modalias: [128]u8 = undefined,
    modalias_len: usize = 0,
    object_path: [max_object_path]u8 = undefined,
    object_path_len: usize = 0,

    fn isAirPods(self: *const Device) bool {
        // BlueZ may omit Modalias, so names are the fallback unless a non-Apple vendor is explicit.
        const named_airpods = std.ascii.findIgnoreCase(self.name[0..self.name_len], "AirPods") != null or
            std.ascii.findIgnoreCase(self.alias[0..self.alias_len], "AirPods") != null;
        const apple_vendor = self.modalias_len == 0 or
            std.ascii.startsWithIgnoreCase(self.modalias[0..self.modalias_len], "bluetooth:v004c");

        return self.has_device_interface and self.connected and self.address_len != 0 and
            named_airpods and apple_vendor;
    }
};

const ManagedObjects = struct {
    bus_error: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error),
    reply: ?*c.sd_bus_message = null,
    bus: ?*c.sd_bus = null,

    fn deinit(self: *ManagedObjects) void {
        c.sd_bus_error_free(&self.bus_error);
        self.reply = c.sd_bus_message_unref(self.reply);
        self.bus = c.sd_bus_unref(self.bus);
    }

    fn open(failure: *support.ErrorMessage) Error!ManagedObjects {
        var objects = ManagedObjects{};
        errdefer objects.deinit();

        var result = c.sd_bus_open_system(&objects.bus);
        if (result < 0) {
            failure.setSystem("cannot connect to the system D-Bus", -result);
            return error.BluezFailure;
        }
        result = c.sd_bus_call_method(
            objects.bus,
            "org.bluez",
            "/",
            "org.freedesktop.DBus.ObjectManager",
            "GetManagedObjects",
            &objects.bus_error,
            &objects.reply,
            "",
        );
        if (result < 0) {
            if (objects.bus_error.message) |message| {
                failure.set("cannot query BlueZ: {s}", .{std.mem.span(message)});
            } else {
                failure.setSystem("cannot query BlueZ", -result);
            }
            return error.BluezFailure;
        }
        result = c.sd_bus_message_enter_container(objects.reply, c.SD_BUS_TYPE_ARRAY, "{oa{sa{sv}}}");
        if (result < 0) {
            failure.setSystem("cannot enter BlueZ objects", -result);
            return error.BluezFailure;
        }
        return objects;
    }
};

fn copyProperty(destination: []u8, destination_len: *usize, source: [*c]const u8) void {
    // Bound D-Bus strings to fixed storage so discovery does not own borrowed message pointers.
    const value = std.mem.span(@as([*:0]const u8, @ptrCast(source)));
    destination_len.* = @min(destination.len, value.len);
    @memcpy(destination[0..destination_len.*], value[0..destination_len.*]);
}

fn readPropertyVariant(
    message: ?*c.sd_bus_message,
    property: []const u8,
    device: *Device,
    failure: *support.ErrorMessage,
) Error!void {
    var contents: [*c]const u8 = null;
    var value_type: u8 = 0;
    var result = c.sd_bus_message_peek_type(message, &value_type, &contents);

    if (result < 0) {
        failure.setSystem("cannot inspect BlueZ property", -result);
        return error.BluezFailure;
    }
    if (value_type != c.SD_BUS_TYPE_VARIANT) {
        failure.set("BlueZ returned a malformed device property", .{});
        return error.BluezFailure;
    }
    result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_VARIANT, contents);
    if (result < 0) {
        failure.setSystem("cannot enter BlueZ property", -result);
        return error.BluezFailure;
    }

    if (std.mem.eql(u8, property, "Connected") and std.mem.eql(u8, std.mem.span(contents), "b")) {
        var connected: c_int = 0;
        result = c.sd_bus_message_read(message, "b", &connected);
        if (result >= 0) device.connected = connected != 0;
    } else if ((std.mem.eql(u8, property, "Address") or
        std.mem.eql(u8, property, "Alias") or
        std.mem.eql(u8, property, "Name") or
        std.mem.eql(u8, property, "Modalias")) and
        std.mem.eql(u8, std.mem.span(contents), "s"))
    {
        var value: [*c]const u8 = null;
        result = c.sd_bus_message_read(message, "s", &value);
        if (result >= 0) {
            if (std.mem.eql(u8, property, "Address")) {
                copyProperty(&device.address, &device.address_len, value);
            } else if (std.mem.eql(u8, property, "Alias")) {
                copyProperty(&device.alias, &device.alias_len, value);
            } else if (std.mem.eql(u8, property, "Name")) {
                copyProperty(&device.name, &device.name_len, value);
            } else {
                copyProperty(&device.modalias, &device.modalias_len, value);
            }
        }
    } else {
        // Skip unfamiliar properties so newer BlueZ versions remain compatible.
        result = c.sd_bus_message_skip(message, contents);
    }
    if (result < 0) {
        failure.setSystem("cannot read BlueZ property", -result);
        return error.BluezFailure;
    }
    result = c.sd_bus_message_exit_container(message);
    if (result < 0) {
        failure.setSystem("cannot leave BlueZ property", -result);
        return error.BluezFailure;
    }
}

fn readDeviceProperties(
    message: ?*c.sd_bus_message,
    device: *Device,
    failure: *support.ErrorMessage,
) Error!void {
    var result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_ARRAY, "{sv}");
    if (result < 0) {
        failure.setSystem("cannot enter BlueZ properties", -result);
        return error.BluezFailure;
    }

    while (true) {
        result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_DICT_ENTRY, "sv");
        if (result <= 0) break;

        var property: [*c]const u8 = null;
        result = c.sd_bus_message_read(message, "s", &property);
        if (result < 0) {
            failure.setSystem("cannot read BlueZ property name", -result);
            return error.BluezFailure;
        }
        try readPropertyVariant(message, std.mem.span(property), device, failure);

        result = c.sd_bus_message_exit_container(message);
        if (result < 0) {
            failure.setSystem("cannot leave BlueZ property entry", -result);
            return error.BluezFailure;
        }
    }
    if (result < 0) {
        failure.setSystem("cannot iterate BlueZ properties", -result);
        return error.BluezFailure;
    }
    result = c.sd_bus_message_exit_container(message);
    if (result < 0) {
        failure.setSystem("cannot leave BlueZ properties", -result);
        return error.BluezFailure;
    }
}

fn readDeviceInterfaces(
    message: ?*c.sd_bus_message,
    device: *Device,
    failure: *support.ErrorMessage,
) Error!void {
    var result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_ARRAY, "{sa{sv}}");
    if (result < 0) {
        failure.setSystem("cannot enter BlueZ interfaces", -result);
        return error.BluezFailure;
    }

    while (true) {
        result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_DICT_ENTRY, "sa{sv}");
        if (result <= 0) break;

        var interface: [*c]const u8 = null;
        result = c.sd_bus_message_read(message, "s", &interface);
        if (result < 0) {
            failure.setSystem("cannot read BlueZ interface", -result);
            return error.BluezFailure;
        }
        if (std.mem.eql(u8, std.mem.span(interface), "org.bluez.Device1")) {
            device.has_device_interface = true;
            try readDeviceProperties(message, device, failure);
        } else {
            result = c.sd_bus_message_skip(message, "a{sv}");
            if (result < 0) {
                failure.setSystem("cannot skip BlueZ interface", -result);
                return error.BluezFailure;
            }
        }

        result = c.sd_bus_message_exit_container(message);
        if (result < 0) {
            failure.setSystem("cannot leave BlueZ interface", -result);
            return error.BluezFailure;
        }
    }
    if (result < 0) {
        failure.setSystem("cannot iterate BlueZ interfaces", -result);
        return error.BluezFailure;
    }
    result = c.sd_bus_message_exit_container(message);
    if (result < 0) {
        failure.setSystem("cannot leave BlueZ interfaces", -result);
        return error.BluezFailure;
    }
}

fn selectDevice(
    devices: []const Device,
    requested_address: ?[]const u8,
    failure: *support.ErrorMessage,
) Error!Address {
    // Normalize once so caller input and BlueZ output compare in one canonical form.
    const requested = if (requested_address) |value| Address.parse(value) orelse {
        failure.set("invalid Bluetooth address: {s}", .{value});
        return error.BluezFailure;
    } else null;
    var selected: ?Address = null;
    var match_count: usize = 0;

    for (devices) |device| {
        if (!device.isAirPods()) continue;
        var address = Address.parse(device.address[0..device.address_len]) orelse {
            failure.set("invalid Bluetooth address returned by BlueZ: {s}", .{device.address[0..device.address_len]});
            return error.BluezFailure;
        };
        if (requested) |expected| {
            if (!std.mem.eql(u8, &address.text, &expected.text)) continue;
        }
        address.object_path_len = device.object_path_len;
        @memcpy(address.object_path[0..address.object_path_len], device.object_path[0..device.object_path_len]);
        selected = address;
        match_count += 1;
    }

    if (match_count == 1) return selected.?;
    if (requested) |expected| {
        failure.set(
            "AirPods {s} are not connected or were not recognized by BlueZ",
            .{expected.text},
        );
    } else if (match_count == 0) {
        failure.set("no connected AirPods were found", .{});
    } else {
        failure.set("multiple AirPods are connected; select one with --device MAC", .{});
    }
    return error.BluezFailure;
}

// Query only BlueZ's already-managed devices; discovery never scans or pairs hardware.
pub fn discover(requested_address: ?[]const u8, failure: *support.ErrorMessage) Error!Address {
    // Bound retained device data while the D-Bus reply itself may contain many unrelated objects.
    var devices: [max_devices]Device = undefined;
    var device_count: usize = 0;
    var objects = try ManagedObjects.open(failure);
    defer objects.deinit();
    var result: c_int = 0;

    while (true) {
        result = c.sd_bus_message_enter_container(objects.reply, c.SD_BUS_TYPE_DICT_ENTRY, "oa{sa{sv}}");
        if (result <= 0) break;

        var device = Device{};
        var object_path: [*c]const u8 = null;

        result = c.sd_bus_message_read(objects.reply, "o", &object_path);
        if (result < 0) {
            failure.setSystem("cannot read BlueZ object path", -result);
            return error.BluezFailure;
        }
        copyProperty(&device.object_path, &device.object_path_len, object_path);
        try readDeviceInterfaces(objects.reply, &device, failure);

        result = c.sd_bus_message_exit_container(objects.reply);
        if (result < 0) {
            failure.setSystem("cannot leave BlueZ object", -result);
            return error.BluezFailure;
        }
        if (device.isAirPods()) {
            if (device_count == devices.len) {
                failure.set("too many connected AirPods to inspect safely", .{});
                return error.BluezFailure;
            }
            devices[device_count] = device;
            device_count += 1;
        }
    }
    if (result < 0) {
        failure.setSystem("cannot iterate BlueZ objects", -result);
        return error.BluezFailure;
    }
    return selectDevice(devices[0..device_count], requested_address, failure);
}

const MediaTransport = struct {
    has_interface: bool = false,
    is_a2dp_source: bool = false,
    state: MediaTransportState = .unknown,
};

fn readMediaTransportProperty(
    message: ?*c.sd_bus_message,
    property: []const u8,
    media_transport: *MediaTransport,
    failure: *support.ErrorMessage,
) Error!void {
    var contents: [*c]const u8 = null;
    var value_type: u8 = 0;
    var result = c.sd_bus_message_peek_type(message, &value_type, &contents);

    if (result < 0) {
        failure.setSystem("cannot inspect BlueZ media-transport property", -result);
        return error.BluezFailure;
    }
    if (value_type != c.SD_BUS_TYPE_VARIANT) {
        failure.set("BlueZ returned a malformed media-transport property", .{});
        return error.BluezFailure;
    }
    result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_VARIANT, contents);
    if (result < 0) {
        failure.setSystem("cannot enter BlueZ media-transport property", -result);
        return error.BluezFailure;
    }

    if ((std.mem.eql(u8, property, "State") or std.mem.eql(u8, property, "UUID")) and
        std.mem.eql(u8, std.mem.span(contents), "s"))
    {
        var value: [*c]const u8 = null;
        result = c.sd_bus_message_read(message, "s", &value);
        if (result >= 0) {
            if (std.mem.eql(u8, property, "State")) {
                media_transport.state = MediaTransportState.parse(std.mem.span(value));
            } else {
                media_transport.is_a2dp_source = std.ascii.eqlIgnoreCase(std.mem.span(value), a2dp_source_uuid);
            }
        }
    } else {
        result = c.sd_bus_message_skip(message, contents);
    }
    if (result < 0) {
        failure.setSystem("cannot read BlueZ media-transport property", -result);
        return error.BluezFailure;
    }
    result = c.sd_bus_message_exit_container(message);
    if (result < 0) {
        failure.setSystem("cannot leave BlueZ media-transport property", -result);
        return error.BluezFailure;
    }
}

fn readMediaTransportProperties(
    message: ?*c.sd_bus_message,
    media_transport: *MediaTransport,
    failure: *support.ErrorMessage,
) Error!void {
    var result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_ARRAY, "{sv}");
    if (result < 0) {
        failure.setSystem("cannot enter BlueZ media-transport properties", -result);
        return error.BluezFailure;
    }

    while (true) {
        result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_DICT_ENTRY, "sv");
        if (result <= 0) break;

        var property: [*c]const u8 = null;
        result = c.sd_bus_message_read(message, "s", &property);
        if (result < 0) {
            failure.setSystem("cannot read BlueZ media-transport property name", -result);
            return error.BluezFailure;
        }
        try readMediaTransportProperty(message, std.mem.span(property), media_transport, failure);

        result = c.sd_bus_message_exit_container(message);
        if (result < 0) {
            failure.setSystem("cannot leave BlueZ media-transport property entry", -result);
            return error.BluezFailure;
        }
    }
    if (result < 0) {
        failure.setSystem("cannot iterate BlueZ media-transport properties", -result);
        return error.BluezFailure;
    }
    result = c.sd_bus_message_exit_container(message);
    if (result < 0) {
        failure.setSystem("cannot leave BlueZ media-transport properties", -result);
        return error.BluezFailure;
    }
}

fn readMediaTransportInterfaces(
    message: ?*c.sd_bus_message,
    media_transport: *MediaTransport,
    failure: *support.ErrorMessage,
) Error!void {
    var result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_ARRAY, "{sa{sv}}");
    if (result < 0) {
        failure.setSystem("cannot enter BlueZ media-transport interfaces", -result);
        return error.BluezFailure;
    }

    while (true) {
        result = c.sd_bus_message_enter_container(message, c.SD_BUS_TYPE_DICT_ENTRY, "sa{sv}");
        if (result <= 0) break;

        var interface: [*c]const u8 = null;
        result = c.sd_bus_message_read(message, "s", &interface);
        if (result < 0) {
            failure.setSystem("cannot read BlueZ media-transport interface", -result);
            return error.BluezFailure;
        }
        if (std.mem.eql(u8, std.mem.span(interface), "org.bluez.MediaTransport1")) {
            media_transport.has_interface = true;
            try readMediaTransportProperties(message, media_transport, failure);
        } else {
            result = c.sd_bus_message_skip(message, "a{sv}");
            if (result < 0) {
                failure.setSystem("cannot skip BlueZ media-transport interface", -result);
                return error.BluezFailure;
            }
        }

        result = c.sd_bus_message_exit_container(message);
        if (result < 0) {
            failure.setSystem("cannot leave BlueZ media-transport interface entry", -result);
            return error.BluezFailure;
        }
    }
    if (result < 0) {
        failure.setSystem("cannot iterate BlueZ media-transport interfaces", -result);
        return error.BluezFailure;
    }
    result = c.sd_bus_message_exit_container(message);
    if (result < 0) {
        failure.setSystem("cannot leave BlueZ media-transport interfaces", -result);
        return error.BluezFailure;
    }
}

pub fn mediaTransportState(
    address: Address,
    failure: *support.ErrorMessage,
) Error!MediaTransportState {
    if (address.object_path_len == 0) {
        failure.set("cannot identify the selected AirPods BlueZ object", .{});
        return error.BluezFailure;
    }

    var objects = try ManagedObjects.open(failure);
    defer objects.deinit();
    var aggregate: MediaTransportState = .absent;
    var result: c_int = 0;

    while (true) {
        result = c.sd_bus_message_enter_container(objects.reply, c.SD_BUS_TYPE_DICT_ENTRY, "oa{sa{sv}}");
        if (result <= 0) break;

        var object_path: [*c]const u8 = null;
        result = c.sd_bus_message_read(objects.reply, "o", &object_path);
        if (result < 0) {
            failure.setSystem("cannot read BlueZ media-transport object path", -result);
            return error.BluezFailure;
        }

        const path = std.mem.span(object_path);
        const device_path = address.object_path[0..address.object_path_len];
        const belongs_to_device = path.len > device_path.len and
            path[device_path.len] == '/' and
            std.mem.eql(u8, path[0..device_path.len], device_path);
        if (belongs_to_device) {
            var media_transport = MediaTransport{};
            try readMediaTransportInterfaces(objects.reply, &media_transport, failure);
            if (media_transport.has_interface and media_transport.is_a2dp_source) {
                aggregate = aggregate.merge(media_transport.state);
            }
        } else {
            result = c.sd_bus_message_skip(objects.reply, "a{sa{sv}}");
            if (result < 0) {
                failure.setSystem("cannot skip unrelated BlueZ object", -result);
                return error.BluezFailure;
            }
        }

        result = c.sd_bus_message_exit_container(objects.reply);
        if (result < 0) {
            failure.setSystem("cannot leave BlueZ media-transport object", -result);
            return error.BluezFailure;
        }
    }
    if (result < 0) {
        failure.setSystem("cannot iterate BlueZ media-transport objects", -result);
        return error.BluezFailure;
    }
    return aggregate;
}

fn callDeviceProfile(
    address: Address,
    method: [*:0]const u8,
    ignored_error: ?[]const u8,
    failure: *support.ErrorMessage,
) Error!void {
    if (address.object_path_len == 0) {
        failure.set("cannot identify the selected AirPods BlueZ object", .{});
        return error.BluezFailure;
    }

    var bus_error: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
    var reply: ?*c.sd_bus_message = null;
    var bus: ?*c.sd_bus = null;

    defer c.sd_bus_error_free(&bus_error);
    defer _ = c.sd_bus_message_unref(reply);
    defer _ = c.sd_bus_unref(bus);

    var result = c.sd_bus_open_system(&bus);
    if (result < 0) {
        failure.setSystem("cannot connect to the system D-Bus", -result);
        return error.BluezFailure;
    }

    var object_path: [max_object_path + 1]u8 = undefined;
    @memcpy(object_path[0..address.object_path_len], address.object_path[0..address.object_path_len]);
    object_path[address.object_path_len] = 0;
    result = c.sd_bus_call_method(
        bus,
        "org.bluez",
        @ptrCast(&object_path),
        "org.bluez.Device1",
        method,
        &bus_error,
        &reply,
        "s",
        a2dp_sink_uuid,
    );
    if (result >= 0) return;
    if (ignored_error != null and bus_error.name != null and
        std.mem.eql(u8, std.mem.span(bus_error.name), ignored_error.?))
    {
        return;
    }
    if (bus_error.name != null and std.mem.eql(u8, std.mem.span(method), "ConnectProfile") and
        std.mem.eql(u8, std.mem.span(bus_error.name), "org.bluez.Error.InProgress"))
    {
        return;
    }
    if (bus_error.message) |message| {
        failure.set("BlueZ {s} failed: {s}", .{ std.mem.span(method), std.mem.span(message) });
    } else {
        failure.setSystem("BlueZ audio-profile operation failed", -result);
    }
    return error.BluezFailure;
}

fn delayUntil(deadline_ms: i64, delay_ms: i64, failure: *support.ErrorMessage) Error!void {
    const duration_ms = @min(delay_ms, @max(deadline_ms - transport.nowMs(), 0));
    var duration = c.struct_timespec{
        .tv_sec = @intCast(@divTrunc(duration_ms, 1000)),
        .tv_nsec = @intCast(@mod(duration_ms, 1000) * 1_000_000),
    };

    while (duration_ms != 0 and c.nanosleep(&duration, &duration) != 0) {
        if (support.lastErrno() != c.EINTR) {
            failure.setSystem("BlueZ audio-profile recovery delay failed", support.lastErrno());
            return error.BluezFailure;
        }
    }
}

pub fn resetAudioProfile(
    address: Address,
    deadline_ms: i64,
    failure: *support.ErrorMessage,
) Error!void {
    try callDeviceProfile(address, "DisconnectProfile", "org.bluez.Error.NotConnected", failure);
    try delayUntil(deadline_ms, 100, failure);
    try callDeviceProfile(address, "ConnectProfile", "org.bluez.Error.AlreadyConnected", failure);
}

pub fn connectAudioProfile(address: Address, failure: *support.ErrorMessage) Error!void {
    try callDeviceProfile(address, "ConnectProfile", "org.bluez.Error.AlreadyConnected", failure);
}

fn waitForMediaTransportCondition(
    address: Address,
    deadline_ms: i64,
    require_active: bool,
    failure: *support.ErrorMessage,
) Error!MediaTransportState {
    var state = try mediaTransportState(address, failure);

    while ((if (require_active) !state.isUsable() else state == .absent) and
        transport.nowMs() < deadline_ms)
    {
        try delayUntil(deadline_ms, 100, failure);
        state = try mediaTransportState(address, failure);
    }
    return state;
}

pub fn waitForMediaTransport(
    address: Address,
    deadline_ms: i64,
    failure: *support.ErrorMessage,
) Error!MediaTransportState {
    return waitForMediaTransportCondition(address, deadline_ms, true, failure);
}

pub fn waitForMediaTransportPresent(
    address: Address,
    deadline_ms: i64,
    failure: *support.ErrorMessage,
) Error!MediaTransportState {
    return waitForMediaTransportCondition(address, deadline_ms, false, failure);
}

fn waitForConnection(fd: c_int, deadline_ms: i64, failure: *support.ErrorMessage) Error!void {
    var descriptor = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };

    while (true) {
        const remaining = deadline_ms - transport.nowMs();
        if (remaining <= 0) {
            failure.set("AirPods control connection timed out", .{});
            return error.TransportFailure;
        }

        const ready = c.poll(&descriptor, 1, @intCast(@min(remaining, std.math.maxInt(c_int))));
        if (ready > 0) {
            var socket_error: c_int = 0;
            var socket_error_size: c.socklen_t = @sizeOf(c_int);

            // Writability only marks completion; SO_ERROR distinguishes success from async failure.
            if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &socket_error_size) != 0) {
                failure.setSystem("cannot inspect Bluetooth connection", support.lastErrno());
                return error.TransportFailure;
            }
            if (socket_error != 0) {
                failure.setSystem("cannot open AirPods control channel", socket_error);
                return error.TransportFailure;
            }
            return;
        }
        if (ready == 0) {
            failure.set("AirPods control connection timed out", .{});
            return error.TransportFailure;
        }
        if (support.lastErrno() != c.EINTR) {
            failure.setSystem("Bluetooth connection poll failed", support.lastErrno());
            return error.TransportFailure;
        }
    }
}

pub fn close(fd: c_int) void {
    _ = c.close(fd);
}

pub fn localAddress(fd: c_int, failure: *support.ErrorMessage) Error![6]u8 {
    var source: c.struct_sockaddr_l2 = std.mem.zeroes(c.struct_sockaddr_l2);
    var size: c.socklen_t = @sizeOf(c.struct_sockaddr_l2);

    if (c.getsockname(fd, .{ .__sockaddr__ = @ptrCast(&source) }, &size) != 0) {
        failure.setSystem("cannot inspect the local Bluetooth address", support.lastErrno());
        return error.TransportFailure;
    }
    if (size < @sizeOf(c.struct_sockaddr_l2) or source.l2_family != c.AF_BLUETOOTH) {
        failure.set("Bluetooth returned an invalid local control address", .{});
        return error.TransportFailure;
    }

    var address = source.l2_bdaddr.b;

    // sockaddr_l2 stores bdaddr least-significant byte first, unlike connected-device routing entries.
    std.mem.reverse(u8, &address);
    return address;
}

// Open Apple's proprietary L2CAP channel without allowing connect to block the deadline.
pub fn openControlChannel(
    address: Address,
    deadline_ms: i64,
    failure: *support.ErrorMessage,
) Error!c_int {
    var destination: c.struct_sockaddr_l2 = std.mem.zeroes(c.struct_sockaddr_l2);
    destination.l2_family = c.AF_BLUETOOTH;
    destination.l2_psm = std.mem.nativeToLittle(u16, control_psm);
    destination.l2_bdaddr.b = address.bytes;

    const fd = c.socket(
        c.AF_BLUETOOTH,
        c.SOCK_SEQPACKET | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK,
        c.BTPROTO_L2CAP,
    );
    if (fd < 0) {
        failure.setSystem("cannot create Bluetooth control socket", support.lastErrno());
        return error.TransportFailure;
    }
    errdefer _ = c.close(fd);

    // Zig represents glibc's transparent sockaddr parameter as an explicit union field.
    if (c.connect(
        fd,
        .{ .__sockaddr__ = @ptrCast(&destination) },
        @sizeOf(c.struct_sockaddr_l2),
    ) == 0) return fd;
    if (support.lastErrno() != c.EINPROGRESS and
        support.lastErrno() != c.EAGAIN and
        support.lastErrno() != c.EWOULDBLOCK)
    {
        failure.setSystem("cannot open AirPods control channel", support.lastErrno());
        return error.TransportFailure;
    }
    try waitForConnection(fd, deadline_ms, failure);
    return fd;
}
