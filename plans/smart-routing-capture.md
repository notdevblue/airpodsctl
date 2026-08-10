Yes, that should work. A Mac-side PacketLogger trace from your current AirPods is the most useful artifact we can collect next.

The critical condition is that the Mac must be a real participant in native Apple automatic switching with your iPhone—not merely a Mac that has been manually paired over ordinary Bluetooth. Ideally:

- The Mac and iPhone are signed into the same Apple Account with two-factor authentication.
- Your AirPods show “Connect to This Mac: Automatically.”
- Your iPhone shows “Connect to This iPhone: Automatically.”
- Automatic switching between that Mac and iPhone actually works before we start capturing.

Apple lists the same Apple Account and two-factor authentication as requirements for automatic switching. [Apple’s automatic-switching requirements](https://support.apple.com/en-us/104988)

If the Mac belongs to someone else and uses a different Apple Account, the capture can still reveal ordinary Mac/AirPods protocol traffic, but it probably will not reveal the trusted host-to-host relay enrollment we need. Do not sign your Apple Account into someone else’s Mac unless it is a trusted machine and you understand the privacy implications. A Mac that is already signed into your account is strongly preferable.

# Before going to the Mac

Bring or prepare:

- Your AirPods, preferably fully charged.
- Your iPhone, preferably fully charged.
- An offline audio file or downloaded song at least two minutes long on both the Mac and iPhone. Offline media avoids network buffering confusing the timing.
- Access to the Apple Developer downloads page.
- A way to export a ZIP file from the Mac afterward: USB drive, AirDrop, cloud storage, or direct upload here.
- This checklist.

On Linux before starting:

1. Stop playback.
2. Stop `airpodsctl serve` if it is running.
3. Turn off Linux Bluetooth temporarily, or at least disconnect the AirPods.
4. Do not remove or forget the AirPods from Linux.

We want the AirPods’ two active hosts to be the Mac and iPhone, without Linux attempting to reconnect in the background.

# Part 1: Verify that the Mac is a valid reference host

Do this before installing or starting PacketLogger.

## 1. Check the Mac and iPhone account relationship

On the Mac:

1. Open **System Settings**.
2. Click the Apple Account name at the top of the sidebar.
3. Confirm this is the same Apple Account used by the iPhone.
4. Do not record or send the account address; just note `same-account=yes` in the metadata later.

On the iPhone:

1. Open **Settings**.
2. Confirm the Apple Account at the top is the same.
3. Confirm two-factor authentication is enabled if you do not already know.

## 2. Verify the AirPods automatic-connection settings

Put the AirPods in your ears and connect them.

On the Mac:

1. Open **System Settings → Bluetooth**.
2. Find your AirPods.
3. Click the information or **Options** button next to them.
4. Set **Connect to This Mac** to **Automatically**.
5. Record whether it was already set to Automatically.

On the iPhone:

1. Open **Settings**.
2. Tap the AirPods near the top, or open **Bluetooth** and tap the information button next to them.
3. Tap **Connect to This iPhone**.
4. Select **Automatically**.
5. Record whether it was already set to Automatically.

Apple documents those controls under the AirPods switching settings. [Apple AirPods switching guide](https://support.apple.com/en-euro/guide/airpods/dev228ba3df8/web)

## 3. Confirm native automatic switching works

Before capturing:

1. Wear both AirPods.
2. Start audio on the Mac and confirm it is audible through the AirPods.
3. While the Mac is playing, start audio on the iPhone.
4. Confirm whether the AirPods automatically move to the iPhone.
5. Pause the iPhone.
6. Start audio on the Mac again.
7. Confirm whether the AirPods move back automatically, show a Mac notification requiring **Connect**, or fail to move.

Record the observed behavior.

A macOS Sonoma-era Mac may display a confirmation notification instead of switching entirely automatically. On macOS Sequoia or later, supported AirPods can switch automatically. The macOS version therefore matters.

If neither direction works and the devices are not recognized as members of the same Apple ecosystem, the capture will not be a complete golden reference. It may still be useful, but tell me that native switching did not work.

Do not forget, factory-reset, or re-pair the AirPods yet.

# Part 2: Install PacketLogger

Apple distributes PacketLogger inside **Additional Tools for Xcode** and recommends it for macOS Bluetooth captures. A paid Apple Developer Program membership is not required to access additional tools, but the download page requires signing into an Apple Account. [Apple Bluetooth tools](https://developer.apple.com/bluetooth/), [Apple Xcode resources](https://developer.apple.com/xcode/resources/)

## 1. Download PacketLogger

On the Mac:

1. Open Safari.
2. Go to [Apple Developer Downloads](https://developer.apple.com/download/all/).
3. Sign in if requested.
4. Search for:

   ```text
   Additional Tools for Xcode
   ```

5. Download the latest stable—not beta—version compatible with the installed macOS.
6. Open the downloaded `.dmg`.
7. Look inside the **Hardware** folder for **PacketLogger.app**.
8. Copy `PacketLogger.app` to `/Applications`, if you have permission.

If you cannot copy it into Applications, launching it directly from the mounted disk image may work for a limited capture session.

You do not need to install the entire Xcode application merely to run PacketLogger.

## 2. Launch and grant permissions

1. Open **PacketLogger**.
2. If macOS blocks it, Control-click the application, select **Open**, and confirm.
3. Approve any request for:
   - Bluetooth access.
   - A privileged capture helper.
   - Administrator authentication.
4. If macOS asks you to enable it under **System Settings → Privacy & Security → Bluetooth**, enable PacketLogger.
5. Quit and reopen PacketLogger after changing a privacy permission.

Do not grant unrelated permissions such as Contacts, Photos, or iCloud access.

## 3. Verify that PacketLogger is actually capturing

PacketLogger versions vary slightly, but normally a new live capture window begins receiving controller traffic automatically. If needed:

1. Choose **File → New** or press `Command-N`.
2. Make sure capture is started if the toolbar presents a Start/Stop control.
3. Clear any search text or packet filters.
4. Ensure the view is showing all packet types.
5. Connect or disconnect the AirPods once from the Mac Bluetooth menu.
6. Confirm rows are appearing rapidly.

Useful rows should include names similar to:

- HCI Command
- HCI Event
- ACL Data TX
- ACL Data RX
- L2CAP traffic

The essential requirement is that both transmitted and received ACL data appear. Bluetooth advertisements alone are not enough.

If the window remains completely empty:

1. Check **System Settings → Privacy & Security → Bluetooth**.
2. Enable PacketLogger if it appears there.
3. Quit and reopen PacketLogger.
4. Try `File → New` again.
5. Confirm you downloaded a PacketLogger version compatible with that macOS release.
6. Restart the Mac if time permits.

Do not continue a long test session until you see packets arriving. A blank PacketLogger capture is not useful.

# Part 3: Create the metadata and event marker files

PacketLogger records accurate packet timestamps, but it does not know when you pressed Play, opened the case, or heard the audio move. We need a separate action timeline.

Open Terminal and run:

```bash
cd ~/Desktop
mkdir -p airpods-smart-routing-capture
cd airpods-smart-routing-capture
sw_vers > macos.txt
sysctl -n hw.model > mac-model.txt
touch events.tsv
mark() { printf '%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a events.tsv; }
mark "capture_setup_complete"
```

Keep that Terminal window open. During the capture, enter commands such as:

```bash
mark "mac_play_start"
```

The `mark` command exists only in that Terminal window. If you close the window, rerun:

```bash
cd ~/Desktop/airpods-smart-routing-capture
mark() { printf '%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a events.tsv; }
```

## Create `metadata.txt`

In TextEdit, create:

```text
same_apple_account=yes-or-no
two_factor_authentication=yes-or-no
native_automatic_switching_verified=yes-or-no

mac_model=
macos_version=
macos_build=

iphone_model=
ios_version=
ios_build_if_known=

airpods_model=
airpods_firmware=
airpods_case_firmware_if_shown=

connect_to_this_mac=automatically-or-other
connect_to_this_iphone=automatically-or-other

packetlogger_version=

linux_bluetooth_disabled=yes-or-no

notes=
```

Save it as:

```text
~/Desktop/airpods-smart-routing-capture/metadata.txt
```

To find the AirPods firmware on the iPhone:

1. Open **Settings**.
2. Tap the AirPods near the top.
3. Scroll to the **About** section.
4. Record the version displayed there.

Do not put your Apple Account email address, Mac serial number, phone number, or any password into the metadata.

# Part 4: Capture 1 — connection bootstrap

This is the most important capture because it may reveal how a Mac announces or enrolls itself as a smart-routing host.

## Initial state

1. Linux Bluetooth is off or Linux is disconnected.
2. Mac Bluetooth is on.
3. iPhone Bluetooth is on.
4. Stop all media on the Mac and iPhone.
5. Put both AirPods in the case.
6. Close the case for at least 30 seconds.
7. Leave the Mac and iPhone awake and unlocked.
8. Start a completely new PacketLogger document.
9. Verify the packet list is moving.
10. Run:

```bash
mark "bootstrap_capture_start_case_closed"
```

## Perform the bootstrap sequence

Follow these steps exactly. Waiting periods do not need to be exact to the millisecond.

1. Wait 15 seconds with the case closed.
2. Run:

   ```bash
   mark "airpods_case_open"
   ```

3. Open the AirPods case.
4. Wait 10 seconds.
5. Run:

   ```bash
   mark "airpods_inserted"
   ```

6. Put both AirPods in your ears.
7. Wait 60 seconds for the Mac and iPhone connections to settle.
8. If the Mac presents an AirPods **Connect** notification, run:

   ```bash
   mark "mac_connect_notification_shown"
   ```

9. Click **Connect**, then run:

   ```bash
   mark "mac_connect_notification_accepted"
   ```

10. Check the Mac Bluetooth menu and iPhone AirPods screen. Do not manually disconnect anything.
11. Record the state:

```bash
mark "settled mac_connected=yes iphone_connected=yes audible=none"
```

Adjust the values if one device is not connected.

## Add a simple playback transition

1. Run:

   ```bash
   mark "mac_play_start"
   ```

2. Start the offline audio file on the Mac.
3. Let it play for 30 seconds.
4. Run an outcome marker:

   ```bash
   mark "mac_play_outcome audible=mac notification=none"
   ```

   Replace the outcome if necessary.

5. Run:

   ```bash
   mark "mac_pause"
   ```

6. Pause the Mac.
7. Wait 20 seconds.
8. Run:

   ```bash
   mark "iphone_play_start"
   ```

9. Start the downloaded audio on the iPhone.
10. Let it play for 30 seconds.
11. Record the outcome:

```bash
mark "iphone_play_outcome audible=iphone switched_automatically=yes"
```

12. Pause the iPhone:

```bash
mark "iphone_pause"
```

13. Wait 20 seconds.
14. Run:

```bash
mark "bootstrap_capture_end"
```

## Save the capture

In PacketLogger:

1. Choose **File → Save** or **Save As**.
2. Save the original PacketLogger document as:

   ```text
   ~/Desktop/airpods-smart-routing-capture/01-bootstrap.pklg
   ```

3. Keep the `.pklg` format. Do not export only as text, PDF, screenshots, or a filtered packet list.
4. Confirm the file exists and has a nontrivial size.

# Part 5: Capture 2 — repeatable automatic switching

This capture compares both takeover directions and distinguishes idle-host behavior from active-host competition.

## Initial state

1. Keep the AirPods in your ears.
2. Make sure the Mac and iPhone are both connected.
3. Pause all media.
4. Wait 30 seconds.
5. Open a fresh PacketLogger document with `Command-N`.
6. Confirm packets are arriving.
7. Run:

   ```bash
   mark "switching_capture_a_start both_idle"
   ```

## Mac to iPhone while Mac is active

1. Run:

   ```bash
   mark "mac_play_start_a"
   ```

2. Start Mac audio.
3. Wait 20 seconds.
4. Confirm it is audible:

   ```bash
   mark "mac_play_outcome_a audible=mac"
   ```

5. Do not pause the Mac manually.
6. Run:

   ```bash
   mark "iphone_play_while_mac_active_start"
   ```

7. Start iPhone audio while Mac audio is still playing.
8. Wait 30 seconds.
9. Record exactly what happened:

   ```bash
   mark "iphone_vs_mac_outcome audible=iphone mac_paused=yes switched_automatically=yes notification=none"
   ```

   Adjust every value to match reality. For example:

   ```bash
   mark "iphone_vs_mac_outcome audible=mac mac_paused=no switched_automatically=no notification=iphone_moved_banner"
   ```

10. Pause both devices:

```bash
mark "both_paused_after_iphone_takeover"
```

11. Wait 30 seconds.

## iPhone to Mac while iPhone is active

1. Run:

   ```bash
   mark "iphone_play_start_b"
   ```

2. Start iPhone audio.
3. Wait 20 seconds.
4. Confirm the outcome:

   ```bash
   mark "iphone_play_outcome_b audible=iphone"
   ```

5. Leave the iPhone playing.
6. Run:

   ```bash
   mark "mac_play_while_iphone_active_start"
   ```

7. Start Mac audio.
8. Wait 30 seconds.
9. If a Mac notification appears, mark it before clicking anything:

   ```bash
   mark "mac_switch_notification_shown"
   ```

10. If the notification requires **Connect**, click it and run:

```bash
mark "mac_switch_notification_accepted"
```

11. Record the final outcome:

```bash
mark "mac_vs_iphone_outcome audible=mac iphone_paused=yes switched_automatically=yes"
```

12. Pause both devices:

```bash
mark "both_paused_after_mac_takeover"
```

13. Wait 30 seconds.

## Explicit/manual switching in both directions

First select the Mac explicitly:

1. Start iPhone audio and confirm it is audible.
2. Run:

   ```bash
   mark "manual_select_mac_start"
   ```

3. On the Mac, open **Control Center → Bluetooth** and select the AirPods.
4. Wait 20 seconds.
5. Run:

   ```bash
   mark "manual_select_mac_outcome audible=mac-or-iphone"
   ```

Then select the iPhone explicitly:

1. Run:

   ```bash
   mark "manual_select_iphone_start"
   ```

2. On the iPhone, open Control Center or the Now Playing output selector and select the AirPods.
3. Wait 20 seconds.
4. Run:

   ```bash
   mark "manual_select_iphone_outcome audible=iphone-or-mac"
   ```

Finally:

```bash
mark "switching_capture_a_end"
```

Save the PacketLogger file as:

```text
02-switching-a.pklg
```

# Part 6: Capture 3 — repeat the switching sequence

Repeat Part 5 once more and save it as:

```text
03-switching-b.pklg
```

Use corresponding markers:

```bash
mark "switching_capture_b_start both_idle"
```

and:

```bash
mark "switching_capture_b_end"
```

The repeated capture is not redundant. It lets me identify:

- Stable OPACK dictionary keys.
- Session-specific values.
- Counters.
- Timestamps.
- Nonces.
- Persistent device identifiers.
- Which packets are causal and which are background traffic.

If your Mac access is extremely short, prioritize:

1. `01-bootstrap.pklg`
2. `02-switching-a.pklg`
3. `03-switching-b.pklg`

# Part 7: Capture 4 — iPhone call priority

This is extremely valuable because calls should use a different arbitration category and priority from media.

Only do this if you can place a safe test call—for example, voicemail, another phone you control, or a willing participant. Do not call emergency services.

## Initial state

1. AirPods in your ears.
2. Mac and iPhone connected.
3. Both idle for 30 seconds.
4. Start a fresh PacketLogger document.
5. Run:

   ```bash
   mark "call_capture_start both_idle"
   ```

## Test sequence

1. Start Mac audio:

   ```bash
   mark "mac_play_before_call_start"
   ```

2. Confirm it is audible:

   ```bash
   mark "mac_play_before_call_outcome audible=mac"
   ```

3. While the Mac is playing, place or answer an iPhone call:

   ```bash
   mark "iphone_call_start"
   ```

4. Wait until call audio is established.
5. Record what happened:

   ```bash
   mark "iphone_call_connected audible=iphone_call mac_paused=yes switched_automatically=yes"
   ```

6. While the call remains active, attempt to start Mac media:

   ```bash
   mark "mac_play_attempt_during_iphone_call"
   ```

7. Wait 15 seconds.
8. Record whether the Mac was allowed to take the AirPods:

   ```bash
   mark "mac_during_call_outcome audible=iphone_call mac_takeover=no"
   ```

9. Stop Mac playback if it started.
10. End the call:

    ```bash
    mark "iphone_call_end"
    ```

11. Wait 30 seconds.
12. Start Mac audio again:

    ```bash
    mark "mac_play_after_call_start"
    ```

13. Record the result:

    ```bash
    mark "mac_play_after_call_outcome audible=mac switched=yes"
    ```

14. Pause all media.
15. Wait 20 seconds.
16. Run:

    ```bash
    mark "call_capture_end"
    ```

Save as:

```text
04-iphone-call.pklg
```

# Part 8: Capture 5 — case reconnect

This tests whether relay enrollment is repeated, refreshed, or retained across an AirPods session reset.

1. Start with Mac and iPhone connected and idle.
2. Start a fresh PacketLogger document.
3. Run:

   ```bash
   mark "reconnect_capture_start"
   ```

4. Put both AirPods in the case:

   ```bash
   mark "airpods_inserted_into_case"
   ```

5. Close the case:

   ```bash
   mark "airpods_case_closed"
   ```

6. Wait 45 seconds.
7. Open the case:

   ```bash
   mark "airpods_case_reopened"
   ```

8. Wait 10 seconds.
9. Put the AirPods in your ears:

   ```bash
   mark "airpods_reinserted"
   ```

10. Wait 60 seconds.
11. Record connections:

    ```bash
    mark "reconnect_settled mac_connected=yes iphone_connected=yes"
    ```

12. Start Mac audio:

    ```bash
    mark "mac_play_after_reconnect_start"
    ```

13. Let it play for 20 seconds.
14. Record:

    ```bash
    mark "mac_play_after_reconnect_outcome audible=mac"
    ```

15. Start iPhone audio while Mac is active:

    ```bash
    mark "iphone_play_after_reconnect_start"
    ```

16. Wait 30 seconds.
17. Record the result:

    ```bash
    mark "iphone_play_after_reconnect_outcome audible=iphone switched=yes"
    ```

18. Pause everything.
19. Run:

    ```bash
    mark "reconnect_capture_end"
    ```

Save as:

```text
05-case-reconnect.pklg
```

# Part 9: Review the files before leaving the Mac

The folder should contain at least:

```text
airpods-smart-routing-capture/
├── 01-bootstrap.pklg
├── 02-switching-a.pklg
├── 03-switching-b.pklg
├── 04-iphone-call.pklg
├── 05-case-reconnect.pklg
├── events.tsv
├── mac-model.txt
├── macos.txt
└── metadata.txt
```

The minimum acceptable set is:

```text
01-bootstrap.pklg
02-switching-a.pklg
events.tsv
mac-model.txt
macos.txt
metadata.txt
```

Before exporting:

1. Open each `.pklg` in PacketLogger.
2. Confirm it contains packets.
3. Confirm the time range matches the experiment.
4. Confirm both ACL TX and ACL RX traffic are present.
5. Confirm `events.tsv` is not empty:

   ```bash
   wc -l events.tsv
   ```

6. Review `metadata.txt` for accidental personal information.
7. Do not modify or redact the raw `.pklg` files.

# Part 10: Package and export

In Finder:

1. Open the Desktop.
2. Select the `airpods-smart-routing-capture` folder.
3. Control-click it.
4. Choose **Compress “airpods-smart-routing-capture”**.
5. The result should be:

   ```text
   airpods-smart-routing-capture.zip
   ```

6. Export that ZIP to this Linux workspace or attach it here.

Do not publish the ZIP or upload it to a public issue. Raw Bluetooth logs can contain:

- Bluetooth addresses.
- Device names.
- Nearby-device traffic.
- Persistent or session identifiers.
- Potential account-derived protocol fields.

I will keep the raw capture out of Git, isolate only the relevant AirPods ACL/L2CAP/AACP stream, and create sanitized fixtures with pseudonymous addresses.

# Things not to do during this first session

Do not:

- Factory-reset the AirPods.
- Choose **Forget This Device** on the iPhone.
- Remove the AirPods from the Apple Account.
- Sign out of the Apple Account.
- Change the Mac Bluetooth address.
- Run Linux and let it repeatedly reconnect in the background.
- Filter PacketLogger down to only Bluetooth events you recognize.
- export only screenshots or text.
- Delete the original `.pklg` files after converting them.
- Capture unrelated sensitive activities for a long period.

A clean 5–10 minute trace around a known switching sequence is much better than an hour-long unrestricted Bluetooth capture.

# If the Mac uses a different Apple Account

If the Mac is not using the same Apple Account as your iPhone:

1. Do not put your personal Apple Account on a borrowed Mac solely for this experiment unless it is a machine you trust.
2. Check whether automatic Mac↔iPhone AirPods switching works anyway.
3. If it does work, perform the full capture; observed behavior matters more than our assumption.
4. If it does not work, collect only:
   - `01-bootstrap.pklg`
   - one Mac playback start/pause sequence
   - `metadata.txt` noting `same_apple_account=no` and `native_automatic_switching_verified=no`

That trace will still serve as a useful negative/control sample, but it will not be sufficient by itself to implement the authenticated native relay.

# What will happen after you export it

Once the ZIP is available here, I will:

1. Inspect the PacketLogger structure without modifying the original.
2. Identify the AirPods connection and relevant ACL handles.
3. Reassemble L2CAP/AACP payloads.
4. Extract all `0x0010` and `0x0011` frames.
5. Align each frame with `events.tsv`.
6. Compare the two repeated switching runs.
7. Determine whether the payload contains ordinary OPACK state, an enrollment announcement, a cryptographic/account-derived field, or some combination.
8. Produce a sanitized fixture corpus.
9. Implement the independently derived OPACK subset and relay state machine if the captures provide enough information.
10. Tell you exactly what remains unknown before sending any experimental relay packet to the AirPods.

The single most valuable outcome is a `01-bootstrap.pklg` from a Mac that demonstrably switches your AirPods automatically with your iPhone. That capture should tell us whether the missing Linux behavior is an unimplemented OPACK announcement or a deeper Apple-account trust/enrollment mechanism.
