# Native AirPods multipoint auto-switching

## Summary

This feature targets one AirPods pair connected simultaneously to a Linux laptop and an iPhone. Switching changes AirPods audio ownership through AACP while preserving both Bluetooth connections. It does not use LibrePods' older Android companion relay and must not disconnect or reconnect either host to simulate handoff.

Implementation is gated on sanitized AirPods Pro 2 USB-C captures. LibrePods documents useful research leads—ownership control identifier `0x06` and routing opcodes `0x000d`, `0x000e`, `0x0010`, `0x0011`, `0x0014`, `0x002d`, and `0x002e`—but not enough field semantics for safe implementation. Packet layouts and acknowledgements must be derived independently for this MIT project rather than copied from GPL code.

The first release proceeds in two stages:

1. Status and explicit take/release commands.
2. Opt-in, MPRIS-triggered automatic switching after the protocol and safety matrix pass.

## Implementation status

The parser, controller state, manual commands, IPC v3, MPRIS policy, reconnect behavior, and automated tests are implemented. Hardware capture and acceptance remain incomplete, so the commands are experimental, automation stays off by default, and a public release must retain the validation gate below.

## Public interface and behavior

Add:

```console
airpodsctl switching status
airpodsctl switching take [--force]
airpodsctl switching release
airpodsctl serve --auto-switch=mpris
```

- Automation defaults to `off`, including in the installed systemd service. Accept `--auto-switch=off|mpris`.
- `switching status` follows existing session-first/direct-fallback behavior and prints stable, line-oriented `multipoint`, `hosts`, `owner`, and `remote-activity` fields.
- `multipoint ready` requires runtime proof that both hosts and the required routing protocol are present. `unverified` does not claim BlueZ is misconfigured; the iPhone may simply be absent.
- Do not print or log the remote device's Bluetooth address.
- `switching take` and `switching release` require a running session service. They must not silently fall back to a direct operation because the service owns acknowledgement handling and the 30-second release timer. Reject `--direct` for these mutations and report clearly when the service is absent.
- A normal `take` succeeds only when multipoint is ready and remote activity is confirmed idle. Remote activity or uncertainty produces an error explaining `--force`.
- `take --force` may interrupt remote media or a call. It bypasses only the remote-activity safety check, not protocol readiness, connection, validation, or acknowledgement requirements.
- `release` yields routing ownership without disconnecting either host or changing a BlueZ profile. It is idempotent when Linux is not the owner.
- A mutation succeeds only after a newer matching routing response or ownership notification. A successful Bluetooth write alone is not confirmation.
- Version IPC as `APC3`/`APR3`, with typed status, take-with-force, and release operations. Mixed client/service versions must report that the service needs restarting.

## Protocol capture and validation

Capture at least two repeatable traces for each of these states: Linux only, both hosts idle, iPhone media playing and paused, iPhone call active, Linux takeover, Linux release, natural iPhone takeover, reconnect, and earbuds entering and leaving the case.

For every candidate packet, document direction, exact length, reserved bytes, address byte order, request/response sequence, and which event proves ownership changed. Validate whether control identifier `0x06` represents audio ownership in this scenario rather than assuming its name is sufficient.

Do not expose routing mutations until captures prove:

- The local host can be distinguished using the L2CAP socket's local adapter address.
- Two connected hosts can be identified without exposing the remote address.
- Remote idle can be reliably distinguished from active or unknown state.
- Take and release have observable acknowledgements.
- Ownership changes do not tear down either Bluetooth connection.

If remote-active safety or ownership acknowledgement cannot be proven, retain research/status parsing only and do not ship take, release, or automation.

### Reference-derived packet surface

The following layouts are protocol research inputs, not completed hardware acceptance. Parsers must preserve unknown metadata and fail closed when a field is not understood.

| Opcode | Direction | Reference-derived payload |
| --- | --- | --- |
| `0x0009` | Both | Fixed control-command frame. Identifier `0x06` carries local ownership as `0x00` or `0x01`; the remaining three value bytes are zero. |
| `0x000d` | Host to AirPods | Empty Audio Source request. |
| `0x000e` | AirPods to host | Six-byte Bluetooth address followed by source state: `0x00` idle, `0x01` call, or `0x02` media. Other states remain unknown. |
| `0x0010`/`0x0011` | Both | Six-byte address, little-endian payload length, one unknown byte, and an opaque OPACK payload. Version 1 does not interpret or emit these messages. |
| `0x0014` | Host to AirPods | Count followed by six-byte addresses forming a connection-priority list. Version 1 does not change this list. |
| `0x002d` | Host to AirPods | Empty Connected Devices request. |
| `0x002e` | AirPods to host | Two unknown bytes, device count, then count entries containing a six-byte address and two unknown bytes. Accept at most two entries. |

All packets use the existing `04 00 04 00` AACP prefix and a little-endian 16-bit opcode. Initial implementation compares reported addresses with the local L2CAP address in Bluetooth byte order, but this remains a hardware acceptance item. A routing mutation is provisional until a capture proves that a newer `0x09` ownership notification acknowledges it and that `0x000e` reliably describes the other host's activity.

## Implementation design

### Protocol and controller state

- Add a pure smart-routing module with bounded, exact parsers and encoders for the confirmed ownership, audio-source, smart-routing, local-address, and connected-host packets. Preserve unknown enum values internally and reject malformed known packets without consuming unrelated AACP events.
- Extend the selected connection with the local adapter address obtained through `getsockname`; do not add BlueZ pairing, `Connect`, `Disconnect`, or profile-changing calls.
- Extend the central controller—the sole AACP reader—with connection-scoped routing state, generation counters, and typed routing events.
- Serialize routing mutations with existing commands. Use the existing three-second operation deadline and never retry a failed automatic takeover until another qualifying playback edge.
- When automation is enabled, reconnect the AACP control channel only after BlueZ already reports the AirPods connected. Use bounded exponential retry from one to thirty seconds; never initiate the normal Bluetooth connection.

### MPRIS policy and service integration

Refactor the existing MPRIS controller to track bounded per-player ownership and playback state while preserving wear-aware pause/resume behavior.

Automatic takeover occurs only when all conditions are true:

- `--auto-switch=mpris` is enabled.
- A player newly transitions to `Playing`; a newly appearing player already reporting `Playing` also counts.
- The event is not part of the initial service, MPRIS, or AACP snapshot.
- Multipoint and ownership state are known.
- Remote activity is confirmed idle.
- Automation is not suppressed by a recent explicit release, remote takeover, or failed takeover.

The explicitly enabled MPRIS policy does not inspect the currently selected audio output. A qualifying play edge may therefore request the AirPods while that player's audio is routed elsewhere. Protocol uncertainty or active remote audio blocks automatic takeover. Becoming eligible later while the player remains `Playing` does not trigger retrospectively; another play edge is required.

After any successful service-initiated take—manual or automatic:

- Keep ownership while at least one tracked MPRIS player reports `Playing`.
- Once all players are paused, stopped, gone, or unavailable, arm a monotonic 30-second release deadline.
- Cancel the deadline if playback resumes before it expires.
- Release at expiry and require a later play edge before another automatic take.
- Apply this policy to explicit takes as well as automatic takes.
- If MPRIS monitoring is lost after a take, arm the same fail-safe release deadline.
- If the iPhone takes ownership while Linux still reports `Playing`, treat it as intentional: cancel local ownership state and suppress automatic retaking until all players stop and a later play edge occurs.
- Service startup and reconnection never take or release based solely on the initial snapshot.

MPRIS is the sole desktop playback trigger. Do not add audio-server route monitoring or stream-triggered switching in this version.

### Setup and safety

Document the manual BlueZ prerequisite identified by LibrePods:

```ini
DeviceID = bluetooth:004C:0000:0000
```

It must be applied through the distribution's BlueZ configuration, followed by a Bluetooth service restart and forgetting and re-pairing the AirPods where required. `airpodsctl` must never edit system configuration, request root, or initiate re-pairing. Runtime status reports only whether multipoint was successfully observed.

## Test and acceptance plan

Automated coverage includes:

- Exact packet fixtures for every confirmed routing message, including truncation, oversized payloads, invalid reserved bytes, unknown values, address order, and unrelated interleaved notifications.
- Controller tests proving generation-based acknowledgements, timeout handling, single-reader behavior, reconnect reset, and no duplicate mutations.
- A pure switching-policy matrix covering initial snapshots, normal and forced take, explicit release, active or unknown remote state, multiple MPRIS players, the 30-second timer, failed operations, remote takeover suppression, and MPRIS loss.
- Injected monotonic time so timer tests do not sleep.
- CLI tests for valid forms, misplaced or duplicate `--force`, service-only mutations, and `--auto-switch` validation.
- IPC v3 round trips and clear adjacent-version incompatibility errors.
- Isolated MPRIS tests for existing players, newly appearing players, owner replacement, status invalidation, and preservation of wear-aware pause ownership.
- Existing `zig build check` and release builds after every commit.

Hardware acceptance uses AirPods Pro 2 USB-C and an iPhone, recording AirPods firmware, iPhone model and iOS version, and BlueZ version. Verify that both hosts remain connected across take and release, calls are never taken automatically, startup snapshots cause no action, a qualifying MPRIS edge does not depend on the selected Linux output, idle release waits 30 seconds, and remote takeover is not fought.

## Assumptions and exclusions

- Initial advertised support is AirPods Pro 2 USB-C only; parsers remain model-neutral where verified captures agree.
- Scope is one AirPods pair and at most two connected hosts.
- Excluded: Android companion relays, pairing, BLE scanning, changing the default sink, BlueZ profile automation, disconnect-based handoff, automatic call takeover, iPhone-side software, and system configuration writes.
- Graceful behavior is best effort if the service crashes after taking ownership; a restarted service does not infer ownership provenance or release from its initial snapshot.

## Delivery commits

1. `docs: plan AirPods multipoint auto switching`
2. `docs: record AirPods smart-routing protocol`
3. `feat: add AirPods multipoint routing state`
4. `feat: add manual AirPods switching commands`
5. `feat: add opt-in MPRIS auto switching`
6. `docs: document AirPods multipoint setup and limits`

Each implementation commit includes its own tests and passes `zig build check`.

## Research references

- [LibrePods feature matrix](https://github.com/librepods-org/librepods)
- [LibrePods control commands](https://github.com/librepods-org/librepods/blob/main/docs/control_commands.md)
- [LibrePods opcode index](https://github.com/librepods-org/librepods/blob/main/docs/opcodes.md)
- [BlueZ Device API](https://bluez.readthedocs.io/en/latest/device-api/)
- [BlueZ Media API](https://bluez.readthedocs.io/en/latest/media-api/)
