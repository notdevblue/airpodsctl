# airpodsctl

`airpodsctl` is a small Linux command-line utility for reading settings and state from connected AirPods and changing supported settings. Commands are one-shot by default, while an optional foreground session service can retain the AACP Bluetooth connection for faster subsequent operations. The service can also provide opt-in, wear-aware MPRIS media control. There is no tray application, BLE proximity scanner, audio-profile automation, or network listener.

The utility is currently tested with AirPods Pro 2 with USB-C. Other AirPods models that expose the same AACP listening-mode and battery-report protocols may work, but Apple does not publish these protocols and firmware updates can change them.

## Usage

Connect the AirPods through BlueZ, then run:

```console
$ airpodsctl status
noise-cancellation
$ airpodsctl off
off
$ airpodsctl anc
noise-cancellation
$ airpodsctl transparency
transparency
$ airpodsctl adaptive
adaptive
$ airpodsctl toggle
off
$ airpodsctl toggle off transparency adaptive
transparency
$ airpodsctl battery
left 99 charging
right 100 discharging
$ airpodsctl battery left
99
$ airpodsctl automatic-ear-detection status
on
$ airpodsctl automatic-ear-detection off
off
$ airpodsctl wear-status
primary in-ear
secondary out-of-ear
```

Commands automatically use a running session service when one is available. Start it in a dedicated terminal to avoid repeating Bluetooth discovery and AACP initialization:

```console
$ airpodsctl serve
```

The service remains in the foreground until interrupted. It keeps one connection to the selected AirPods, consumes notifications continuously, and caches current state, so subsequent commands are normally answered without another handshake. If no service is listening, ordinary commands retain the original one-shot behavior.

Use `--session` when a command must use the service, or `--direct` to bypass it explicitly:

```console
$ airpodsctl --session battery left
99
$ airpodsctl --direct status
noise-cancellation
```

Automatic fallback occurs only when the session socket is absent or has no listener. Errors returned by a running service are reported directly instead of opening a second AACP connection.

The earbuds must be detected in-ear before AirPods will accept a listening-mode change.

The available commands are:

- `status`: print the current mode without changing it.
- `anc`: enable active noise cancellation.
- `off`: disable listening-mode processing.
- `transparency`: pass surrounding sound through the earbuds.
- `adaptive`: automatically adjust noise control for the surroundings.
- `toggle [MODE...]`: cycle through the supplied modes in order, wrapping from the last mode to the first. If the current mode is not listed, the first supplied mode is selected. Supported mode arguments are `anc`, `off`, `transparency`, and `adaptive`, and each may be listed once. With one mode, `toggle` always selects it; with no modes, it retains the default ANC/Off cycle.
- `battery`: print the left and right earbud battery levels and charging states. An earbud that is not present in the report is printed as `unavailable`.
- `battery left|right`: print only the selected earbud's battery percentage. The command waits for a report containing that earbud and fails if the AirPods do not provide one before the overall deadline.
- `automatic-ear-detection status|on|off`: read or change the AirPods' Automatic Ear Detection preference. Changes succeed only after a newer matching device notification; a successful Bluetooth write alone is not treated as confirmation.
- `wear-status`: print the most recent primary and secondary AACP wear states. These labels describe protocol roles, not permanent left/right identity. A state is `in-ear`, `out-of-ear`, `in-case`, or `unknown`.
- `serve`: run the persistent foreground session service. `--device MAC` selects which AirPods the service owns. Add `--pause-on-removal=one` or `--pause-on-removal=both` to enable wear-aware MPRIS control; the default is `off`.

Automatic Ear Detection and wear notifications are reverse-engineered and have automated protocol coverage but have not completed the hardware acceptance matrix in [the implementation plan](plans/automatic-ear-detection.md). Commands therefore remain provisional and fail if the AirPods do not provide a confirmed setting or wear snapshot.

Wear-aware media control requires PipeWire/WirePlumber. It acts only when PipeWire identifies the selected AirPods address as the exact default A2DP audio sink. Unknown routing, virtual default sinks, another output, a PipeWire restart, or a disabled/unknown Automatic Ear Detection setting suppresses all media actions. On removal, every bounded MPRIS player reporting `Playing` and supporting pause is paused. Only players whose transition to `Paused` was confirmed and whose D-Bus owner remains unchanged are eligible for automatic resume. Players already paused are never resumed.

Case battery reporting is deprecated and `battery case` is invalid usage. AACP reports the case as `0 disconnected` when it cannot relay a case reading, so presenting that record as a percentage is misleading. Accurate case state requires Apple BLE proximity advertisements, which are deliberately outside the current program scope. The requirements for reconsidering that feature are recorded in [plans/ble-advertisments.md](plans/ble-advertisments.md).

The sole connected AirPods device is selected automatically. When more than one pair is connected, select one explicitly:

```console
$ airpodsctl --device 18:3F:70:6F:A1:06 toggle
```

Successful listening-mode commands print the mode confirmed by the AirPods. A component-specific battery command prints an integer percentage, while the aggregate command prints stable, space-delimited `component level state` lines. Charging state is one of `unknown`, `charging`, `discharging`, or `disconnected`. Successful commands exit with status `0`; discovery, Bluetooth, timeout, malformed-response, and acknowledgement failures use status `1`; invalid command-line usage uses status `2`.

## Persistent user service

The installed package includes `share/systemd/user/airpodsctl.service`. Copy or link it into the user unit search path if the package manager does not do so automatically, then enable it with:

```console
$ systemctl --user daemon-reload
$ systemctl --user enable --now airpodsctl.service
```

The unit runs `airpodsctl serve` in the foreground and restarts it after unexpected process failures. A temporary AirPods disconnection does not terminate the service: it keeps the local socket available and reconnects when a later command needs the device.

The installed unit keeps media automation disabled. Enable it with a user override that replaces `ExecStart`, for example:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/env airpodsctl serve --pause-on-removal=one
```

Run `systemctl --user daemon-reload` and restart the unit after changing the override.

AirPods Pro 2 may reject the Off command until **Off Listening Mode** has been enabled once from a compatible iPhone, iPad, or Mac. Turning listening modes off also disables the AirPods' hearing-protection processing.

## Build

The build requires Zig 0.16, `pkg-config`, BlueZ, PipeWire, `libsystemd`, and `dbus-run-session` for the isolated MPRIS test:

```console
$ zig build check
$ zig build -Doptimize=ReleaseSafe
$ sudo zig build install -Doptimize=ReleaseSafe --prefix /usr/local
```

With Nix, the repository provides a development shell and a default package:

```console
$ nix develop
$ zig build check
$ nix run . -- status
```

## Design and security

The utility asks BlueZ for already-connected AirPods over the system D-Bus, then opens Apple's AACP L2CAP PSM `0x1001`. A shared session layer performs the handshake and notification subscription; independent feature modules then parse or send only the packets they own. A central controller is the sole AACP reader and routes every notification into connection-scoped state and typed events, preventing one feature from consuming another feature's events. Generic control-command framing is shared by listening mode and Automatic Ear Detection.

Persistent clients communicate through a versioned `SOCK_SEQPACKET` Unix socket at `$XDG_RUNTIME_DIR/airpodsctl.sock`. Version 1 remains in use for listening-mode and battery operations; version 2 adds Automatic Ear Detection and wear status. The socket is created with mode `0600`, accepted peers must have the service's user ID, messages are bounded, and clients can request only typed operations implemented by the program—not arbitrary AACP packets. The service safely replaces an owner-matched stale socket but never removes an unexpected file at that path. It does not expose a network listener.

The utility does not pair devices, initiate a normal Bluetooth connection, scan for BLE proximity advertisements, run with elevated privileges, or write AirPods configuration except when an explicit setting command requests a change. Case battery will not be inferred from AACP placeholder records.

Each invocation has a three-second overall deadline. A mode or Automatic Ear Detection change is successful only when the AirPods send a newer notification containing the requested value. Media discovery is bounded to 16 MPRIS services, and individual D-Bus calls have fixed deadlines so an unresponsive player does not invalidate the AirPods connection.

Protocol behavior was independently implemented from observed AACP traffic and cross-checked against the reverse-engineering work in [LibrePods](https://github.com/kavishdevar/librepods) and [MagicPodsCore](https://github.com/steam3d/MagicPodsCore).

## License

MIT
