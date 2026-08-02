const std = @import("std");
const battery = @import("battery");
const command = @import("command");
const ear_detection = @import("ear_detection");
const noise_control = @import("noise_control");

pub const usage =
    \\Usage: airpodsctl [--device MAC] COMMAND
    \\       airpodsctl [--device MAC] toggle [MODE...]
    \\       airpodsctl [--device MAC] battery [COMPONENT]
    \\       airpodsctl [--device MAC] automatic-ear-detection status|on|off
    \\       airpodsctl [--device MAC] wear-status
    \\       airpodsctl [--device MAC] serve [--pause-on-removal=POLICY]
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
    \\  automatic-ear-detection status|on|off
    \\                Read or change the AirPods device preference
    \\  wear-status   Print the latest primary and secondary wear state
    \\  serve         Keep an AACP session available to later commands
    \\
    \\Toggle modes:
    \\  anc, off, transparency, adaptive
    \\
    \\Battery components:
    \\  left, right
    \\
    \\Pause policies:
    \\  one, both, off
    \\
    \\Options:
    \\  -d, --device MAC  Select connected AirPods by Bluetooth address
    \\      --session     Require a running session service
    \\      --direct      Bypass the session service
    \\      --pause-on-removal POLICY
    \\                    Pause MPRIS players while serving (default: off)
    \\  -h, --help        Show this help
    \\  -V, --version     Show the program version
    \\
;

pub const Backend = enum {
    automatic,
    session,
    direct,
};

pub const Command = struct {
    requested_address: ?[]const u8,
    backend: Backend,
    operation: command.Operation,
};

pub const ServeCommand = struct {
    requested_address: ?[]const u8,
    pause_on_removal: command.PauseOnRemoval,
};

pub const Invocation = union(enum) {
    help,
    version,
    usage,
    serve: ServeCommand,
    execute: Command,
};

fn parsePauseOnRemoval(value: []const u8) ?command.PauseOnRemoval {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "one")) return .one;
    if (std.mem.eql(u8, value, "both")) return .both;
    return null;
}

pub fn parseInvocation(arguments: []const [:0]const u8) Invocation {
    // Keep an overflow slot so a fifth toggle mode is rejected by mode-count validation.
    var positional: [command.max_toggle_modes + 2][]const u8 = undefined;
    var positional_count: usize = 0;
    var requested_address: ?[]const u8 = null;
    var pause_on_removal: ?command.PauseOnRemoval = null;
    var backend: Backend = .automatic;
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
        if (!options_ended and std.mem.eql(u8, argument, "--pause-on-removal")) {
            if (pause_on_removal != null) return .usage;
            index += 1;
            if (index == arguments.len) return .usage;
            pause_on_removal = parsePauseOnRemoval(arguments[index]) orelse return .usage;
            continue;
        }
        if (!options_ended and std.mem.startsWith(u8, argument, "--pause-on-removal=")) {
            if (pause_on_removal != null) return .usage;
            pause_on_removal = parsePauseOnRemoval(argument["--pause-on-removal=".len..]) orelse return .usage;
            continue;
        }
        if (!options_ended and std.mem.eql(u8, argument, "--session")) {
            if (backend != .automatic) return .usage;
            backend = .session;
            continue;
        }
        if (!options_ended and std.mem.eql(u8, argument, "--direct")) {
            if (backend != .automatic) return .usage;
            backend = .direct;
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
    if (std.mem.eql(u8, positional[0], "serve")) {
        if (positional_count != 1 or backend != .automatic) return .usage;
        return .{ .serve = .{
            .requested_address = requested_address,
            .pause_on_removal = pause_on_removal orelse .off,
        } };
    }
    if (pause_on_removal != null) return .usage;
    if (std.mem.eql(u8, positional[0], "battery")) {
        if (positional_count > 2) return .usage;
        return .{ .execute = .{
            .requested_address = requested_address,
            .backend = backend,
            .operation = .{ .battery = if (positional_count == 2)
                battery.Component.parse(positional[1]) orelse return .usage
            else
                null },
        } };
    }
    if (std.mem.eql(u8, positional[0], "automatic-ear-detection")) {
        if (positional_count != 2) return .usage;
        return .{ .execute = .{
            .requested_address = requested_address,
            .backend = backend,
            .operation = .{ .automatic_ear_detection = ear_detection.Action.parse(positional[1]) orelse
                return .usage },
        } };
    }
    if (std.mem.eql(u8, positional[0], "wear-status")) {
        if (positional_count != 1) return .usage;
        return .{ .execute = .{
            .requested_address = requested_address,
            .backend = backend,
            .operation = .wear_status,
        } };
    }

    const action = noise_control.Action.parse(positional[0]) orelse return .usage;
    const toggle_mode_count = positional_count - 1;
    if ((action != .toggle and toggle_mode_count != 0) or toggle_mode_count > command.max_toggle_modes) {
        return .usage;
    }

    var noise_command = command.NoiseControl{
        .action = action,
        .toggle_mode_count = toggle_mode_count,
    };
    for (positional[1..positional_count], 0..) |value, mode_index| {
        noise_command.toggle_modes[mode_index] = noise_control.Mode.parse(value) orelse return .usage;

        // Duplicate entries make a cycle position ambiguous and provide no useful behavior.
        for (noise_command.toggle_modes[0..mode_index]) |previous| {
            if (previous == noise_command.toggle_modes[mode_index]) return .usage;
        }
    }
    return .{ .execute = .{
        .requested_address = requested_address,
        .backend = backend,
        .operation = .{ .noise_control = noise_command },
    } };
}
