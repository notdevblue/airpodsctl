const std = @import("std");
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
    @cInclude("unistd.h");
});

const max_devices = 8;
const control_psm = 0x1001;

pub const Error = error{ BluezFailure, TransportFailure };

pub const Address = struct {
    text: [17]u8,
    bytes: [6]u8,

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
        var address: Address = undefined;

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
        const address = Address.parse(device.address[0..device.address_len]) orelse {
            failure.set("invalid Bluetooth address returned by BlueZ: {s}", .{device.address[0..device.address_len]});
            return error.BluezFailure;
        };
        if (requested) |expected| {
            if (!std.mem.eql(u8, &address.text, &expected.text)) continue;
        }
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
    result = c.sd_bus_call_method(
        bus,
        "org.bluez",
        "/",
        "org.freedesktop.DBus.ObjectManager",
        "GetManagedObjects",
        &bus_error,
        &reply,
        "",
    );
    if (result < 0) {
        if (bus_error.message) |message| {
            failure.set("cannot query BlueZ: {s}", .{std.mem.span(message)});
        } else {
            failure.setSystem("cannot query BlueZ", -result);
        }
        return error.BluezFailure;
    }
    result = c.sd_bus_message_enter_container(reply, c.SD_BUS_TYPE_ARRAY, "{oa{sa{sv}}}");
    if (result < 0) {
        failure.setSystem("cannot enter BlueZ objects", -result);
        return error.BluezFailure;
    }

    while (true) {
        result = c.sd_bus_message_enter_container(reply, c.SD_BUS_TYPE_DICT_ENTRY, "oa{sa{sv}}");
        if (result <= 0) break;

        var device = Device{};

        // The object path is irrelevant after its Device1 properties have been collected.
        result = c.sd_bus_message_skip(reply, "o");
        if (result < 0) {
            failure.setSystem("cannot read BlueZ object path", -result);
            return error.BluezFailure;
        }
        try readDeviceInterfaces(reply, &device, failure);

        result = c.sd_bus_message_exit_container(reply);
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
