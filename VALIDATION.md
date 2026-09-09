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
