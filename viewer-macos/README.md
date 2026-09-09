# Studio Upgrade Remote — macOS viewer

Native AppKit viewer for the SU Remote v1 server. Requires macOS 14.4 or newer. Build on Apple Silicon with Xcode Command Line Tools:

```sh
./build.sh
open 'build/SU Remote Viewer.app'
```

The app is ad-hoc signed for development. The `build.sh` script also runs offline protocol/model tests. Developer ID signing and notarization are not configured for this preview.

Enter a Mac's address, port (default 5920), and server password. Compare the SHA-256 fingerprint with **Connection Details** on the server before trusting a new server identity. Changed certificates require a new explicit confirmation. Saved passwords go to the macOS Keychain only when selected in the Save Preset dialog.

Use monitor checkboxes to choose screens within one encrypted connection. HD, FHD, QHD, and UHD control the server's output size; zoom only changes viewer display geometry. Unsupported presets are disabled. Audio is off by default. The initial audio codec is 24 kHz mono μ-law, approximately 192 kbps before transport overhead.

**Controls:** Fit all, Fit monitor (the clicked screen), 100%, zoom, fullscreen, scroll bars, and pointer edge panning. Option-scroll pans the local viewport; ordinary scroll goes to the remote Mac. Control-Option-Escape releases remote keys and returns focus to the local window. Minimizing pauses image and audio subscriptions. View-only disables remote input. The server can still restrict control when macOS permission is unavailable.

The selected monitors retain their layout when panned out of sight, but their zero-area subscriptions prevent unnecessary image updates. Dirty PNG/JPEG rectangles are bounded and validated before decoding, and obsolete subscription revisions are discarded.

**OSC:** Localhost UDP 19790, using the shared addresses in `../PROTOCOL.md`. `/su/remote/state/get` replies to the sender, with no password or network token. Native UI and OSC use the same actions. External LAN OSC listening is not implemented in this preview.

**ZeroTier:** The optional bundled `su-zerotier` helper uses an already installed local ZeroTier service. The ZeroTier dialog shows networks and lets a preset choose a required network plus explicit networks it may temporarily suspend. Policies do nothing until connecting. The app restores its transaction on disconnect/quit, and offers Restore or Keep Current Networks for saved recovery records. Local service token access may require additional setup; the app never exports that token.

## Development verification

```sh
'build/SU Remote Viewer.app/Contents/MacOS/su-remote-viewer' --self-test
'build/SU Remote Viewer.app/Contents/MacOS/su-remote-viewer' --demo --snapshot /tmp/su-remote-viewer.png
python3 test-integration.py
```

Integration uses an isolated fixture server on loopback, temporary credentials, and an explicitly supplied exact TLS fingerprint. It exercises real native WebSocket reception and PNG/JPEG decoding, then writes a report and screenshot under `build/`. It does not grant capture permissions, capture a real desktop, send input to the studio, or change ZeroTier networks.

Current limitations: no H.264 decoder, no native IME/composed-text entry, no independent audio volume control, one viewer window, and no automatic installer for login-window server access. PNG/JPEG and lossless reduced-color modes are supported. Real screen capture/control and audio require a consented target-machine acceptance test.
