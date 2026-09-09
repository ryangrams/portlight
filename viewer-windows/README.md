# SU Remote — native Windows viewer

Native Win32 viewer for Windows 10 and later. Built without a browser engine or third-party GUI runtime. Uses WinHTTP for encrypted WebSocket transport, WIC for image decoding, GDI for drawing, and waveOut for audio playback.

Build on macOS using `./build.sh`, which downloads the pinned LLVM-MinGW toolchain to a temporary cache if `LLVM_MINGW` is not supplied. Binaries are emitted in `dist/` for x86 (32-bit), x64, and ARM64.

The application requests confirmation of the server's SHA-256 certificate fingerprint before sending the session password. Confirm it against the server's displayed fingerprint. An unexpected certificate change requires explicit approval. Passwords are never saved in connection presets.

OSC is bound to localhost UDP 19790; use `/su/remote/state/get` for state. There is no shell-command OSC endpoint. Windows Firewall is not changed by the app.

Current builds require validation on real Windows computers; compiling a binary is not equivalent to testing its behavior on Windows.

## Using the viewer

Keep `SU Remote Viewer.exe` and `su-zerotier.exe` together. Enter the Mac's address (default port 5920) and server password. Verify the first-connection certificate fingerprint against the server, then connect. Click monitor names to toggle them; several monitors share one encrypted session. Unselected monitors are unsubscribed, and zoomed-out-of-view regions are paused.

Choose HD/FHD/QHD/UHD before transmission; unavailable sizes are gray. Native is a fallback only for displays smaller than HD. Desktop uses sharp lossless tiles, Motion uses JPEG tiles, and Adaptive lets the server choose. This viewer currently advertises PNG/JPEG; hardware H.264 decoding is not implemented. Audio is an optional 192-kbps mono preview and starts off.

Fit, 100%, minus/plus, and Ctrl+mouse-wheel change local zoom. Use scroll bars to pan, or enable pointer-following panning. F11 enters/exits fullscreen, and Escape exits fullscreen. Clicking the canvas gives it keyboard control. View-only and Pause release held input.

Name and save presets with the editable preset selector. Passwords are not saved. For ZeroTier, enter the desired network ID and comma-separated IDs of only the networks the preset may suspend, then save and approve that concrete policy. Connecting activates it, disconnecting restores it. Network Status shows pending recovery and offers Restore, Keep current networks, or Cancel. Unrelated networks are not managed.

Settings and trusted fingerprints are stored under `%LOCALAPPDATA%\Studio Upgrade\SU Remote\viewer.json`.

## Validation

`./test.sh` runs portable framing/allocation tests and 10,000 malformed messages under address/undefined-behavior sanitizers on macOS. Each native executable supports `--self-test`, returning JSON and a nonzero exit code on failure; it exercises Windows WIC decoding, certificate SHA-256 hashing, secure endpoint parsing, OSC bounds, zoom/pan mapping, and memory limits.

For CI, `--integration-test` uses a loopback-only TLS fixture. Set `SU_REMOTE_TEST_HOST` to `127.0.0.1:port`, `SU_REMOTE_TEST_FINGERPRINT` to its exact uppercase colon-separated SHA-256 leaf fingerprint, `SU_REMOTE_TEST_PASSWORD` to its disposable password, and `SU_REMOTE_TEST_REPORT` to the JSON output path. Fixture monitors are `fixture-1`, `fixture-2`, and `fixture-3`. The viewer selects the first monitor, switches to the third at two seconds, selects first+third at four seconds, and exits at seven seconds. It never accepts an unverified certificate in this mode. The fixture runner is `../tests/windows_integration.py`.
