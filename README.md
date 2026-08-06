# airpodsctl

`airpodsctl` is a small Linux command-line utility for reading settings and state from connected AirPods and changing supported settings. Commands are one-shot by default, while an optional foreground session service can retain the AACP Bluetooth connection for faster subsequent operations. The service can also provide opt-in, wear-aware MPRIS media control and experimental multipoint audio switching. There is no tray application, BLE proximity scanner, audio-profile automation, or network listener.

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
$ airpodsctl wear-status
primary in-ear
secondary out-of-ear
$ airpodsctl switching status
multipoint ready
hosts local-and-remote
owner remote
remote-activity idle
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

Add `-v` or `--verbose` to log causal, human-readable operational diagnostics to standard error without changing normal command output:

```console
$ airpodsctl -v --direct status
airpodsctl: INFO   Running 'status' because it was requested on the command line.
airpodsctl: INFO   Using a direct Bluetooth connection because --direct bypasses the session service.
airpodsctl: INFO   Looking for connected AirPods because the operation is using a direct Bluetooth connection.
airpodsctl: INFO   The AirPods control session is ready because its handshake and notification subscription completed.
noise-cancellation
```

Logging levels control the amount of detail:

- The default `warn` level reports recoverable failures and terminal errors.
- `-v` or `--verbose` enables `info` lifecycle, state-transition, and policy-action messages.
- `-vv` also enables `debug` protocol stages, policy inputs, safety invariants, and reasons for taking or suppressing an action.
- `--log-level=error|warn|info|debug` selects a level explicitly and cannot be combined with `-v`.

Every diagnostic includes why the event occurred or why the action was chosen. For example, pause-on-removal logs the previous and current in-ear counts, the configured threshold, and whether airpodsctl owns confirmed MPRIS pause transitions. Info and debug diagnostics remain identifier-free: they do not contain Bluetooth addresses, device or player names, D-Bus identities, socket paths, or raw protocol packets. A terminal error may repeat a user-supplied address when that value is the reason validation or service-device matching failed.

Only the level label is colored. `--color=auto` is the default and enables ANSI colors only when standard error is an interactive terminal, `TERM` is not `dumb`, and `NO_COLOR` is unset or empty. Use `--color=always` or `--color=never` to override that behavior. Redirected output and journald therefore remain plain text by default.

Logging configuration is process-local. A verbose client explains its own session request, but an already-running service reports internal connection, wear, routing, and media-policy decisions only when that service was started with `-v`, `-vv`, or an explicit `--log-level`.

Automatic fallback occurs only when the session socket is absent or has no listener. Errors returned by a running service are reported directly instead of opening a second AACP connection.

Multipoint ownership changes require the service because it confirms the AirPods acknowledgement and retains the 30-second idle-release timer:

```console
$ airpodsctl switching take
multipoint ready
hosts local-and-remote
owner linux
remote-activity idle
$ airpodsctl switching release
multipoint ready
hosts local-and-remote
owner remote
remote-activity idle
```

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
- `wear-status`: print the most recent primary and secondary AACP wear states. These labels describe protocol roles, not permanent left/right identity. A state is `in-ear`, `out-of-ear`, `in-case`, or `unknown`.
- `switching status`: request connected-host, ownership, and remote-activity state. `multipoint ready` means two hosts and all required runtime fields were observed; `unverified` can also mean the second host is absent rather than misconfigured.
- `switching take [--force]`: ask the AirPods to route ownership to Linux. A normal take requires confirmed idle remote activity. `--force` can interrupt iPhone media or a call and should be used only as an intentional override.
- `switching release`: yield ownership without disconnecting either Bluetooth host or changing a BlueZ audio profile.
- `serve`: run the persistent foreground session service. `--device MAC` selects which AirPods the service owns. Add `--pause-on-removal=one` or `--pause-on-removal=both` to enable wear-aware MPRIS control, or `--auto-switch=mpris` to enable automatic multipoint takeover; both policies default to `off`.

Wear notifications and host media automation are reverse-engineered and have automated protocol coverage but have not completed the hardware acceptance matrix in [the implementation plan](plans/pause-on-removal.md). `wear-status` therefore remains provisional and fails when the AirPods do not provide a wear snapshot.

The explicitly configured `--pause-on-removal` policy is the only ear-detection automation exposed by airpodsctl and operates directly from AACP wear notifications. Its first valid wear snapshot establishes a baseline and never changes playback. A qualifying removal pauses every bounded MPRIS player reporting `Playing` and supporting pause, regardless of the current PipeWire default sink. Only players whose transition to `Paused` was confirmed and whose D-Bus owner remains unchanged are eligible for automatic resume. Players already paused are never resumed. While the policy is enabled, the service retries a lost AACP control session with bounded exponential backoff so automation can recover without a client command.

## Experimental multipoint switching

AirPods multipoint requires the Linux Bluetooth Device ID to identify as Apple. LibrePods documents the following BlueZ setting:

```ini
[General]
DeviceID = bluetooth:004C:0000:0000
```

Apply it through the distribution's BlueZ configuration, restart Bluetooth, then forget and re-pair the AirPods if the new Device ID is not applied to the existing pairing. This changes the host identity advertised by BlueZ and should be used at your own risk. `airpodsctl` never edits this configuration, requests root, pairs devices, or initiates their normal Bluetooth connection. It reports `multipoint unverified` until two connected hosts and the required routing state are observed at runtime.

Connect the same AirPods pair to Linux and the iPhone, then enable automatic switching with:

```console
$ airpodsctl serve --auto-switch=mpris
```

The first MPRIS snapshot is only a baseline and never takes the AirPods. A later player transition to `Playing` requests ownership only when the iPhone is confirmed idle and PipeWire identifies the AirPods as Linux's exact default A2DP sink. Active or unknown remote state, another output, an unknown route, or a failed earlier attempt blocks the takeover. If the iPhone takes the route while Linux remains playing, airpodsctl waits until all tracked players stop and a new play edge occurs instead of fighting the iPhone.

After any successful take, including an explicit command, ownership is retained while at least one tracked player is playing. It is released after all players have been idle for 30 seconds; playback during that interval cancels the deadline. Losing MPRIS monitoring starts the same fail-safe release timer. A service restart does not infer ownership provenance and takes no action from its initial state.

The packet layouts have automated parser, state-machine, controller, IPC, and MPRIS coverage, but have not completed the hardware acceptance matrix in [the implementation plan](plans/auto-switching.md). Multipoint commands and automation are therefore experimental on the currently targeted AirPods Pro 2 USB-C. Unknown protocol values always suppress an automatic takeover.

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

The unit runs `airpodsctl serve` in the foreground and restarts it after unexpected process failures. A temporary AirPods disconnection does not terminate the service: it keeps the local socket available. With an automatic host policy enabled, it proactively retries the control session; otherwise, a later command reconnects on demand.

The installed unit keeps both media policies disabled. Enable either or both with a user override that replaces `ExecStart`, for example:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/env airpodsctl serve --pause-on-removal=one --auto-switch=mpris
```

Run `systemctl --user daemon-reload` and restart the unit after changing the override.

Append `-v` for operational logs or `--log-level=debug` for full decision diagnostics, then follow them with `journalctl --user -u airpodsctl.service -f`. The installed unit emits only warnings and errors by default, and automatic color detection keeps journal entries free of ANSI escapes.

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

The utility asks BlueZ for already-connected AirPods over the system D-Bus, then opens Apple's AACP L2CAP PSM `0x1001`. A shared session layer performs the handshake and notification subscription; independent feature modules then parse or send only the packets they own. A central controller is the sole AACP reader and routes every notification into connection-scoped state and typed events, preventing one feature from consuming another feature's events. Generic control-command framing is shared by listening mode and multipoint ownership.

Persistent clients communicate through a versioned `SOCK_SEQPACKET` Unix socket at `$XDG_RUNTIME_DIR/airpodsctl.sock`. Version 1 remains in use for listening-mode and battery operations, version 2 for wear status, and version 3 for typed multipoint status and ownership operations. The socket is created with mode `0600`, accepted peers must have the service's user ID, messages are bounded, and clients can request only typed operations implemented by the program—not arbitrary AACP packets. The service safely replaces an owner-matched stale socket but never removes an unexpected file at that path. It does not expose a network listener.

The utility does not pair devices, initiate a normal Bluetooth connection, scan for BLE proximity advertisements, run with elevated privileges, change the default audio sink, or expose an AirPods ear-detection preference. Multipoint ownership changes stay on the existing AACP connection and never call BlueZ connect, disconnect, or profile-changing methods. Case battery will not be inferred from AACP placeholder records.

Each invocation has a three-second overall deadline. A listening-mode change is successful only when the AirPods send a newer notification containing the requested value. Media discovery is bounded to 16 MPRIS services, and individual D-Bus calls have fixed deadlines so an unresponsive player does not invalidate the AirPods connection.

Protocol behavior was independently implemented from observed AACP traffic and cross-checked against the reverse-engineering work in [LibrePods](https://github.com/kavishdevar/librepods) and [MagicPodsCore](https://github.com/steam3d/MagicPodsCore).

## License

MIT
