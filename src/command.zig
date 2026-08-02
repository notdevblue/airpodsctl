const battery = @import("battery");
const ear_detection = @import("ear_detection");
const noise_control = @import("noise_control");

pub const PauseOnRemoval = enum {
    off,
    one,
    both,
};

pub const max_toggle_modes = 4;

pub const NoiseControl = struct {
    action: noise_control.Action,
    toggle_modes: [max_toggle_modes]noise_control.Mode = undefined,
    toggle_mode_count: usize = 0,
};

pub const Operation = union(enum) {
    noise_control: NoiseControl,
    battery: ?battery.Component,
    automatic_ear_detection: ear_detection.Action,
    wear_status,
};

pub const BatteryResult = struct {
    component: ?battery.Component,
    report: battery.Report,
};

pub const Result = union(enum) {
    mode: noise_control.Mode,
    battery: BatteryResult,
    automatic_ear_detection: ear_detection.Setting,
    wear_status: ear_detection.WearReport,
};
