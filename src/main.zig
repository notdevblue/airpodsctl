const std = @import("std");
const app = @import("app");
const battery = @import("battery");
const build_options = @import("build_options");
const cli = @import("cli");
const ipc = @import("ipc");
const operations = @import("command");
const server = @import("server");
const support = @import("support");
const wear_detection = @import("wear_detection");

fn writeAll(fd: c_int, bytes: []const u8) void {
    var remaining = bytes;

    // Consume partial or interrupted writes; output failures cannot be reported recursively.
    while (remaining.len > 0) {
        const written = support.c.write(fd, remaining.ptr, remaining.len);
        if (written > 0) {
            remaining = remaining[@intCast(written)..];
        } else if (written < 0 and support.lastErrno() == support.c.EINTR) {
            continue;
        } else {
            return;
        }
    }
}

fn writeFailure(failure: *const support.ErrorMessage) void {
    support.log(
        .@"error",
        "The requested operation failed; cause: {s}",
        .{failure.text()},
    );
}

fn writeBatteryLine(component: battery.Component, reading: ?battery.Reading) void {
    var buffer: [64]u8 = undefined;
    writeAll(support.c.STDOUT_FILENO, if (reading) |value|
        std.fmt.bufPrint(
            &buffer,
            "{s} {d} {s}\n",
            .{ component.name(), value.level, value.state.name() },
        ) catch return
    else
        std.fmt.bufPrint(&buffer, "{s} unavailable\n", .{component.name()}) catch return);
}

fn writeWearLine(label: []const u8, state: wear_detection.WearState) void {
    writeAll(support.c.STDOUT_FILENO, label);
    writeAll(support.c.STDOUT_FILENO, " ");
    writeAll(support.c.STDOUT_FILENO, state.name());
    writeAll(support.c.STDOUT_FILENO, "\n");
}

fn writeSwitchingLine(label: []const u8, value: []const u8) void {
    writeAll(support.c.STDOUT_FILENO, label);
    writeAll(support.c.STDOUT_FILENO, " ");
    writeAll(support.c.STDOUT_FILENO, value);
    writeAll(support.c.STDOUT_FILENO, "\n");
}

fn writeResult(result: operations.Result) void {
    switch (result) {
        .mode => |mode| {
            writeAll(support.c.STDOUT_FILENO, mode.name());
            writeAll(support.c.STDOUT_FILENO, "\n");
        },
        .battery => |value| if (value.component) |component| {
            var buffer: [4]u8 = undefined;
            writeAll(
                support.c.STDOUT_FILENO,
                std.fmt.bufPrint(&buffer, "{d}\n", .{value.report.get(component).?.level}) catch return,
            );
        } else {
            writeBatteryLine(.left, value.report.left);
            writeBatteryLine(.right, value.report.right);
        },
        .wear_status => |report| {
            writeWearLine("primary", report.primary);
            writeWearLine("secondary", report.secondary);
        },
        .switching => |status| {
            writeSwitchingLine("multipoint", status.multipointName());
            writeSwitchingLine("hosts", status.hosts.name());
            writeSwitchingLine("owner", status.owner.name());
            writeSwitchingLine("remote-activity", status.remote_activity.name());
        },
    }
}

fn execute(command: cli.Command) u8 {
    support.configureLogging(command.log_level, command.color);
    support.log(
        .info,
        "Running '{s}' because it was requested on the command line.",
        .{command.operation.name()},
    );

    var failure = support.ErrorMessage{};
    const result = switch (command.backend) {
        .direct => operation: {
            support.log(.info, "Using a direct Bluetooth connection because --direct bypasses the session service.", .{});
            break :operation app.run(command, &failure);
        },
        .session => operation: {
            support.log(.info, "Using the session service because --session requires an existing service connection.", .{});
            break :operation ipc.request(command, &failure);
        },
        .automatic => operation: {
            support.log(
                .info,
                "Trying the session service first because the automatic backend prefers its shared AirPods control connection.",
                .{},
            );
            break :operation ipc.request(command, &failure) catch |request_failure| switch (request_failure) {
                error.Unavailable => fallback: {
                    support.log(.info, "Using a direct Bluetooth connection because no session service is available.", .{});
                    break :fallback app.run(command, &failure);
                },
                else => request_failure,
            };
        },
    } catch {
        support.log(.debug, "The '{s}' operation produced no result because its selected backend failed.", .{command.operation.name()});
        writeFailure(&failure);
        return 1;
    };

    support.log(.debug, "The '{s}' operation completed successfully.", .{command.operation.name()});
    writeResult(result);

    return 0;
}

pub fn main(init: std.process.Init) u8 {
    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch {
        var failure = support.ErrorMessage{};
        failure.set("cannot read command-line arguments", .{});
        writeFailure(&failure);
        return 1;
    };

    return switch (cli.parseInvocation(arguments)) {
        .help => result: {
            writeAll(support.c.STDOUT_FILENO, cli.usage);
            break :result 0;
        },
        .version => result: {
            writeAll(support.c.STDOUT_FILENO, "airpodsctl " ++ build_options.version ++ "\n");
            break :result 0;
        },
        .usage => result: {
            writeAll(support.c.STDERR_FILENO, cli.usage);
            break :result 2;
        },
        .serve => |configuration| result: {
            support.configureLogging(configuration.log_level, configuration.color);
            var failure = support.ErrorMessage{};
            server.run(configuration, &failure) catch {
                writeFailure(&failure);
                break :result 1;
            };
            break :result 0;
        },
        .execute => |command| execute(command),
    };
}
