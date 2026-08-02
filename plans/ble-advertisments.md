# BLE proximity advertisements and case battery

Status: deferred and outside the supported product scope.

`airpodsctl` currently supports left and right earbud battery readings received over an initialized AACP connection. Case battery reporting is deprecated. The CLI must reject `battery case`, aggregate battery output must omit the case, and case records received over AACP must not enter application state.

This document records the work required before case battery can be considered again. It is not an implementation commitment, and the current service must not start a BLE scan merely because this plan exists.

## Why AACP is insufficient

A live capture from AirPods Pro 2 with USB-C produced this AACP battery notification while both earbuds were connected and the case was open:

```text
04 00 04 00 04 00 03
02 01 26 02 01   right: 38%, discharging
04 01 31 02 01   left:  49%, discharging
08 01 00 04 01   case:   0%, disconnected
```

The case record is a reachability placeholder, not evidence that the case has 0% charge. Opening an empty case did not change the record. Treating it as a real percentage gives a confidently wrong result.

AACP may occasionally relay a valid case record when an earbud is in the case, but that condition is not reliable enough to define a case-battery feature. The current parser may ignore the unknown `0x08` component without rejecting the entire notification, but no supported operation may expose or cache it.

Apple devices and existing third-party implementations obtain case state from Apple's Bluetooth Low Energy proximity advertisements. Apple's support flow also requires the case or AirPods to be awake and held near the receiving device when checking charge status.

## Observed BLE protocol surface

Existing implementations provide a starting point, not a stable specification:

- AirPods use Apple manufacturer data with company identifier `0x004c`.
- Proximity-pairing advertisements use message prefix `0x07`.
- Public fields include the model, primary-earbud flags, pod-in-case flags, lid state or counter, coarse battery nibbles, and charging flags.
- Paired devices can include a 16-byte encrypted payload containing more precise battery data.
- BLE advertiser addresses may rotate and must not be assumed to equal the paired classic Bluetooth address.
- A case advertises only while awake. Closing the lid eventually removes the live data source.

Relevant reverse-engineering references:

- [Apple: Charge your AirPods](https://support.apple.com/119912)
- [LibrePods BLE discovery and proximity parsing](https://github.com/librepods-org/librepods/blob/main/linux/ble/blemanager.cpp)
- [LibrePods AACP and encrypted battery parsing](https://github.com/librepods-org/librepods/blob/main/linux/battery.hpp)
- [CAPod](https://github.com/d4rken-org/capod), which implements AirPods case state from BLE advertisements

These protocols are unpublished and can vary by model and firmware. Code must be based on captures from hardware we are allowed to test, with external projects used for cross-checking rather than copied as an assumed specification.

## Questions that must be answered first

Implementation should not begin until research answers all of these questions:

1. Which proximity advertisement layouts are emitted by every AirPods model the project intends to support?
2. Is the public case nibble sufficiently accurate, or is decrypting the 16-byte payload required for the advertised CLI contract?
3. What paired-device material is required to associate rotating BLE advertisements with one selected AirPods pair and decrypt its payload?
4. Can that material be obtained through documented BlueZ interfaces without root access, re-pairing, or reading broadly scoped system secrets?
5. How are replayed, duplicated, and out-of-order advertisements identified?
6. Does active scanning interfere with A2DP, AACP latency, adapter power use, or other Bluetooth devices on the supported BlueZ versions?
7. Can multiple nearby AirPods pairs be distinguished without leaking stable identifiers in logs or IPC messages?
8. What freshness window makes a case reading current rather than merely last known?

If exact case readings require privileged access, insecure key handling, or a pairing workflow, the feature should remain out of scope.

## Required architecture

BLE support must remain independent from the existing AACP transport. It should add four logical responsibilities:

```text
BlueZ passive discovery
        |
        v
bounded Apple advertisement decoder
        |
        v
selected-pair association and optional decryption
        |
        v
timestamped state merger used by the session controller
```

### Passive discovery

Use the BlueZ D-Bus interfaces already available to the process rather than introducing a second Bluetooth framework. The scanner must:

- Select the same adapter used for the connected AirPods.
- Apply the narrowest discovery filter BlueZ supports.
- Subscribe to manufacturer-data changes instead of polling all managed objects repeatedly.
- Share discovery with other BlueZ clients and stop only the discovery session it owns.
- Bound every D-Bus value before parsing it.
- Survive adapter resets, suspend/resume, and BlueZ restarts.
- Avoid requiring root or additional Linux capabilities.

Continuous scanning should initially be limited to `serve`. A one-shot command should not silently start a broad BLE scan until its latency, privacy, and power behavior are explicitly designed.

### Advertisement decoding

The decoder must be a pure module with byte-slice input and typed output. It must validate the Apple company ID, message type, exact layout for the identified model, all offsets, reserved values, and payload lengths before reading fields.

Unknown models or layouts must be ignored rather than guessed. Malformed advertisements must not terminate the persistent AACP service.

The decoded event needs, at minimum:

- Model identifier.
- Primary-earbud orientation.
- Earbud-in-case flags.
- Lid state or lid counter.
- Left, right, and case battery values with charging flags when present.
- Whether a value is coarse, exact, unavailable, or encrypted.
- An observation timestamp from a monotonic clock.
- Enough ephemeral identity data for the association layer, without exposing it to CLI clients.

### Pair association and decryption

Rotating advertiser addresses mean address equality is not a valid association strategy. This layer must prove that an advertisement belongs to the AirPods selected by `--device` before its case value can enter state.

If precise data requires decryption:

- Keep key material in memory only unless a separately reviewed storage design is approved.
- Never log keys, decrypted identity fields, serial numbers, raw paired-device records, or full advertisements at normal log levels.
- Zero temporary key buffers when practical.
- Reject authentication or integrity failures rather than falling back to unauthenticated data.
- Document the origin, lifetime, and permissions of every required secret.

A coarse public value must not be silently labeled as an exact percentage. If the only trustworthy value is a ten-percent bucket, the output contract must say so.

### State merging and freshness

The central controller must remain the only owner of user-visible AirPods state. AACP and BLE producers should submit typed events; neither producer should directly format CLI results.

Every reading needs source and freshness metadata. At minimum, distinguish:

- Current AACP earbud reading.
- Current BLE case reading.
- Last-known case reading whose advertisement has expired.
- Unavailable reading.

An AACP `0 disconnected` case placeholder must never overwrite a valid BLE case value. A newly authenticated BLE event may update earbud values, but source-precedence rules must be documented and tested.

The default CLI must not present stale data as current. A future interface could use one of these explicit contracts:

```console
$ airpodsctl battery case
70

$ airpodsctl battery case
airpodsctl: case battery is unavailable; last seen 4 minutes ago at 70%
```

If last-known output is wanted for scripting, it should require an explicit option and return the observation age in a machine-readable form. That decision belongs in a separate CLI proposal.

### IPC evolution

The current `APR1` battery response retains a retired three-byte case slot only for compatibility with already-running version 1 services. New code writes zeroes there and ignores received contents.

BLE case state must not reuse that retired slot because it lacks source, precision, and freshness metadata. Reintroducing case battery requires a new IPC protocol version with:

- An explicit availability discriminator.
- Reading source.
- Precision or resolution.
- Observation age or timestamp semantics.
- Backward-compatibility behavior for mixed client and service versions.

## Security and privacy requirements

BLE scanning broadens the program from communicating with an already-selected connected device to observing nearby radio traffic. Before implementation, review and document:

- What nearby-device data BlueZ delivers to the process.
- What data is retained and for how long.
- Whether debug logs can identify people or devices.
- How the scanner behaves when no selected AirPods are connected.
- Whether the same-user IPC boundary remains sufficient for case information.
- How denial-of-service from high advertisement volume is bounded.

The implementation must remain passive. It must not pair, connect to arbitrary BLE devices, transmit proximity frames, impersonate an Apple device, or modify AirPods state.

## Implementation phases

1. Capture and research:
   - Record sanitized advertisements for supported models across lid, charging, and pod-placement states.
   - Remove addresses, serials, key material, and unrelated nearby-device traffic before committing fixtures.
   - Write a field map that distinguishes observation from inference.
2. Pure parser:
   - Add model-specific, bounds-checked advertisement fixtures.
   - Implement public/coarse decoding with malformed and unknown-layout tests.
   - Add decryption only after the key source and authentication model are understood.
3. BlueZ scanner:
   - Implement filtered passive discovery and lifecycle handling.
   - Prove that scans do not break AACP, audio, or other discovery clients.
4. Identity association:
   - Accept state only for the selected pair.
   - Test rotating addresses, multiple nearby pairs, replay, and failed decryption.
5. State integration:
   - Add source-aware timestamped cache entries and expiration.
   - Define precedence between AACP and BLE.
6. Interface proposal:
   - Specify exact, coarse, unavailable, and last-known output behavior.
   - Version IPC before restoring any case command.
7. Hardware validation:
   - Test every supported model and firmware condition in the acceptance matrix below.

Each phase should be independently reviewable. Parser work must not implicitly enable scanning, and scanner work must not implicitly expose case data through the CLI.

## Test and acceptance matrix

Automated tests must cover:

- Truncated advertisements at every field boundary.
- Incorrect company IDs and message types.
- Unknown models and reserved field values.
- Coarse battery values, unavailable sentinels, and charging flags.
- Authentication/decryption success and failure, if implemented.
- Rotating addresses and multiple nearby pairs.
- Duplicate and out-of-order observations.
- Freshness expiry and monotonic-clock behavior.
- AACP `0 disconnected` records not overwriting BLE state.
- IPC compatibility between adjacent protocol versions.
- Advertisement floods staying within fixed memory and CPU bounds.

Hardware validation must include:

- Case open with both earbuds outside.
- Case open with left, right, and both earbuds inside.
- Case closed with both earbuds inside.
- Case charging by cable and wirelessly.
- Case at low, mid, and high battery levels.
- One earbud connected while the other is unavailable.
- AirPods disconnected, reconnected, and moved out of range.
- Suspend/resume and BlueZ restart.
- Two paired AirPods and an unrelated nearby AirPods advertisement.
- Concurrent audio playback and repeated AACP commands during scanning.

Case battery support may return to the public scope only after the selected-pair association, freshness semantics, security review, automated tests, and hardware matrix all pass.
