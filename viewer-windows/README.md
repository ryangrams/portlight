# Portlight for Windows

Portlight by Studio Upgrade is a native Windows viewer for Portlight Host on macOS. Builds target Windows 10 and later on x86 (32-bit), x64, and ARM64. The September 10 update brings the current Mac viewer's connection management, viewing controls, display layout, and media options to Windows.

## Install this update

Quit the old Windows viewer. Extract the matching ZIP and run `Portlight.exe`, keeping `su-zerotier.exe` beside it. Existing saved connections and trusted certificates remain in `%LOCALAPPDATA%\Studio Upgrade\SU Remote\viewer.json`; replacing the application does not remove them. The executable embeds the Portlight icon and file version **0.2.0.1**.

Use the latest Portlight Host for AAC audio and the host's audio scheduling improvements. Older hosts keep working with legacy mono audio. The host's capture/privacy permissions are managed on the Mac; updating this viewer does not change them.

## Connections

The leading sidebar button shows or hides the compact connection list. Hiding it allows a narrower window; showing it widens a window that would be too small. Sidebar animation follows the Windows animation preference. Groups expand with one click. A connection's single click selects it for editing; double-click or **Connect** starts the session.

Use the bare **+** and **−** at the bottom to add connections/groups or remove the selected item. Drag connections into groups or reorder them; drag groups to rearrange them. Right-click offers Rename, Remove, and Move to Group; F2 renames. The optional name field comes first, followed by Computer, Password, and Port in native Tab/Shift+Tab order. **Save Connection** changes to **Update Connection** when editing a saved item. An unnamed connection is saved as **Saved Connection**.

**Save password securely** stores an optional password in Windows Credential Manager under a stable connection identifier. Selecting a row does not read the credential. The password is retrieved when connecting, and only for the matching saved address. Credentials are not written to the settings JSON. Renaming a connection keeps its credential identifier.

**ZeroTier…** pairs a connection with a single network. Choose a known network or add its ID. Portlight can pause other networks paired in Portlight when switching, while leaving unrelated networks alone. Network preparation has a status message and supports cancellation; the helper waits for authorization/readiness before connecting. **Disconnect network when session ends** is optional and off by default. Leaving it connected makes subsequent connections faster. Failed or canceled connections restore the earlier network state. Refresh also exposes pending recovery transactions.

## Viewing

The grouped toolbar places the computer name and state at the leading edge and **Disconnect** at the right. It wraps groups when needed. Right-click the toolbar for **Icons** or **Icons and Text**. Native window controls, Segoe UI, system light/dark appearance, high contrast, and per-monitor DPI behavior are retained.

- **Control On / View Only:** an explicit selected state and label. **Pause** disables control, dims the retained picture, and adds a large pause symbol.
- **Resolution:** HD / FHD / QHD / UHD, with 2×2 / 3×3 / 4×4 / 5×5 grid icons. Resolutions that would upscale a selected source are unavailable. The active option has an accent outline. A host below HD uses its native size automatically.
- **Color:** Full Color, 256 Colors, or 16 Shades of Gray, with gradient, palette, and grayscale icons. The old 16-bit option is removed; saved legacy choices migrate to Full Color.
- **Displays:** every fresh connection selects all screens. The map uses the host's logical layout, matching Arrange Displays proportions even with mixed Retina resolutions. Compact maps allow direct clicks; small targets open a 280×140 map. Space/Return in that popup provides an accessible display list. Unselected displays are not requested. The viewing canvas removes empty bands between remaining displays, so 1 + 3 can appear adjacent while the map retains the physical arrangement.
- **Zoom:** Zoom In, Zoom Out, 100%, Fit, in that order. Steps are 10%. Fit remains centered during resizing and constrains the window to the combined display aspect ratio, subject to minimum size and available desktop space. Fullscreen keeps the toolbar; F11 toggles fullscreen and Escape exits. Pan toggles between pointer-following and manual scroll bars. Ctrl+wheel changes local zoom.
- **Audio:** off initially, including recalled connections. Supported hosts offer AAC mono 48 kbps or stereo 96, 160, and 320 kbps. Audio reception bypasses the image UI queue; decoding/playback use a separate bounded worker. Video subscription changes do not reset that worker. Audio pauses with the session or minimization. Legacy hosts use 24 kHz mono μ-law.
- **Mbps ▾:** combines video bandwidth, audio quality, and Automatic / Text & Controls / Video optimization. Video defaults to Automatic; blank or 0 removes a manual ceiling. Frame rate is requested up to 60 and adapts through host backpressure, with no user fps selector. The displayed fps comes from host changed-image updates averaged over selected displays, not the number of tiles.
- **Smooth gradients:** the Mac host's optional fixed ordered dither for Video with reduced colors. It adds no frame buffering but can increase data use, so it is off by default.

The renderer accepts JPEG, RGB PNG, indexed PNG8, and packed 4-bit grayscale PNG. It reuses an offscreen canvas to avoid exposing partially painted frames. Audio and video still share the protocol's TLS/WebSocket connection; network head-of-line blocking remains possible. Windows AAC uses Microsoft's Media Foundation components; Windows N editions need their Media Feature Pack. H.264 decoding is not implemented.

OSC remains on localhost UDP 19790 with the existing `/su/remote/...` commands. No general command execution endpoint is exposed. See the included `PROTOCOL.md`.

## Validation and development

`./build.sh` verifies a pinned LLVM-MinGW toolchain and builds x86, x64, and ARM64. `./package.sh` creates the three update ZIPs. `./test.sh` runs framing/allocation and logical display-layout tests, including 10,000 malformed messages and 10,000 randomized layouts under AddressSanitizer and UndefinedBehaviorSanitizer.

On Windows, `Portlight.exe --self-test` checks WIC image decoding, coordinates, connection tab order, safe row selection, secure endpoints, and silent Media Foundation decoding of AAC fixtures produced by the actual Mac encoder. The embedded synthetic fixtures contain no recorded audio. Regenerate them from the repository root with:

```sh
swiftc shared/AAC.swift viewer-windows/tests/generate-aac-fixtures.swift -o /tmp/portlight-aac-fixture
/tmp/portlight-aac-fixture viewer-windows/tests/aac-fixtures.json
```

`Portlight.exe --visual-test OUTPUT_DIRECTORY` captures light/dark Connections, collapsed sidebar, Viewing, labels, pause, view-only, display map, and Data Rate states using synthetic content. It does not connect to a computer or load/save real settings. It writes `visual-report.json` and exits. `../tests/windows_integration.py` runs the actual Windows viewer against a loopback TLS fixture, checking all-screens startup, selection changes, indexed/grayscale PNG decoding, and return to Connections.

**Validation for this build:** all three targets cross-compiled without warnings; the portable sanitizer suites and ZeroTier helper's in-memory tests passed. The generated AAC fixtures decoded successfully through the Mac decoder at all four rates. Native Windows UI, WIC/TLS integration, and Media Foundation execution still need to run on Windows: the local Parallels service was unavailable. The existing CI jobs invoke those native tests on x86, x64, and ARM64; they were updated but have not been run for these local changes. This is a local preview, not a published release.

Microsoft's [AAC decoder documentation](https://learn.microsoft.com/en-us/windows/win32/medfound/aac-decoder) describes the raw AAC input and Media Foundation format metadata used by the Windows audio implementation.
