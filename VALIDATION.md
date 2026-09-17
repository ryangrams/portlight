# Preview validation

This file distinguishes implemented behavior from real-machine acceptance testing. The synthetic fixtures never capture a real desktop or inject input.

## Appearance and navigation

Both native viewers provide a bounded synthetic screenshot mode covering Connections, the viewing window, settings, and minimum window sizes in light and dark appearances. The Windows workflow uploads these screenshots for visual review. Synthetic images contain no private desktop contents. Appearance changes are handled using system preferences; the test-only switches do not change OS preferences.

Native checks cover Connections → Viewing → Connections, cancellation, display selection, and toolbar geometry. Focused regressions cover canceled network activation, restoration before quit, replacement connection intents, stale transport callbacks, and visible session errors. Native Windows image tests decode known 4-bit grayscale samples through WIC and verify their intensity values.

## Local macOS checks

- Native server self-tests: scaling/native limits/portrait geometry; color quantization and changed tiles; visible-region crop; μ-law encoding; password persistence/verification; TLS identity loading; framing.
- Encrypted real-server integration: authenticates over WSS, rejects a wrong password, switches between monitor combinations within the same session, decodes actual PNG/JPEG packets, checks reduced palettes and output sizes, and verifies no frames from unselected, hidden, or paused monitors.
- Native Mac viewer integration: trusts only the fixture's supplied SHA-256 fingerprint, connects through URLSession/WebSocket, receives and decodes real server tiles, changes selected monitors, and exports a screenshot for inspection.
- ZeroTier helper self-tests: explicitly scoped exclusivity, leave-before-join order, restoration, refusal to overwrite manual changes, safe clearing of recovery state, rollback after a failed join, and retry after interrupted restoration. Live local ZeroTier status was read; automated tests never modify real VPN memberships.

## Windows checks

The build workflow cross-compiles native x86, x64, and ARM64 executables, then runs each on a corresponding Windows runner. Tests cover framing and rectangle bounds, WIC decoding, certificate fingerprint hashing, OSC parsing, input coordinate mapping, resolution gating, and secret-free state reports. A separate local TLS fixture exercises the actual WinHTTP connection, monitor selection changes, and image decoding, including the host’s packed 4-bit grayscale PNG format.

Check the [workflow results](https://github.com/ryangrams/portlight/actions) for the exact commit's outcome. A configured test is not a passed test. Windows Server/Windows 11 runner coverage does not establish Windows 10 hardware compatibility.

## Still requires acceptance testing

- Actual screen capture and permissions on the destination Mac, including multiple physical displays, rotated displays, disconnection/reconnection, and display rearrangement.
- Physical mouse/keyboard behavior in editing applications, international layouts, shortcuts, drag, and trackpad scrolling.
- Optional system audio quality, timing, and permission behavior.
- Long-running sessions, constrained real LAN/VPN connections, CPU usage, video workload quality, and reconnects.
- Windows 10 x86 and x64 machines and Windows ARM hardware, including fullscreen and high-DPI layouts.
- Live ZeroTier network activation/restoration and recovery, on a non-production test network.

Pre-login access, H.264, multiple simultaneous viewers, code signing/notarization, Windows/Linux servers, clipboard sync, and file transfer are not implemented in this preview.

## Encoding measurements

The repeatable generated-workload benchmark in `benchmarks/` measures conversion, encoding, and payload size separately. These measurements characterize the supplied fixtures; they are not a claim about actual YouTube playback, real VPN throughput, or every Mac. See its results and method for before/after details.

## September 9 Mac viewer revision

- Native viewer and host builds and self-tests passed, including AAC encode/decode at all four quality settings, logical-point display geometry, and compacted display layout.
- All 37 native UI regression checks passed, including persistent centered Fit on resize, pause blocking input, display toggles, grouped preset persistence, and dragging presets into groups.
- Native viewer WebSocket integration decoded 616 fixture frames with zero rejected frames; protocol end-to-end checks passed. ZeroTier helper self-tests passed, including keeping or disconnecting the paired network after a successful session.
- Visually checked light/dark connection/session windows, the paused overlay, and the expanded stacked-display selector.
- These checks do not establish physical cross-monitor window dragging, live AAC playback, or live ZeroTier switching. The previously running host was left running: UI automation timed out during the final restart/permission verification. The rebuilt host requires live verification, and ad-hoc signing may require renewed macOS grants after replacement.
- Windows viewer UI has not been ported to this design yet.

## Toolbar and keyboard follow-up

Tab and Shift-Tab were verified in the running Mac viewer between Connection name and Computer. Expanded regression coverage includes that key-view loop, port navigation, the three supported color choices, native toolbar customization, and removal of the Settings/fullscreen toolbar items. Host screen capture and Accessibility were restored after a scoped TCC reset; a live local viewer connection streamed successfully. The host remains listening on 5920. The toolbar context menu exposes Icons and Icons and Text; labeled mode uses AppKit's expanded toolbar style.

## September 10 media revision

Protocol tests passed against an isolated rebuilt host, including indexed-color output, viewport selection, pause, and remote-control messages. Encoder validation compares decoded pixels for indexed PNG, verifies packed grayscale/crops, and confirms unchanged-image suppression. A 720p synthetic gradient benchmark measured approximately 21 ms for the preceding RGB PNG 256-color encoder versus 3 ms with indexed PNG; this is a fixture result, not a universal latency claim. Low-amplitude ordered dithering increased reduced-color payloads, so it is opt-in and disabled by default. Audio scheduling/capture changes still require live playback testing under constrained networking; the synthetic protocol host has no audio source.

The final native viewer integration selected all three fixture monitors in its first subscription and decoded 867 frames with zero rejections. All 57 UI regression checks passed. Optional dithering preserves unchanged-frame suppression and is ignored in Text mode; both reduced-color formats decode successfully. The working host was left running, with the new host built separately in `server-macos/build-media/Portlight Host.app`.
