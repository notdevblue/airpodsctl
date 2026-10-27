pub const Mode = enum {
    off,
    mpris,
    mpris_priority,
};

pub const Action = enum {
    none,
    take,
    release,
};

const suppression_idle_ms = 2000;

pub const Eligibility = struct {
    multipoint_ready: bool,
    remote_idle: bool,
    local_streaming: bool = false,

    pub fn allowsTake(self: Eligibility) bool {
        return self.multipoint_ready and self.remote_idle;
    }
};

pub const Policy = struct {
    mode: Mode,
    initialized: bool = false,
    playing: bool = false,
    suppressed: bool = false,
    suppression_idle_at_ms: ?i64 = null,
    operation_pending: bool = false,
    service_owns: bool = false,
    release_at_ms: ?i64 = null,
    priority_armed: bool = false,
    priority_takes: u8 = 0,
    priority_next_take_ms: i64 = 0,
    idle_since_ms: ?i64 = null,

    fn armRelease(self: *Policy, now_ms: i64) void {
        self.release_at_ms = now_ms + 30_000;
    }

    pub fn updatePlayback(
        self: *Policy,
        now_ms: i64,
        playing: bool,
        play_edge: bool,
        eligibility: Eligibility,
    ) Action {
        if (!self.initialized) {
            self.initialized = true;
            self.playing = playing;
            if (playing) {
                self.release_at_ms = null;
            } else if (self.service_owns and self.release_at_ms == null) {
                self.armRelease(now_ms);
            }
            // Only adopt an existing playback baseline after confirming that
            // Linux is already streaming to these AirPods, not another output.
            if (self.mode != .mpris_priority or !eligibility.local_streaming) return .none;
        }

        self.playing = playing;
        if (playing) {
            self.idle_since_ms = null;
            if (self.mode == .mpris_priority and eligibility.local_streaming and !self.suppressed) {
                self.priority_armed = true;
            }
            self.release_at_ms = null;
            self.suppression_idle_at_ms = null;
        } else {
            self.priority_armed = false;
            if (self.idle_since_ms == null) self.idle_since_ms = now_ms;
            if (now_ms - self.idle_since_ms.? >= suppression_idle_ms) self.priority_takes = 0;
            if (self.suppressed) {
                if (self.suppression_idle_at_ms == null) self.suppression_idle_at_ms = now_ms;
                if (now_ms - self.suppression_idle_at_ms.? >= suppression_idle_ms) {
                    self.suppressed = false;
                    self.suppression_idle_at_ms = null;
                }
            }
            if (self.service_owns and self.release_at_ms == null) self.armRelease(now_ms);
        }
        const priority_recovery = self.mode == .mpris_priority and playing and self.priority_armed and
            self.priority_takes < 3 and now_ms >= self.priority_next_take_ms;
        if (self.mode == .off or (!play_edge and !priority_recovery) or self.suppressed or self.operation_pending or
            self.service_owns or !eligibility.allowsTake())
        {
            return .none;
        }

        if (self.mode == .mpris_priority) {
            // Bound retries during uninterrupted playback instead of fighting
            // a remote host indefinitely. A stable pause resets the budget.
            if (self.priority_takes >= 3) return .none;
            self.priority_takes += 1;
            self.priority_next_take_ms = now_ms + 5000;
        }
        self.operation_pending = true;
        return .take;
    }

    pub fn takeSucceeded(self: *Policy, now_ms: i64) void {
        self.operation_pending = false;
        self.service_owns = true;
        if (self.mode == .mpris_priority and self.playing) self.priority_armed = true;
        self.suppressed = false;
        self.suppression_idle_at_ms = null;
        self.release_at_ms = null;
        if (!self.playing) self.armRelease(now_ms);
    }

    pub fn releaseSucceeded(self: *Policy) void {
        self.priority_armed = false;
        self.operation_pending = false;
        self.service_owns = false;
        self.release_at_ms = null;
        self.suppressed = self.playing;
        self.suppression_idle_at_ms = null;
    }

    pub fn operationFailed(self: *Policy) void {
        self.priority_armed = false;
        self.operation_pending = false;
        self.suppressed = self.playing;
        self.suppression_idle_at_ms = null;
    }

    pub fn remoteTakeover(self: *Policy) void {
        const recover = self.mode == .mpris_priority and self.playing and
            self.priority_armed and self.priority_takes < 3;
        self.operation_pending = false;
        self.service_owns = false;
        self.release_at_ms = null;
        self.suppressed = self.playing and !recover;
        self.suppression_idle_at_ms = null;
    }

    pub fn tick(self: *Policy, now_ms: i64) Action {
        if (self.operation_pending or !self.service_owns or
            self.release_at_ms == null or now_ms < self.release_at_ms.?)
        {
            return .none;
        }

        self.operation_pending = true;
        return .release;
    }
};
