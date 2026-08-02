const std = @import("std");
const app = @import("app");
const battery = @import("battery");
const build_options = @import("build_options");
const cli = @import("cli");
const ear_detection = @import("ear_detection");
const ipc = @import("ipc");
const operations = @import("command");
const server = @import("server");
const support = @import("support");

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
    writeAll(support.c.STDERR_FILENO, "airpodsctl: ");
    writeAll(support.c.STDERR_FILENO, failure.text());
    writeAll(support.c.STDERR_FILENO, "\n");
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

fn writeWearLine(label: []const u8, state: ear_detection.WearState) void {
    writeAll(support.c.STDOUT_FILENO, label);
    writeAll(support.c.STDOUT_FILENO, " ");
    writeAll(support.c.STDOUT_FILENO, state.name());
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
        .automatic_ear_detection => |setting| {
            writeAll(support.c.STDOUT_FILENO, setting.name());
            writeAll(support.c.STDOUT_FILENO, "\n");
        },
        .wear_status => |report| {
            writeWearLine("primary", report.primary);
            writeWearLine("secondary", report.secondary);
        },
    }
}

fn execute(command: cli.Command) u8 {
    var failure = support.ErrorMessage{};
    writeResult(switch (command.backend) {
        .direct => app.run(command, &failure),
        .session => ipc.request(command, &failure),
        .automatic => ipc.request(command, &failure) catch |request_failure| switch (request_failure) {
            error.Unavailable => app.run(command, &failure),
            else => request_failure,
        },
    } catch {
        writeFailure(&failure);
        return 1;
    });

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
