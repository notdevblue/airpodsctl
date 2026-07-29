const std = @import("std");
const battery = @import("battery");
const noise_control = @import("noise_control");

const max_toggle_modes = 4;

pub const usage =
    \\Usage: airpodsctl [--device MAC] COMMAND
    \\       airpodsctl [--device MAC] toggle [MODE...]
    \\       airpodsctl [--device MAC] battery [COMPONENT]
    \\
    \\Commands:
    \\  status        Print the current listening mode
    \\  anc           Enable active noise cancellation
    \\  off           Disable all listening-mode processing
    \\  transparency  Pass surrounding sound through
    \\  adaptive      Adjust noise control for the surroundings
    \\  toggle [MODE...]
    \\                Cycle through MODEs in order (defaults to anc off)
    \\  battery [COMPONENT]
    \\                Print all battery readings or one percentage
    \\
    \\Toggle modes:
    \\  anc, off, transparency, adaptive
    \\
    \\Battery components:
    \\  left, right, case
    \\
    \\Options:
    \\  -d, --device MAC  Select connected AirPods by Bluetooth address
    \\  -h, --help        Show this help
    \\  -V, --version     Show the program version
    \\
;

pub const NoiseControlCommand = struct {
    action: noise_control.Action,
    toggle_modes: [max_toggle_modes]noise_control.Mode = undefined,
    toggle_mode_count: usize = 0,
};

pub const Operation = union(enum) {
    noise_control: NoiseControlCommand,
    battery: ?battery.Component,
};

pub const Command = struct {
    requested_address: ?[]const u8,
    operation: Operation,
};

pub const Invocation = union(enum) {
    help,
    version,
    usage,
    execute: Command,
};

pub fn parseInvocation(arguments: []const [:0]const u8) Invocation {
    // Keep an overflow slot so a fifth toggle mode is rejected by mode-count validation.
    var positional: [max_toggle_modes + 2][]const u8 = undefined;
    var positional_count: usize = 0;
    var requested_address: ?[]const u8 = null;
    var options_ended = false;
    var index: usize = 1;

    // Scan the whole command line so options work on either side of the command until `--`.
    while (index < arguments.len) : (index += 1) {
        const argument: []const u8 = arguments[index];
        if (!options_ended and std.mem.eql(u8, argument, "--")) {
            options_ended = true;
            continue;
        }
        if (!options_ended and std.mem.eql(u8, argument, "--help")) return .help;
        if (!options_ended and std.mem.eql(u8, argument, "--version")) return .version;
        if (!options_ended and std.mem.eql(u8, argument, "--device")) {
            index += 1;
            if (index == arguments.len) return .usage;
            requested_address = arguments[index];
            continue;
        }
        if (!options_ended and std.mem.startsWith(u8, argument, "--device=")) {
            requested_address = argument["--device=".len..];
            continue;
        }
        if (!options_ended and std.mem.startsWith(u8, argument, "--")) return .usage;
        if (!options_ended and argument.len > 1 and argument[0] == '-') {
            var short_index: usize = 1;
            while (short_index < argument.len) : (short_index += 1) {
                switch (argument[short_index]) {
                    'h' => return .help,
                    'V' => return .version,
                    'd' => {
                        if (short_index + 1 < argument.len) {
                            requested_address = argument[short_index + 1 ..];
                        } else {
                            index += 1;
                            if (index == arguments.len) return .usage;
                            requested_address = arguments[index];
                        }
                        break;
                    },
                    else => return .usage,
                }
            }
            continue;
        }
        if (positional_count == positional.len) return .usage;
        positional[positional_count] = argument;
        positional_count += 1;
    }

    if (positional_count == 0) return .usage;
    if (std.mem.eql(u8, positional[0], "battery")) {
        if (positional_count > 2) return .usage;
        return .{ .execute = .{
            .requested_address = requested_address,
            .operation = .{ .battery = if (positional_count == 2)
                battery.Component.parse(positional[1]) orelse return .usage
            else
                null },
        } };
    }

    const action = noise_control.Action.parse(positional[0]) orelse return .usage;
    const toggle_mode_count = positional_count - 1;
    if ((action != .toggle and toggle_mode_count != 0) or toggle_mode_count > max_toggle_modes) {
        return .usage;
    }

    var command = NoiseControlCommand{
        .action = action,
        .toggle_mode_count = toggle_mode_count,
    };
    for (positional[1..positional_count], 0..) |value, mode_index| {
        command.toggle_modes[mode_index] = noise_control.Mode.parse(value) orelse return .usage;

        // Duplicate entries make a cycle position ambiguous and provide no useful behavior.
        for (command.toggle_modes[0..mode_index]) |previous| {
            if (previous == command.toggle_modes[mode_index]) return .usage;
        }
    }
    return .{ .execute = .{
        .requested_address = requested_address,
        .operation = .{ .noise_control = command },
    } };
}
