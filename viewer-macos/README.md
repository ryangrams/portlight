# Portlight for macOS

Portlight is the native macOS viewer from Studio Upgrade. Requires macOS 14.4 or newer. Build with Xcode Command Line Tools:

```sh
./build.sh
open 'build/Portlight.app'
```

Preview builds are ad hoc signed and are not yet Developer ID signed or notarized.

## Connect

The **Connections** window contains a saved-computers sidebar and a simple Computer / Password form. Choose a saved connection or enter a computer name or IP address, then click **Connect**. **Advanced** contains the port (default 5920), ZeroTier settings, and Save Connection.

Compare a new computer’s SHA-256 certificate fingerprint with **Connection Details** in Portlight Host before trusting it. Changed certificates require explicit approval. Saved passwords go to macOS Keychain only when selected in the Save Connection dialog. Existing connection storage and Keychain identifiers remain compatible with the earlier preview.

Authentication opens a separate viewing window. Its compact native toolbar contains the computer name/status, **Displays**, **Fit/zoom**, **Audio**, and **View settings**. The remote picture fills the rest of the window. Disconnecting or closing the viewing window returns to Connections.

## View and control

**Displays** chooses one or more displays without reconnecting. **View settings** controls HD/FHD/QHD/UHD resolution, color mode, Optimize For (Automatic / Text & controls / Video), frame rate, bandwidth limit in Mbps, panning, Allow Control, and Pause Streaming. Unsupported resolution choices are disabled. An Automatic bandwidth limit sends `0` over the existing protocol.

Resolution controls the computer’s transmitted output size. Zoom changes only local viewing geometry. Fit Displays, Fit This Display, Actual Size, Zoom In/Out, and macOS fullscreen controls remain available. Option-scroll pans the local viewport; ordinary scroll goes to the remote computer. **Control-Option-Escape** releases remote keys and returns local focus. Clicking a local control, changing selection, minimizing, losing focus, or disconnecting also releases held input.

Audio is off by default. The initial codec is 24 kHz mono μ-law, approximately 192 kbps before transport overhead. Minimizing pauses both image and audio subscriptions. Disabling Allow Control enables view-only mode.

Display geometry remains stable when panned out of sight, but zero-area subscriptions suppress unnecessary image updates. PNG/JPEG rectangles and negotiated canvas dimensions are bounded and checked before decoding. Obsolete subscription revisions are discarded.

The interface follows the system appearance and accessibility settings. Light/dark appearance overrides exist only for synthetic screenshot tests. Native popovers and materials respect reduced-motion/transparency preferences; no live remote pixels are recolored by the viewer theme.

## OSC and ZeroTier

OSC listens on **localhost UDP 19790** using the shared contract in `../PROTOCOL.md`. `/su/remote/state/get` replies to its sender without secrets. The UI and OSC use the same actions; existing `/su/remote/monitors/select` and preset addresses remain unchanged for compatibility. LAN OSC listening is not implemented in this preview.

The bundled optional `su-zerotier` helper uses an already installed local ZeroTier service. Advanced → ZeroTier shows networks and lets a saved connection select its required network and explicit networks it may temporarily pause. Changes occur only when connecting. Restoration runs on disconnect and quit; pending recovery offers Restore or Keep Current Networks. Local token access may require additional setup. Tokens are never exported in saved connections or OSC replies.

## Verification

```sh
'build/Portlight.app/Contents/MacOS/su-remote-viewer' --self-test
python3 test-integration.py
python3 test-appearance.py
```

The integration test starts a temporary loopback fixture, uses an exact test certificate fingerprint, and verifies real TLS/WebSocket reception, decoded image tiles, monitor selection, and Connections → Viewing → Connections transitions. It writes `build/integration-report.json` and `build/integration-viewer.png`. Set `PORTLIGHT_TEST_SERVER` to use a specific local fixture executable.

The appearance test first runs 17 native UI regression checks, including cancellation during a stubbed ZeroTier activation, then generates 12 bounded native captures under `build/design-review`, plus `index.json`: Connections and Viewing in light/dark at normal/minimum sizes, and both toolbar popovers in each appearance. It uses synthetic connection/display data, disables OSC during capture, and never connects to a computer, captures a real desktop, sends input, changes ZeroTier networks, or reads Keychain passwords. CI can run it with the repository’s `.test-venv/bin/python`.

A single capture can be generated with:

```sh
'build/Portlight.app/Contents/MacOS/su-remote-viewer' \
  --ui-snapshot setup --appearance dark --size minimum --snapshot /tmp/portlight.png
```

Use `session` for the viewing window; add `--popover settings` or `--popover displays` to capture the anchored panel.

Current limitations: no H.264 decoder, native IME/composed-text input, independent audio volume control, or multiple simultaneous viewing windows. Real capture/control/audio still require a consented target-machine acceptance test. PNG/JPEG and reduced-color modes are supported.
