const std = @import("std");

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const version = builder.option([]const u8, "version", "program version") orelse "0.5.0";
    const dbus_session_config = builder.option(
        []const u8,
        "dbus-session-config",
        "session bus configuration used by isolated MPRIS tests",
    );
    const options = builder.addOptions();
    options.addOption([]const u8, "version", version);

    // Share one module graph between the executable and feature tests.
    const support_module = builder.createModule(.{
        .root_source_file = builder.path("src/support.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_module = builder.createModule(.{
        .root_source_file = builder.path("src/transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    transport_module.addImport("support", support_module);

    const aacp_module = builder.createModule(.{
        .root_source_file = builder.path("src/aacp.zig"),
        .target = target,
        .optimize = optimize,
    });
    aacp_module.addImport("support", support_module);
    aacp_module.addImport("transport", transport_module);

    const battery_module = builder.createModule(.{
        .root_source_file = builder.path("src/battery.zig"),
        .target = target,
        .optimize = optimize,
    });

    const noise_control_module = builder.createModule(.{
        .root_source_file = builder.path("src/noise_control.zig"),
        .target = target,
        .optimize = optimize,
    });
    noise_control_module.addImport("aacp", aacp_module);

    const control_command_module = builder.createModule(.{
        .root_source_file = builder.path("src/control_command.zig"),
        .target = target,
        .optimize = optimize,
    });
    noise_control_module.addImport("control_command", control_command_module);

    const ear_detection_module = builder.createModule(.{
        .root_source_file = builder.path("src/ear_detection.zig"),
        .target = target,
        .optimize = optimize,
    });
    ear_detection_module.addImport("aacp", aacp_module);
    ear_detection_module.addImport("control_command", control_command_module);

    const smart_routing_module = builder.createModule(.{
        .root_source_file = builder.path("src/smart_routing.zig"),
        .target = target,
        .optimize = optimize,
    });
    smart_routing_module.addImport("aacp", aacp_module);
    smart_routing_module.addImport("control_command", control_command_module);

    const switching_policy_module = builder.createModule(.{
        .root_source_file = builder.path("src/switching_policy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const command_module = builder.createModule(.{
        .root_source_file = builder.path("src/command.zig"),
        .target = target,
        .optimize = optimize,
    });
    command_module.addImport("battery", battery_module);
    command_module.addImport("ear_detection", ear_detection_module);
    command_module.addImport("noise_control", noise_control_module);
    command_module.addImport("smart_routing", smart_routing_module);

    const controller_module = builder.createModule(.{
        .root_source_file = builder.path("src/controller.zig"),
        .target = target,
        .optimize = optimize,
    });
    controller_module.addImport("aacp", aacp_module);
    controller_module.addImport("battery", battery_module);
    controller_module.addImport("command", command_module);
    controller_module.addImport("control_command", control_command_module);
    controller_module.addImport("ear_detection", ear_detection_module);
    controller_module.addImport("noise_control", noise_control_module);
    controller_module.addImport("smart_routing", smart_routing_module);

    const cli_module = builder.createModule(.{
        .root_source_file = builder.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("battery", battery_module);
    cli_module.addImport("command", command_module);
    cli_module.addImport("ear_detection", ear_detection_module);
    cli_module.addImport("noise_control", noise_control_module);
    cli_module.addImport("switching_policy", switching_policy_module);

    const bluez_module = builder.createModule(.{
        .root_source_file = builder.path("src/bluez.zig"),
        .target = target,
        .optimize = optimize,
    });
    bluez_module.addImport("support", support_module);
    bluez_module.addImport("transport", transport_module);

    const wear_policy_module = builder.createModule(.{
        .root_source_file = builder.path("src/wear_policy.zig"),
        .target = target,
        .optimize = optimize,
    });
    wear_policy_module.addImport("command", command_module);
    wear_policy_module.addImport("ear_detection", ear_detection_module);

    const media_module = builder.createModule(.{
        .root_source_file = builder.path("src/media.zig"),
        .target = target,
        .optimize = optimize,
    });
    media_module.addImport("support", support_module);
    media_module.addImport("transport", transport_module);
    media_module.linkSystemLibrary("libsystemd", .{});

    const pipewire_route_module = builder.createModule(.{
        .root_source_file = builder.path("src/pipewire_route.zig"),
        .target = target,
        .optimize = optimize,
    });
    pipewire_route_module.addIncludePath(builder.path("src"));
    pipewire_route_module.addCSourceFile(.{
        .file = builder.path("src/pipewire_route_shim.c"),
        .flags = &.{ "-Wall", "-Wextra", "-Werror" },
    });
    pipewire_route_module.linkSystemLibrary("pipewire-0.3", .{});

    const app_module = builder.createModule(.{
        .root_source_file = builder.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addImport("aacp", aacp_module);
    app_module.addImport("bluez", bluez_module);
    app_module.addImport("cli", cli_module);
    app_module.addImport("command", command_module);
    app_module.addImport("controller", controller_module);
    app_module.addImport("support", support_module);
    app_module.addImport("transport", transport_module);

    const ipc_module = builder.createModule(.{
        .root_source_file = builder.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_module.addImport("battery", battery_module);
    ipc_module.addImport("cli", cli_module);
    ipc_module.addImport("command", command_module);
    ipc_module.addImport("ear_detection", ear_detection_module);
    ipc_module.addImport("noise_control", noise_control_module);
    ipc_module.addImport("smart_routing", smart_routing_module);
    ipc_module.addImport("support", support_module);
    ipc_module.addImport("transport", transport_module);

    const server_module = builder.createModule(.{
        .root_source_file = builder.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_module.addImport("aacp", aacp_module);
    server_module.addImport("bluez", bluez_module);
    server_module.addImport("cli", cli_module);
    server_module.addImport("controller", controller_module);
    server_module.addImport("ipc", ipc_module);
    server_module.addImport("media", media_module);
    server_module.addImport("pipewire_route", pipewire_route_module);
    server_module.addImport("support", support_module);
    server_module.addImport("switching_policy", switching_policy_module);
    server_module.addImport("transport", transport_module);
    server_module.addImport("wear_policy", wear_policy_module);

    // Build and install the Linux command-line executable.
    const executable_module = builder.createModule(.{
        .root_source_file = builder.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    executable_module.addOptions("build_options", options);
    executable_module.addImport("app", app_module);
    executable_module.addImport("battery", battery_module);
    executable_module.addImport("cli", cli_module);
    executable_module.addImport("command", command_module);
    executable_module.addImport("ear_detection", ear_detection_module);
    executable_module.addImport("ipc", ipc_module);
    executable_module.addImport("server", server_module);
    executable_module.addImport("support", support_module);
    executable_module.link_libc = true;
    executable_module.linkSystemLibrary("bluetooth", .{});
    executable_module.linkSystemLibrary("libsystemd", .{});
    executable_module.linkSystemLibrary("pipewire-0.3", .{});

    const executable = builder.addExecutable(.{
        .name = "airpodsctl",
        .root_module = executable_module,
    });
    builder.installArtifact(executable);
    builder.installFile("contrib/airpodsctl.service", "share/systemd/user/airpodsctl.service");

    // Run packet and feature tests against an emulated AirPods peer.
    const test_module = builder.createModule(.{
        .root_source_file = builder.path("tests/test_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("aacp", aacp_module);
    test_module.addImport("battery", battery_module);
    test_module.addImport("cli", cli_module);
    test_module.addImport("command", command_module);
    test_module.addImport("control_command", control_command_module);
    test_module.addImport("controller", controller_module);
    test_module.addImport("ear_detection", ear_detection_module);
    test_module.addImport("ipc", ipc_module);
    test_module.addImport("noise_control", noise_control_module);
    test_module.addImport("pipewire_route", pipewire_route_module);
    test_module.addImport("smart_routing", smart_routing_module);
    test_module.addImport("support", support_module);
    test_module.addImport("switching_policy", switching_policy_module);
    test_module.addImport("transport", transport_module);
    test_module.addImport("wear_policy", wear_policy_module);
    test_module.link_libc = true;
    const tests = builder.addTest(.{ .root_module = test_module });
    const run_tests = builder.addRunArtifact(tests);

    const media_test_module = builder.createModule(.{
        .root_source_file = builder.path("tests/test_media.zig"),
        .target = target,
        .optimize = optimize,
    });
    media_test_module.addImport("media", media_module);
    media_test_module.addIncludePath(builder.path("tests"));
    media_test_module.addCSourceFile(.{
        .file = builder.path("tests/fake_mpris.c"),
        .flags = &.{ "-Wall", "-Wextra", "-Werror" },
    });
    media_test_module.linkSystemLibrary("libsystemd", .{});
    media_test_module.linkSystemLibrary("pthread", .{});
    media_test_module.link_libc = true;
    const media_tests = builder.addTest(.{ .root_module = media_test_module });
    const run_media_tests = if (dbus_session_config) |config|
        builder.addSystemCommand(&.{
            "dbus-run-session",
            builder.fmt("--config-file={s}", .{config}),
            "--",
        })
    else
        builder.addSystemCommand(&.{ "dbus-run-session", "--" });
    run_media_tests.addArtifactArg(media_tests);

    // Exercise non-Bluetooth CLI paths and preserve documented exit statuses.
    const help_check = builder.addRunArtifact(executable);
    help_check.addArg("--help");
    help_check.expectStdOutMatch("Usage: airpodsctl");

    const version_check = builder.addRunArtifact(executable);
    version_check.addArg("--version");
    version_check.expectStdOutEqual(builder.fmt("airpodsctl {s}\n", .{version}));

    const invalid_arguments = [_][]const []const u8{
        &.{"invalid"},
        &.{ "status", "off" },
        &.{ "toggle", "invalid" },
        &.{ "toggle", "anc", "anc" },
        &.{ "battery", "invalid" },
        &.{ "battery", "case" },
        &.{ "battery", "left", "right" },
        &.{"automatic-ear-detection"},
        &.{ "automatic-ear-detection", "invalid" },
        &.{ "automatic-ear-detection", "status", "on" },
        &.{ "wear-status", "extra" },
        &.{"switching"},
        &.{ "switching", "invalid" },
        &.{ "switching", "status", "extra" },
        &.{ "switching", "status", "--force" },
        &.{ "switching", "release", "--force" },
        &.{ "--direct", "switching", "take" },
        &.{ "status", "--pause-on-removal=one" },
        &.{ "serve", "--pause-on-removal=invalid" },
        &.{ "serve", "--pause-on-removal=one", "--pause-on-removal=both" },
        &.{ "serve", "--auto-switch=invalid" },
        &.{ "serve", "--auto-switch=mpris", "--auto-switch=off" },
        &.{ "status", "--auto-switch=mpris" },
        &.{ "--session", "--direct", "status" },
        &.{ "--session", "serve" },
        &.{ "--direct", "serve" },
        &.{ "serve", "status" },
    };

    const check_step = builder.step("check", "Run tests and command-line checks");
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&run_media_tests.step);
    check_step.dependOn(&help_check.step);
    check_step.dependOn(&version_check.step);
    for (invalid_arguments) |arguments| {
        const invalid_check = builder.addRunArtifact(executable);
        invalid_check.addArgs(arguments);
        invalid_check.expectExitCode(2);
        invalid_check.expectStdErrMatch("Usage: airpodsctl");
        check_step.dependOn(&invalid_check.step);
    }
}
