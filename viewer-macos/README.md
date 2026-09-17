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

The appearance test first runs 27 native UI and transport regression checks, including cancellation during a stubbed ZeroTier activation, quit during restoration, visible session errors, and stale connection callbacks, then generates 12 bounded native captures under `build/design-review`, plus `index.json`: Connections and Viewing in light/dark at normal/minimum sizes, and both toolbar popovers in each appearance. It uses synthetic connection/display data, disables OSC during capture, and never connects to a computer, captures a real desktop, sends input, changes ZeroTier networks, or reads Keychain passwords. CI can run it with the repository’s `.test-venv/bin/python`.

A single capture can be generated with:

```sh
'build/Portlight.app/Contents/MacOS/su-remote-viewer' \
  --ui-snapshot setup --appearance dark --size minimum --snapshot /tmp/portlight.png
```

Use `session` for the viewing window; add `--popover settings` or `--popover displays` to capture the anchored panel.

Current limitations: no H.264 decoder, native IME/composed-text input, independent audio volume control, or multiple simultaneous viewing windows. Real capture/control/audio still require a consented target-machine acceptance test. PNG/JPEG and reduced-color modes are supported.

## Display layout and connections

The viewing toolbar provides a display map, HD/FHD/QHD/UHD grid buttons, color mode, Fit, 100%, 10% zoom steps, pause, remote control, edge-follow panning, audio, fullscreen, and disconnect. The map preserves the host's logical display arrangement; inactive displays are dimmed. If a compact map target would be smaller than 28×20 points, click the map to expand it. The viewing canvas removes empty rows/columns between selected displays while retaining their logical proportions. 100% refers to logical desktop points, independently of stream pixel density.

Fit remains active through resize, centers the selected collection, and constrains the non-fullscreen window to the collection's aspect ratio. Pause dims the retained image and blocks control. Pointer drags are routed to the selected display currently under the pointer, even when the drag began on a different canvas. Real application window-drag behavior across skipped host displays still depends on macOS and the application.

Connection names are optional; Save Connection uses “Saved Connection” when blank. The compact sidebar supports groups, a + menu for creating connections/groups, removal with −, and drag-to-group/reorder. Removing a group keeps its connections ungrouped. Double-click a group to collapse or expand it.

ZeroTier pairs one network per connection. Portlight waits up to 30 seconds for that network to become ready before opening the desktop. Other networks paired with Portlight are disconnected first; unrelated memberships remain untouched. The saved “disconnect when the desktop disconnects” option leaves the paired network on normal disconnect; otherwise it stays connected for faster reuse. A canceled or failed connection restores the previous state, with recovery records retained if cleanup fails. No live network mutation occurs while editing a preset.

Audio remains off by default. Updated hosts support AAC mono 48 kbps or stereo 96/160/320 kbps. Older hosts retain legacy 192 kbps mono μ-law audio; unsupported quality options are disabled. “65,536 colors (16-bit)” is intentionally distinguished from “16 shades of gray”; it is not a 16-color mode.
