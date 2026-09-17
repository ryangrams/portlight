# Portlight iPhone — physical device test script

This script covers every acceptance item that the simulator cannot prove. Record each result in
`ACCEPTANCE.json` as `{date, command/steps, result, artifact}`. A device item never passes on simulator
evidence alone. Allow about 75 minutes, plus the 30-minute soak.

## 0. Setup (once)

1. **iPhone.** Use iPhone 17 Pro "StrangerAlps", or any iPhone on iOS 17 or later. For the iOS 17 floor,
   also check an older supported phone. Unlock it, connect it by cable to RG Mac Studio, and trust the Mac.
   Turn on Developer Mode (Settings › Privacy & Security › Developer Mode).
2. **Test Mac.** It must be explicitly consented, with harmless apps open: TextEdit, a Finder window, and a
   test app that logs `NSEvent` clicks, including `clickCount`.
   - Never use a live studio host unless its owner has agreed. A physical iPhone can't reach the loopback-only fixture.
   - Run Portlight Host on the test Mac with a test password.
   - Note the host's "Connection Details" fingerprint.
   - Have at least two displays: one Retina and one standard, ideally with one at a negative origin and one portrait.
3. **Install.**
   ```sh
   scripts/studio scripts/test-device --udid <device-udid>
   ```
   This builds with the Studio's Apple Development identity, installs, and runs the device smoke test. It never uploads anything.
4. **Evidence.**
   - Screen recordings: Control Center › Screen Recording.
   - Screenshots.
   - The Diagnostics sheet: More › Diagnostics › Export.
   - For timing, a 240 fps slow-motion video from a second phone.

## 1. First connection and permissions — PRIV-01, NET-01, NET-04

1. **Local Network prompt.** Launch fresh, add the test Mac by IP, and tap Connect.
   - The Local Network prompt appears.
   - Tap **Don't Allow**. Expect "Allow Local Network Access" with Open Settings. There must be no crash and no retry loop.
   - Allow it in Settings, return, and tap Try Again. The connection proceeds.
2. **No other permission prompts.** At no point does the app ask for screen recording, the microphone,
   Bluetooth, or tracking.
3. **Trust.** The trust sheet shows a fingerprint identical to the host's Connection Details.
   - Cancel: "Computer Not Trusted", and the password is not sent (the host log shows no authentication attempt).
   - Connect again and choose Trust and Connect: it connects.
4. **Changed certificate.** Reset the host's identity (use a test host only), then reconnect. Expect
   "Computer Identity Changed" with the old fingerprint, and no automatic reconnect.
5. **Failure messages.** Each must be distinct. The simulator already shows each card
   (`evidence/e2e/screenshots/`). On the phone, note the title you get:
   - wrong password: "Password Not Accepted"
   - host app quit: "Portlight Host Isn't Listening"
   - wrong IP on the same subnet: "The Computer Didn't Answer", or "Can't Reach the Computer" if the phone
     gives up on the address sooner
   - an address reachable only over a VPN, with the VPN off: "Can't Reach the Computer"
   - Wi-Fi and cellular off: "No Network Connection"
   - another viewer already connected: "Another Viewer Is Connected". Try Again connects once that viewer
     disconnects.

## 2. Input — INPUT-01 through INPUT-04, DISP-02

Record the screen and the test app's event log throughout.

1. **Trackpad** (default):
   - One-finger move: the cursor moves smoothly and stays within the displays.
   - Tap: left click at the cursor.
   - Double tap: the test app logs `clickCount` 2 (host-dependent; note the result).
   - Two-finger tap: right click.
   - Two-finger pan: scroll; content follows your fingers.
   - Pinch: local zoom, with no scroll.
   - Tap, then press and hold and move: drag.
2. **Direct:**
   - Tap: click where you touched.
   - One-finger pan: moves the view only; nothing happens on the Mac.
   - Long press, then move: drag.
3. **Pan:** nothing reaches the Mac. Pinch and pan move the view only.
4. **Mouse controls:** middle click; Hold Left, then move, then release; Hold Right.
5. **Modifiers:**
   - ⌘ latched + click: ⌘-click, then ⌘ releases.
   - ⇧ locked: two shift-clicks.
   - ⌥-drag a Finder file: it copies.
   - Every modifier clears on Disconnect, on backgrounding, on a mode change, and on View Only.
6. **Interruptions mid-drag** (INPUT-03). During a drag in TextEdit, in turn:
   - Pause
   - View Only
   - switch mode
   - press Home
   - Disconnect
   - pull down Control Center

   After each, confirm on the Mac that no button or key stays stuck: typing and clicking behave normally.
7. **Text** (INPUT-04):
   - Software keyboard: "héllo wörld 👋🏽 👨‍👩‍👧" arrives exactly once.
   - Dictation.
   - Hardware keyboard: arrows, ⌘C/⌘V on the Mac, F1–F12, keypad, and key repeat.
   - Type Pasted Text on 300 characters with emoji: all of it arrives, typed into the focused field, and the Mac clipboard is unchanged (PASTE-01; also confirm there is no system paste prompt except the explicit control).
   - Type Pasted Text on more than 4,096 characters: "Text Shortened" appears, and only the first 4,096 characters arrive (PASTE-01). Note how long the typing takes.
8. **Displays** (DISP-02):
   - Select displays 1 and 3: they sit side by side on the phone.
   - Drag a window across the compacted boundary: the pointer targets the correct Mac display throughout.
   - A Retina and a standard display with the same logical size appear the same size.
   - Negative-origin and portrait displays are placed correctly.

## 3. Viewport and layout — VIEW-01

1. **Rotation.** In Fit, rotate portrait → landscape → portrait: the view refits each time.
2. **Zoom anchor.** Zoom to a spot and rotate: the same spot stays centered.
3. **Keyboard.** Showing and hiding the keyboard keeps the anchor.
4. **Resolution.** Changing HD → FHD doesn't move the view.

## 4. Audio — AUDIO-02

1. **Audio on** (AAC 96). Play a test tone on the Mac. Then switch displays, resolution and color while it
   plays: no restart and no gap longer than 150 ms.
2. **Route and interruptions:**
   - Unplug headphones: "Audio Paused" appears, and Resume works.
   - A phone call or Siri interrupts audio, which resumes afterwards.
   - Bluetooth headphones: note the latency.
3. **Congestion.** Saturate video with a full-screen video on the Mac:
   - Diagnostics' queued audio stays at or below 250 ms.
   - Record underruns and drops.
   - Repeat on a Personal Hotspot link.

## 5. Lifecycle and privacy — LIFE-01

1. **Background mid-session.**
   - The app switcher shows the privacy cover, never remote pixels.
   - The host shows the viewer disconnected within a few seconds.
2. **Foreground.** Expect "Reconnecting" over the frozen frame.
   - Zoom and pan still work.
   - Taps do nothing until connected.
   - Then it reconnects with the same displays.
3. **Screen stays awake.** Auto-Lock does not trigger during a connected session, and works again after Disconnect.

## 6. Accessibility — UX-01

1. **VoiceOver.** Walk through Connections → detail → Connect → Session chrome → every sheet.
   - Every control is labeled.
   - Selected states are announced.
   - The remote surface is announced with its custom actions.
2. **Display settings.** Try each:
   - largest Dynamic Type
   - Bold Text
   - Increase Contrast
   - Reduce Transparency
   - Reduce Motion
   - Dark Mode
3. **Controls.** Every control can be hit with one thumb, and none is obscured by the Dynamic Island or home indicator.

## 7. Performance — PERF-01

Use a Release build. For each named link profile, record the median, p95 and sample count, with at least three runs:

| Profile | Setup |
|---|---|
| LAN | nothing |
| 10 Mbps / 30 ms | Network Link Conditioner on the phone: Settings › Developer › Network Link Conditioner, custom profile |
| 2 Mbps / 80 ms | same |

Measure:
1. **Local gesture timing.** Pinch and pan under incoming video, measured with Instruments' Animation Hitches, or the display-link stats in Diagnostics.
2. **Input-to-photon.** 240 fps video of a tap and the test app's marker change.
3. **Throughput and freshness.** Receive Mbps, updates/s and frame age from Diagnostics.
4. **Memory.** Peak and resident memory, with Instruments Allocations/VM, on 3 displays at HD and at FHD.

## 8. Soak — SOAK-01

Run 30 minutes, with 3 displays, audio on and mixed activity:
- one network switch (Wi-Fi ↔ cellular)
- two background/foreground cycles

Record at the start, at 15 minutes and at 30 minutes:
- memory
- thermal state (Diagnostics)
- decoder queue
- audio queue

Pass when all of these hold:
- memory is flat within ±10%
- queues stay bounded
- no input is stuck at the end
- reconnects succeed
