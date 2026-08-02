const std = @import("std");
const media = @import("media");

const c = @cImport({
    @cInclude("fake_mpris.h");
});

fn waitForOwnership(controller: *media.Controller, expected: bool) !void {
    for (0..20) |_| {
        if (controller.hasOwnership() == expected) return;
        var descriptors = [_]std.posix.pollfd{.{
            .fd = controller.fd(),
            .events = controller.events(),
            .revents = 0,
        }};

        _ = try std.posix.poll(&descriptors, 50);
        try controller.dispatch();
    }

    try std.testing.expectEqual(expected, controller.hasOwnership());
}

test "MPRIS ownership pauses and resumes only players changed by the controller" {
    const playing = c.fake_mpris_create("org.mpris.MediaPlayer2.airpodsctl_playing", 1) orelse
        return error.SkipZigTest;
    defer c.fake_mpris_destroy(playing);
    const paused = c.fake_mpris_create("org.mpris.MediaPlayer2.airpodsctl_paused", 0) orelse
        return error.SkipZigTest;
    defer c.fake_mpris_destroy(paused);
    var controller = media.Controller{};
    defer controller.deinit();

    try controller.pausePlayers();
    try std.testing.expect(c.fake_mpris_is_playing(playing) == 0);
    try std.testing.expect(c.fake_mpris_is_playing(paused) == 0);
    try std.testing.expect(controller.hasOwnership());

    try controller.resumePlayers();
    try std.testing.expect(c.fake_mpris_is_playing(playing) != 0);
    try std.testing.expect(c.fake_mpris_is_playing(paused) == 0);
    try std.testing.expect(!controller.hasOwnership());
}

test "MPRIS manual playback cancels automatic resume ownership" {
    const player = c.fake_mpris_create("org.mpris.MediaPlayer2.airpodsctl_override", 1) orelse
        return error.SkipZigTest;
    defer c.fake_mpris_destroy(player);
    var controller = media.Controller{};
    defer controller.deinit();

    try controller.pausePlayers();
    try std.testing.expect(controller.hasOwnership());
    try std.testing.expect(c.fake_mpris_set_playing(player, 1) >= 0);
    try waitForOwnership(&controller, false);

    try controller.resumePlayers();
    try std.testing.expect(c.fake_mpris_is_playing(player) != 0);
}

test "MPRIS player disappearance clears automatic resume ownership" {
    const player = c.fake_mpris_create("org.mpris.MediaPlayer2.airpodsctl_disappear", 1) orelse
        return error.SkipZigTest;
    var player_destroyed = false;
    defer if (!player_destroyed) c.fake_mpris_destroy(player);
    var controller = media.Controller{};
    defer controller.deinit();

    try controller.pausePlayers();
    try std.testing.expect(controller.hasOwnership());
    c.fake_mpris_destroy(player);
    player_destroyed = true;
    try waitForOwnership(&controller, false);
}
