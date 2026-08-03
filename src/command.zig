const battery = @import("battery");
const noise_control = @import("noise_control");
const smart_routing = @import("smart_routing");
const wear_detection = @import("wear_detection");

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

pub const SwitchingAction = enum {
    status,
    take,
    release,
};

pub const Switching = struct {
    action: SwitchingAction,
    force: bool = false,
};

pub const Operation = union(enum) {
    noise_control: NoiseControl,
    battery: ?battery.Component,
    wear_status,
    switching: Switching,
};

pub const BatteryResult = struct {
    component: ?battery.Component,
    report: battery.Report,
};

pub const Result = union(enum) {
    mode: noise_control.Mode,
    battery: BatteryResult,
    wear_status: wear_detection.WearReport,
    switching: smart_routing.Status,
};
