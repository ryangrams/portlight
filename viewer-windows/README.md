# Portlight for Windows

Portlight by Studio Upgrade connects to Portlight Host on a Mac. It is a lightweight native Windows app, with builds for x86 (32-bit), x64, and ARM64. Windows 10 remains the minimum target. Existing SU Remote connections, trusted certificates, and OSC commands remain compatible.

## Connect

Keep `Portlight.exe` and `su-zerotier.exe` together. In **Connections**, choose a saved computer or enter its name/IP address and password, then select **Connect**. Verify the first connection's certificate fingerprint against Portlight Host. Passwords are never saved.

**Advanced** contains the port (5920 by default) and optional ZeroTier network policy. A saved connection can activate its chosen network and pause only the network IDs explicitly listed under **Networks to pause**. Use **Save connection** in Advanced to save the policy before using it. Cancel also works while the network is being prepared. Disconnect and closing the app wait for restoration of the previous network state; Network Status also exposes interrupted-operation recovery.

After authentication, the computer's picture fills the window. The compact toolbar contains **Displays**, **Fit/zoom**, **Audio**, and **Settings**. The back button disconnects and returns to Connections. No computer addresses, password fields, or permanent settings sidebar appear over the viewing area.

- **Displays:** choose one display, several, or all, without reconnecting.
- **Fit/zoom:** fit the selected displays, use 100%, zoom in/out, or enter fullscreen. F11 toggles fullscreen; Escape exits it. Ctrl+mouse-wheel changes local zoom.
- **Audio:** optional computer audio, off by default. Current preview audio uses 192 kbps.
- **Settings:** HD/FHD/QHD/UHD resolution, color mode, optimization for Automatic/Text & controls/Video, frame rate, bandwidth limit in Mbps, pointer-following panning, pause, and Allow control. Blank/zero bandwidth means Automatic. A Native fallback is available for displays smaller than HD.
- **Saved connection:** name the computer/view in Settings and select Save. The saved row then appears in Connections.

Only selected displays and visible regions are requested. The app supports PNG/JPEG tiles and the Host's packed 4-bit grayscale PNGs. H.264 decoding is not yet implemented.

Portlight uses Segoe UI, native Windows title-bar controls, system light/dark appearance, high-contrast colors, and DPI-aware layout. Appearance changes do not recolor remote images. Controls respond immediately and use no ornamental animation, including when reduced motion is enabled.

Settings retain the original location for compatibility:
`%LOCALAPPDATA%\Studio Upgrade\SU Remote\viewer.json`.

OSC listens on localhost UDP 19790. Existing `/su/remote/...` addresses are unchanged; see `../PROTOCOL.md`. No general command-execution endpoint is exposed.

## Build and validate

Run `./build.sh` on macOS. It verifies and caches a pinned LLVM-MinGW toolchain, builds all three architectures, and places complete app folders in `dist/x86`, `dist/x64`, and `dist/arm64`. The Portlight icon and version metadata are embedded in each executable.

`./test.sh` runs framing/allocation tests and 10,000 malformed messages under sanitizers. Each executable supports `--self-test` for native WIC PNG/grayscale decoding, certificate hashing, secure address parsing, OSC bounds, coordinate mapping, and allocation limits.

`Portlight.exe --visual-test OUTPUT_DIRECTORY` is a bounded screenshot test. It uses synthetic saved computers and remote content, opens no network/OSC listener, writes Connections/Viewing/Settings screenshots in light and dark appearances (including small windows), and exits with `visual-report.json`. It neither loads nor saves real connection settings.

`--integration-test` connects only to a loopback TLS fixture. Supply `SU_REMOTE_TEST_HOST=127.0.0.1:port`, `SU_REMOTE_TEST_FINGERPRINT` (exact uppercase colon-separated SHA-256 fingerprint), `SU_REMOTE_TEST_PASSWORD`, and `SU_REMOTE_TEST_REPORT`. It verifies real decoding, one-connection display switching, and the Connections → Viewing → Connections transition. Run through `../tests/windows_integration.py`.
