pub const Mode = enum {
    off,
    mpris,
};

pub const Action = enum {
    none,
    take,
    release,
};

pub const Eligibility = struct {
    route_selected: bool,
    multipoint_ready: bool,
    remote_idle: bool,

    pub fn allowsTake(self: Eligibility) bool {
        return self.route_selected and self.multipoint_ready and self.remote_idle;
    }
};

pub const Policy = struct {
    mode: Mode,
    initialized: bool = false,
    playing: bool = false,
    suppressed: bool = false,
    operation_pending: bool = false,
    service_owns: bool = false,
    release_at_ms: ?i64 = null,

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
            return .none;
        }

        self.playing = playing;
        if (playing) {
            self.release_at_ms = null;
        } else {
            self.suppressed = false;
            if (self.service_owns and self.release_at_ms == null) self.armRelease(now_ms);
        }
        if (self.mode != .mpris or !play_edge or self.suppressed or self.operation_pending or
            self.service_owns or !eligibility.allowsTake())
        {
            return .none;
        }

        self.operation_pending = true;
        return .take;
    }

    pub fn takeSucceeded(self: *Policy, now_ms: i64) void {
        self.operation_pending = false;
        self.service_owns = true;
        self.suppressed = false;
        self.release_at_ms = null;
        if (!self.playing) self.armRelease(now_ms);
    }

    pub fn releaseSucceeded(self: *Policy) void {
        self.operation_pending = false;
        self.service_owns = false;
        self.release_at_ms = null;
        self.suppressed = self.playing;
    }

    pub fn operationFailed(self: *Policy) void {
        self.operation_pending = false;
        self.suppressed = self.playing;
    }

    pub fn remoteTakeover(self: *Policy) void {
        self.operation_pending = false;
        self.service_owns = false;
        self.release_at_ms = null;
        self.suppressed = self.playing;
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
