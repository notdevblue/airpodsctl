# airpodsctl

`airpodsctl` is a small Linux command-line utility for reading settings and state from connected AirPods and changing supported settings. It performs one operation over Apple's AACP Bluetooth channel and exits: there is no daemon, tray application, BLE scanner, media integration, or network listener.

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
case 17 discharging
$ airpodsctl battery left
99
```

The earbuds must be detected in-ear before AirPods will accept a listening-mode change.

The available commands are:

- `status`: print the current mode without changing it.
- `anc`: enable active noise cancellation.
- `off`: disable listening-mode processing.
- `transparency`: pass surrounding sound through the earbuds.
- `adaptive`: automatically adjust noise control for the surroundings.
- `toggle [MODE...]`: cycle through the supplied modes in order, wrapping from the last mode to the first. If the current mode is not listed, the first supplied mode is selected. Supported mode arguments are `anc`, `off`, `transparency`, and `adaptive`, and each may be listed once. With one mode, `toggle` always selects it; with no modes, it retains the default ANC/Off cycle.
- `battery`: print the left, right, and case battery levels and charging states. A component that is not present in the report, which is common for a closed case, is printed as `unavailable`.
- `battery left|right|case`: print only the selected component's battery percentage. The command waits for a report containing that component and fails if the AirPods do not provide one before the overall deadline.

The sole connected AirPods device is selected automatically. When more than one pair is connected, select one explicitly:

```console
$ airpodsctl --device 18:3F:70:6F:A1:06 toggle
```

Successful listening-mode commands print the mode confirmed by the AirPods. A component-specific battery command prints an integer percentage, while the aggregate command prints stable, space-delimited `component level state` lines. Charging state is one of `unknown`, `charging`, `discharging`, or `disconnected`. Successful commands exit with status `0`; discovery, Bluetooth, timeout, malformed-response, and acknowledgement failures use status `1`; invalid command-line usage uses status `2`.

AirPods Pro 2 may reject the Off command until **Off Listening Mode** has been enabled once from a compatible iPhone, iPad, or Mac. Turning listening modes off also disables the AirPods' hearing-protection processing.

## Build

The build requires Zig 0.16, `pkg-config`, BlueZ development files, and `libsystemd` development files:

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

The utility asks BlueZ for already-connected AirPods over the system D-Bus, then opens Apple's AACP L2CAP PSM `0x1001`. A shared session layer performs the handshake and notification subscription; independent feature modules then parse or send only the packets they own. Adding a setting does not require changing device discovery or packet transport. The utility does not pair devices, initiate a normal Bluetooth connection, scan for BLE advertisements, run with elevated privileges, write configuration, or listen on any local or network socket.

Each invocation has a three-second overall deadline. A mode-changing command is successful only when the AirPods send a listening-mode notification containing the requested mode.

Protocol behavior was independently implemented from observed AACP traffic and cross-checked against the reverse-engineering work in [LibrePods](https://github.com/kavishdevar/librepods) and [MagicPodsCore](https://github.com/steam3d/MagicPodsCore).

## License

MIT
