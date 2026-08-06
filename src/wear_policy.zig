const command = @import("command");
const wear_detection = @import("wear_detection");

pub const Decision = enum {
    none,
    pause_media,
    resume_media,
};

pub const Reason = enum {
    disabled,
    incomplete_state,
    baseline,
    unchanged,
    pause_threshold,
    resume_threshold,
    resume_not_owned,
    transition_irrelevant,
};

pub const Evaluation = struct {
    decision: Decision,
    reason: Reason,
    previous_count: ?u8,
    current_count: ?u8,
};

pub const Policy = struct {
    mode: command.PauseOnRemoval,
    previous_count: ?u8 = null,

    pub fn reset(self: *Policy) void {
        self.previous_count = null;
    }

    pub fn evaluateWear(self: *Policy, report: wear_detection.WearReport, owns_media: bool) Evaluation {
        const previous_count = self.previous_count;
        if (self.mode == .off) return .{
            .decision = .none,
            .reason = .disabled,
            .previous_count = previous_count,
            .current_count = report.inEarCount(),
        };
        const new_count = report.inEarCount() orelse {
            // Do not infer a transition across a period containing an unknown earbud state.
            self.previous_count = null;
            return .{
                .decision = .none,
                .reason = .incomplete_state,
                .previous_count = previous_count,
                .current_count = null,
            };
        };
        const known_previous = previous_count orelse {
            self.previous_count = new_count;
            return .{
                .decision = .none,
                .reason = .baseline,
                .previous_count = null,
                .current_count = new_count,
            };
        };
        self.previous_count = new_count;
        if (known_previous == new_count) return .{
            .decision = .none,
            .reason = .unchanged,
            .previous_count = known_previous,
            .current_count = new_count,
        };

        return switch (self.mode) {
            .off => unreachable,
            .one => if (known_previous == 2 and new_count < 2)
                .{
                    .decision = .pause_media,
                    .reason = .pause_threshold,
                    .previous_count = known_previous,
                    .current_count = new_count,
                }
            else if (known_previous < 2 and new_count == 2)
                .{
                    .decision = if (owns_media) .resume_media else .none,
                    .reason = if (owns_media) .resume_threshold else .resume_not_owned,
                    .previous_count = known_previous,
                    .current_count = new_count,
                }
            else
                .{
                    .decision = .none,
                    .reason = .transition_irrelevant,
                    .previous_count = known_previous,
                    .current_count = new_count,
                },
            .both => if (known_previous > 0 and new_count == 0)
                .{
                    .decision = .pause_media,
                    .reason = .pause_threshold,
                    .previous_count = known_previous,
                    .current_count = new_count,
                }
            else if (known_previous == 0 and new_count > 0)
                .{
                    .decision = if (owns_media) .resume_media else .none,
                    .reason = if (owns_media) .resume_threshold else .resume_not_owned,
                    .previous_count = known_previous,
                    .current_count = new_count,
                }
            else
                .{
                    .decision = .none,
                    .reason = .transition_irrelevant,
                    .previous_count = known_previous,
                    .current_count = new_count,
                },
        };
    }

    pub fn updateWear(self: *Policy, report: wear_detection.WearReport, owns_media: bool) Decision {
        return self.evaluateWear(report, owns_media).decision;
    }
};
