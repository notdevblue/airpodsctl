# Pause on removal host media policy

Status: implemented provisionally. AACP wear parsing, controller state/events, the pure transition policy, persistent control-session recovery, and bounded MPRIS pause/resume ownership are present. Live testing on AirPods Pro 2 USB-C confirmed pause after removal and resume after reinsertion. The broader hardware and desktop acceptance matrix remains outstanding.

## Scope

This feature is a Linux host policy:

```text
AACP wear notifications
        |
        v
connection-scoped wear state
        |
        v
explicit pause-on-removal policy
        |
        v
bounded MPRIS pause/resume
```

airpodsctl does not expose, read, infer, cache, or write an AirPods-side ear-detection preference. The policy is controlled only through:

```console
$ airpodsctl serve --pause-on-removal=one
$ airpodsctl serve --pause-on-removal=both
$ airpodsctl serve --pause-on-removal=off
```

The default is `off`. One-shot commands never remain alive to automate media.

`wear-status` remains available as a diagnostic view of the most recent AACP snapshot:

```console
$ airpodsctl wear-status
primary in-ear
secondary out-of-ear
```

Primary and secondary are protocol roles, not permanent left/right identities.

## Observed AACP wear notification

AirPods report wear changes with opcode `0x0006` in an eight-byte packet:

```text
04 00 04 00 06 00 [primary] [secondary]
```

The observed values are:

| Value | Meaning |
| --- | --- |
| `0x00` | In ear |
| `0x01` | Out of ear |
| `0x02` | In case |
| Other | Unknown; do not guess |

The secondary earbud may become primary after removal. Playback decisions therefore use the number of known earbuds in ear rather than byte position. Unknown values invalidate the aggregate count and suppress transitions.

## Transition policy

The pure policy consumes stable aggregate wear counts and owns no Bluetooth, D-Bus, or player state directly.

| Policy | Pause transition | Resume transition |
| --- | --- | --- |
| `one` | Two in ear to fewer than two | Fewer than two to two, only after a confirmed policy pause |
| `both` | At least one in ear to none | None to at least one, only after a confirmed policy pause |
| `off` | Never | Never |

Required behavior:

- The first valid snapshot establishes a baseline and never changes playback.
- Repeated snapshots are idempotent.
- Swapping primary and secondary without changing the aggregate count is not a transition.
- `in-case` counts as not in ear.
- Unknown states clear the transition baseline so no change is inferred across uncertain data.
- Losing the AACP connection clears the baseline and automatic-resume ownership.
- Reconnecting establishes a new baseline and never resumes media paused by an earlier connection.
- An enabled policy retries a lost AACP control session with bounded exponential backoff instead of waiting for a client command.

## Host-wide action scope

Pause-on-removal is an explicitly enabled host policy and does not depend on the currently selected audio output. A qualifying wear transition may therefore pause eligible MPRIS players even when another physical or virtual output is selected or the AirPods use a non-A2DP profile.

This behavior is intentional: wear notifications establish that the configured AirPods were removed, while the opt-in policy defines that event as a request to pause host media generally.

## MPRIS ownership

On an eligible removal transition, the service inspects a bounded set of MPRIS players and sends `Pause` only to players that report `Playing` and support pausing.

A player becomes eligible for automatic resume only when:

1. airpodsctl requested its pause;
2. a later property read confirmed `Paused`;
3. the D-Bus owner is unchanged.

Players that were already paused are never resumed. Manual playback changes, player disappearance, D-Bus loss, or AACP disconnect clear ownership conservatively. A default-sink change does not clear ownership because routing is outside this host-wide policy. Multiple players are tracked independently and bounded operations prevent one unresponsive player from blocking the service indefinitely.

## Controller and service ownership

The central controller is the sole reader of the AACP stream. It parses wear packets into connection-scoped state and emits typed events. The service observes those events and owns all desktop side effects.

This separation ensures:

- one-shot `wear-status` cannot trigger playback changes;
- unrelated commands cannot consume wear notifications needed by the service;
- packet parsing remains independently testable;
- MPRIS failures do not corrupt Bluetooth protocol state.

The persistent IPC protocol keeps `wear-status` on version 2. Wear events are not streamed to clients; the service returns only its latest cached snapshot.

## Automated coverage

Protocol and policy tests cover:

- exact wear packet parsing;
- every known state in both byte positions;
- truncated, oversized, wrong-prefix, and unknown-state packets;
- initial baselines and duplicate notifications;
- one-removed and both-removed transition tables;
- primary/secondary swaps;
- in-case and unknown handling;
- reconnect resets;
- multiple MPRIS players with mixed outcomes;
- confirmed-pause ownership;
- user playback changes, player disappearance, and D-Bus restart;
- asynchronous MPRIS pause confirmation before resume ownership is recorded.

The MPRIS integration suite runs under an isolated D-Bus session with fake players and does not require a desktop media application.

## Remaining acceptance matrix

Hardware validation should include:

- both earbuds in, either earbud removed, both removed, and each reinserted;
- one earbud placed in the case while the other remains worn;
- primary/secondary role changes during removal;
- a single connected earbud;
- unknown or disconnected wear values;
- AACP disconnect and reconnect in every aggregate state.

Desktop validation should include:

- Chromium-family browsers, Firefox, VLC, mpv, and a native music player;
- multiple simultaneous players;
- a player already paused before removal;
- manual play or pause between removal and reinsertion;
- player exit or restart while removed;
- D-Bus restart;
- another physical output, a virtual default sink, and profile changes, all of which must leave the host-wide policy active;
- removal while no player is active.

## Non-goals

This feature does not:

- expose or synchronize an AirPods-side ear-detection setting;
- infer device configuration from missing notifications;
- scan BLE proximity advertisements;
- relabel primary/secondary as left/right without verified orientation data;
- change BlueZ profiles or the default audio output;
- pause media unless the policy is explicitly enabled;
- resume media that airpodsctl did not confirm it had paused.
