# Automatic ear detection and wear-aware media control

Status: proposed and not yet part of the supported command surface.

This document separates two features that are often both called automatic ear detection:

| Layer | Responsibility |
| --- | --- |
| AirPods setting | Enable or disable the AirPods' Automatic Ear Detection preference through AACP control command `0x0a`. |
| Host media policy | Observe AACP wear-state notifications and decide whether Linux media players should pause or resume. |

Implementing only the AirPods setter provides a useful, scriptable device preference, but it does not guarantee that Linux applications will pause. LibrePods implements Linux playback control as a separate host-side policy. `airpodsctl` should preserve this boundary in its command interface and internal architecture.

## User value

The AirPods-side setting provides:

- Feature parity with the Automatic Ear Detection switch exposed by Apple devices.
- A way to disable false pauses caused by fit, sensor obstruction, or unusual wearing positions.
- A way to keep audio routed to the AirPods while they are not being worn.
- A reusable AACP control-command foundation for future settings such as microphone selection, one-bud ANC, automatic connection, press timing, and conversational awareness.
- Fast scripted access through the existing persistent session.

The host-side policy provides the larger Linux-specific benefit:

- Pause media when one or both earbuds are removed.
- Resume only media that `airpodsctl` previously paused.
- Avoid affecting media when the selected AirPods are not the active audio output.
- Expose live wear state for scripts and future integrations without adding BLE scanning.

Apple documents that enabled Automatic Ear Detection pauses or stops audio and changes output routing when the AirPods are removed. When disabled, audio remains routed to the AirPods whether or not they are being worn. That describes Apple-platform behavior and must not be treated as proof that sending the setting alone controls arbitrary Linux players.

## Observed AACP protocol

### Device setting

AACP control commands use opcode `0x0009` and an 11-byte packet:

```text
04 00 04 00 09 00 [identifier] [data1] [data2] [data3] [data4]
```

Automatic Ear Detection uses identifier `0x0a` and one meaningful value byte:

| Setting | Value | Complete packet |
| --- | --- | --- |
| Enabled | `0x01` | `04 00 04 00 09 00 0a 01 00 00 00` |
| Disabled | `0x02` | `04 00 04 00 09 00 0a 02 00 00 00` |

LibrePods Android sends this command from `AirPodsViewModel.setAutomaticEarDetectionEnabled` through its generic control-command builder. Its sender updates a local cache before writing the packet, so that cache is not proof that the AirPods accepted the value. `airpodsctl` must retain its existing acknowledgement standard: a successful setter should require a newer matching event from the AirPods whenever the protocol provides one.

### Wear-state notification

AirPods report wear-state changes with opcode `0x0006` in an eight-byte packet:

```text
04 00 04 00 06 00 [primary] [secondary]
```

The observed status values are:

| Value | Meaning |
| --- | --- |
| `0x00` | In ear |
| `0x01` | Out of ear |
| `0x02` | In case |
| Other | Unknown or disconnected; do not guess |

The final two bytes identify the primary and secondary earbuds, not permanently the left and right earbuds. LibrePods documents that the secondary may become primary when the current primary is removed, followed by another notification. Playback policy should therefore operate on the number of earbuds in ear rather than on byte position. A left/right status interface must first map primary orientation using a verified source such as the AACP battery report.

## Protocol questions to validate on hardware

Implementation may begin with pure packet parsing, but the public getter and acknowledged setter require live answers to these questions:

1. Does AACP initialization report the current `0x0a` control state without first changing it?
2. Does setting `0x0a` produce a matching control-command event that can acknowledge the write?
3. Does the value persist across an AACP reconnect, Bluetooth reconnect, case sleep cycle, and connection to an Apple device?
4. Does disabling Automatic Ear Detection stop opcode `0x0006` notifications, or does it only change how a host is expected to react to them?
5. Does the notification-subscription mask need to change when the setting is disabled or re-enabled?
6. Do all supported AirPods models use the same identifier and values?
7. What unknown or disconnected status values are emitted when only one earbud is available?
8. During a primary-earbud change, are transient packets emitted that could falsely look like a removal of both earbuds?

Sanitized captures should be committed as test fixtures only after addresses, names, serials, and unrelated traffic have been removed.

## Proposed command surface

Keep device configuration, observed state, and host automation explicit:

```console
$ airpodsctl automatic-ear-detection status
on
$ airpodsctl automatic-ear-detection off
off
$ airpodsctl wear-status
primary in-ear
secondary out-of-ear
$ airpodsctl serve --pause-on-removal=one
```

The final command spelling should be reviewed with the broader settings interface before implementation. Required semantics are:

- `automatic-ear-detection status|on|off` reads or changes the AirPods-side setting.
- `wear-status` reports the most recent AACP wear state without implying that primary means left.
- `--pause-on-removal=one|both|off` configures host media behavior for the persistent service.
- One-shot commands may read or change state, but must not remain alive to automate media.
- Media automation must be opt-in until its active-output detection and desktop compatibility have been validated.

Turning the device setting off should disable host automation by default because users reasonably expect that switch to stop automatic playback changes. If an explicit host-policy override is desired, it must be designed and documented rather than happening accidentally.

## Required architecture

The feature should add four logical responsibilities:

```text
AACP packet stream
        |
        v
control-command and wear-state decoders
        |
        v
controller-owned cached state and typed events
        |
        v
optional service-owned wear policy
        |
        v
bounded MPRIS media operations
```

### Protocol modules

Add a reusable control-command module instead of embedding the `0x0a` packet in an ear-detection operation. It should:

- Encode the fixed opcode `0x0009` frame from an identifier and at most four value bytes.
- Parse incoming control-command state with exact length and reserved-byte validation.
- Return typed identifier and value slices without owning application state.
- Reject malformed packets without preventing unrelated AACP notifications from being handled.

Add an ear-detection module that should:

- Define typed device-setting and wear-status enums.
- Construct the `0x0a` setting through the generic control-command encoder.
- Parse only exact opcode `0x0006` wear-state packets.
- Preserve primary and secondary identity in protocol state.
- Provide aggregate in-ear counts for policy decisions without inventing left/right identity.

The modules must remain pure packet logic. They must not format CLI output, call D-Bus, or implement playback policy.

### Controller state and events

The central controller remains the owner of current AirPods state. Extend it with:

- The most recently confirmed Automatic Ear Detection setting.
- A generation counter for setting acknowledgements.
- Primary and secondary wear states.
- A wear-state generation counter.
- Whether an initial wear snapshot has been received for the current AACP session.

`Controller.receiveOne` currently parses a packet, updates state, and returns. Media integration will need to know whether a meaningful event occurred without duplicating reads. Refactor it to return an optional typed event while continuing to update controller state. Direct commands may ignore the event; the persistent service may pass wear events to its policy layer.

The controller must not invoke media operations. Keeping side effects in the service ensures one-shot commands remain one-shot and prevents packet tests from requiring a desktop session bus.

### Device getter and setter

The getter should wait for a confirmed `0x0a` state received from the AirPods. It must not report a compiled default or a value remembered only by the current process.

The setter should:

1. Ensure the current setting is known if the acknowledgement protocol depends on generation comparison.
2. Record the previous setting generation.
3. Send the `0x0a` control command.
4. Continue consuming all AACP notifications until a newer matching `0x0a` state arrives.
5. Report the confirmed value.
6. Fail with a specific acknowledgement error if a newer conflicting value arrives or the shared deadline expires.

If hardware testing proves that AirPods do not acknowledge this control command, the CLI must not pretend that transport success is state confirmation. In that case, either expose the operation explicitly as write-only with documented semantics or defer the setter until a reliable confirmation mechanism is known.

### Wear policy

Implement playback decisions as a pure state machine with these inputs:

- Previous stable in-ear count.
- New stable in-ear count.
- Configured policy: one removed, both removed, or off.
- Whether the initial snapshot has been received.
- Whether media is currently owned by an earlier automatic pause.

The intended transitions are:

| Policy | Pause transition | Resume transition |
| --- | --- | --- |
| One removed | Two in ear to fewer than two | Fewer than two to two, only if previously paused by this service |
| Both removed | At least one in ear to none | None to at least one, only if previously paused by this service |
| Off | Never | Never |

Additional rules:

- The first snapshot initializes state and must never pause or resume media.
- Repeated identical notifications are idempotent.
- Swapping primary and secondary without changing the in-ear count is not a playback transition.
- `InCase` counts as not in ear.
- Unknown or disconnected values must be handled conservatively and tested before being counted as an intentional removal.
- Losing the AACP connection clears transition and pause ownership state; reconnecting must not resume stale media.
- Debouncing should be added only if hardware captures prove that AirPods emit unstable intermediate counts. An arbitrary delay would make a latency-sensitive feature worse.

### MPRIS integration

Linux playback control should use the user D-Bus session and the standard `org.mpris.MediaPlayer2.Player` interface. Do not shell out to `playerctl`; a direct D-Bus implementation avoids command injection, an extra runtime dependency, and ambiguous parsing.

On a pause transition, the media layer should:

1. Verify that the selected AirPods are the active audio output.
2. Enumerate bounded session-bus names beginning with `org.mpris.MediaPlayer2.`.
3. Read each valid player's `PlaybackStatus` with a bounded timeout.
4. Call `Pause` only for players reporting `Playing`.
5. Record only the service names for which `Pause` succeeded.

On a resume transition, it should:

1. Reconfirm that the selected AirPods are active.
2. Call `Play` only for recorded services that still exist and remain eligible.
3. Clear each ownership record after success, disappearance, explicit user override, or session reset.

Subscribe to `PlaybackStatus` changes so a user action made after the automatic pause cancels automatic-resume ownership. The implementation must never resume a player merely because it exists or is currently paused.

Multiple players can legitimately report `Playing`. The initial behavior may match LibrePods by pausing all such players, but this must be documented and tested. One failed or unresponsive player must not block other players or tear down the AACP connection.

### Active-output detection

LibrePods Linux checks whether the PulseAudio default sink name contains the selected AirPods MAC address. That is practical but depends on naming conventions and audio-server compatibility.

Before enabling media automation by default, determine a reliable method for the supported Linux stack. Prefer matching the selected BlueZ device to an active `org.bluez.MediaTransport1` object if its state accurately represents routed A2DP audio. If that is insufficient, evaluate a narrowly scoped PipeWire or PulseAudio integration. Requirements are:

- Identify the exact AirPods selected by `--device`.
- Avoid pausing media sent to speakers or another headset.
- Work from a systemd user service with the normal user-session environment.
- Handle route changes, suspend/resume, and audio-server restarts.
- Avoid parsing unstable display names when a stable object relationship is available.

Media automation must remain disabled when active-output identity is unknown.

### Audio-profile behavior

LibrePods activates A2DP when at least one earbud is worn and sets the Bluetooth card profile to `off` when both are removed. Do not include that behavior in the first implementation.

Changing the card profile is more invasive than pausing media. It may add reconnect latency, conflict with WirePlumber, affect calls, or interfere with user routing choices. Audio-profile automation requires a separate proposal and hardware validation.

### IPC evolution

New operations and results must be encoded as explicit IPC variants. Review the current protocol version before assigning values, and test mixed client/service versions so an older process produces a clear incompatibility error rather than interpreting a new operation as another command.

Wear-state events do not need to be streamed to ordinary clients for the first implementation. The persistent service can consume them internally while `wear-status` returns the latest cached snapshot. A future watch or subscription interface should use a separately versioned IPC design with backpressure and disconnect behavior.

## Service lifecycle and failure behavior

The persistent service already keeps the AACP connection open, drains unsolicited notifications, and caches state. Ear detection should use that existing read owner rather than creating another thread or socket.

Required behavior includes:

- Media failures are logged or returned through media-specific state but do not invalidate the AACP byte stream.
- Malformed ear packets produce protocol diagnostics without being mistaken for valid transitions.
- D-Bus calls have fixed deadlines and no unbounded retry loop.
- Player service names and statuses are treated as untrusted same-user input and bounded before storage.
- The remembered paused-player set has a fixed maximum size.
- A service shutdown, AirPods disconnect, selected-device change, or D-Bus restart clears pause ownership.
- No media action occurs merely because a client runs `wear-status` or changes an unrelated setting.

## Implementation phases

1. Protocol capture and validation:
   - Capture initial control state, enabled and disabled setters, and their responses.
   - Capture all wear transitions, including primary swaps, single-ear use, and case placement.
   - Determine persistence and notification-mask behavior.
2. Generic control commands:
   - Add bounded encoder and parser fixtures for opcode `0x0009`.
   - Add controller state and generation tracking for incoming control values.
3. Automatic Ear Detection operation:
   - Add the typed `0x0a` setting.
   - Implement direct and session getter/setter behavior with confirmed acknowledgements.
   - Extend CLI, IPC, help, and README documentation.
4. Wear-state support:
   - Add the opcode `0x0006` parser and fixtures.
   - Cache primary/secondary state and expose `wear-status`.
   - Verify orientation behavior against battery primary-earbud data before exposing left/right labels.
5. Pure playback policy:
   - Implement transition and ownership logic independently of D-Bus.
   - Cover initialization, duplicate events, primary swaps, reconnects, and user overrides.
6. MPRIS integration:
   - Add bounded player discovery, property reads, `Pause`, and `Play`.
   - Prove selected-AirPods active-output detection on supported audio stacks.
   - Integrate only with `serve` and keep it opt-in.
7. Hardware and desktop validation:
   - Exercise the acceptance matrix below across representative players and AirPods states.
   - Enable broader defaults only after routing and manual-override behavior are reliable.

Each phase should be independently reviewable. The AirPods setter must not silently introduce media integration, and parsing wear notifications must not automatically enable playback side effects.

## Automated tests

Protocol tests must cover:

- Exact enabled and disabled control-command encodings.
- Truncated control commands at every byte boundary.
- Unknown identifiers, oversized values, and nonzero reserved bytes.
- Matching, conflicting, duplicate, and stale setting acknowledgements.
- Exact wear-state packet parsing.
- Every known status value in both byte positions.
- Truncated, oversized, wrong-prefix, and unknown-status packets.
- Primary/secondary swaps that preserve the aggregate in-ear count.

Policy tests must cover:

- No action on the initial state.
- One-removed and both-removed transition tables.
- Duplicate notifications producing no repeated calls.
- `InCase`, unknown, and disconnected handling.
- Pause ownership recorded only after successful pauses.
- Pre-existing paused players never being resumed.
- User play, user pause, player disappearance, D-Bus restart, and AACP reconnect clearing ownership appropriately.
- Multiple players with mixed success, timeout, and disappearance behavior.

Integration tests should run under an isolated D-Bus session with fake MPRIS players. They must verify method calls and property changes without requiring a real desktop media player. Active-output detection should have an injectable interface so policy tests do not depend on BlueZ, PipeWire, or PulseAudio.

## Hardware and desktop acceptance matrix

AirPods validation must include:

- Read setting while enabled and disabled.
- Enable, disable, and repeat an already-selected value.
- Reconnect AACP and Bluetooth after each value.
- Put the case and earbuds through sleep and wake cycles.
- Change the setting from an Apple device, then observe it from `airpodsctl`.
- Both earbuds in, left removed, right removed, both removed, and each earbud reinserted.
- One earbud placed in the case while the other remains worn.
- Primary/secondary orientation changes during removal.
- Only one earbud connected or available.
- AACP disconnect during every aggregate wear state.

Desktop validation must include:

- At least one browser, native music player, and video player that exposes MPRIS.
- A player that does not expose MPRIS.
- Two MPRIS players active concurrently.
- Media already paused before an earbud is removed.
- Manual resume while the earbuds remain removed.
- Manual pause or track change after automatic resume.
- Audio routed to speakers, another headset, and the selected AirPods.
- Route changes immediately before and after a wear transition.
- Service restart, D-Bus restart, audio-server restart, suspend/resume, and AirPods reconnect.
- Calls or communication audio remaining unaffected by media-only policy.

## Out of scope for the first implementation

- BLE proximity advertisements or case battery state.
- Audio-profile disabling, forced A2DP reconnection, or automatic route changes.
- Pausing non-MPRIS audio streams through process or audio-server manipulation.
- Call control or communication-stream automation.
- A GUI, tray application, or desktop notification.
- A public streaming IPC subscription for every wear event.

## References

- Apple, [Change the settings of your AirPods and AirPods Pro](https://support.apple.com/en-euro/108764).
- LibrePods control-command documentation, `../librepods/docs/control_commands.md`.
- LibrePods ear-notification documentation, `../librepods/docs/AAP Definitions.md`.
- LibrePods Linux parser, `../librepods/linux/eardetection.hpp`.
- LibrePods Linux event routing, `../librepods/linux/main.cpp`.
- LibrePods Linux media policy and MPRIS integration, `../librepods/linux/media/mediacontroller.cpp`.
- LibrePods Android control-command implementation, `../librepods/android/app/src/main/java/me/kavishdevar/librepods/bluetooth/AACPManager.kt`.
- LibrePods Android ear-state policy, `../librepods/android/app/src/main/java/me/kavishdevar/librepods/services/AirPodsService.kt`.

The LibrePods paths above refer to the sibling checkout used for this research. Protocol behavior remains reverse-engineered and must be verified against hardware before becoming a stable `airpodsctl` contract.
