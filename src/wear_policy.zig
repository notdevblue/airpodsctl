const command = @import("command");
const ear_detection = @import("ear_detection");

pub const Decision = enum {
    none,
    pause_media,
    resume_media,
};

pub const Policy = struct {
    mode: command.PauseOnRemoval,
    setting_on: bool = false,
    previous_count: ?u8 = null,

    pub fn reset(self: *Policy) void {
        self.setting_on = false;
        self.previous_count = null;
    }

    pub fn updateSetting(self: *Policy, setting: ear_detection.Setting, snapshot: ?ear_detection.WearReport) void {
        self.setting_on = setting == .on;
        self.previous_count = if (self.setting_on and snapshot != null) snapshot.?.inEarCount() else null;
    }

    pub fn updateWear(self: *Policy, report: ear_detection.WearReport, owns_media: bool) Decision {
        if (!self.setting_on or self.mode == .off) return .none;
        const new_count = report.inEarCount() orelse {
            // Do not infer a transition across a period containing an unknown earbud state.
            self.previous_count = null;
            return .none;
        };
        const previous_count = self.previous_count orelse {
            self.previous_count = new_count;
            return .none;
        };
        self.previous_count = new_count;
        if (previous_count == new_count) return .none;

        return switch (self.mode) {
            .off => .none,
            .one => if (previous_count == 2 and new_count < 2)
                .pause_media
            else if (previous_count < 2 and new_count == 2 and owns_media)
                .resume_media
            else
                .none,
            .both => if (previous_count > 0 and new_count == 0)
                .pause_media
            else if (previous_count == 0 and new_count > 0 and owns_media)
                .resume_media
            else
                .none,
        };
    }
};
