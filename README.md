# Portlight

**Your screens, closer.**

An open source remote desktop app by **Studio Upgrade**, built for studios and connections where bandwidth matters. Run Portlight Host in the Mac menu bar, connect once in Portlight, and choose the displays you need. Unselected displays stop producing screen data. Both viewers separate connection setup from an uncluttered viewing window and follow the system’s light or dark appearance.

This is an **early preview**, not a production replacement for an established remote-access service. See the current limitations below.

![Portlight Connections](https://raw.githubusercontent.com/ryangrams/portlight/main/docs/images/connections-light.png)

![Portlight viewing window, synthetic displays](https://raw.githubusercontent.com/ryangrams/portlight/main/docs/images/viewing-dark.png)

## Downloads

[Download preview builds](https://github.com/ryangrams/portlight/releases) for:

| Component | Platform |
| --- | --- |
| Server | Apple Silicon Mac, macOS 15 or later |
| Viewer | Windows 10 or later, x86 (32-bit) and x64 |
| Viewer | Windows ARM64 |
| Viewer | Apple Silicon Mac, macOS 14.4 or later |

The Windows downloads are portable: extract the whole folder and open **Portlight.exe**. Keep `su-zerotier.exe` alongside it for the optional ZeroTier controls. The Mac download contains **Portlight Host.app** and **Portlight.app**; copy the apps you need to Applications.

Preview builds are not yet Developer ID signed/notarized or Authenticode signed. macOS or Windows may ask you to approve opening them. Do not disable operating-system protections globally.

## Connect

1. Open **Portlight Host** on the Mac. Its display icon lives in the menu bar.
2. Set a connection password. Grant **Screen & System Audio Recording** for viewing, and **Accessibility** for control. If macOS asks for an app restart after changing permissions, quit and reopen it.
3. Choose **Start Sharing**. Open **Connection Details** to see the port and certificate fingerprint.
4. Open **Portlight** on the other computer. In Connections, enter the Mac's LAN/VPN address and password, then choose **Connect**. The default port is **5920**; change it in **Advanced** if needed. Compare the certificate fingerprint with the server before trusting it.
5. The viewing window opens after authentication. Choose **Displays** in the toolbar to change the selection while staying connected. The toolbar also contains zoom, audio, and viewing settings. Audio starts off.

The server uses its own encrypted protocol. These apps do not connect to TightVNC or other VNC servers/viewers. An existing VNC installation can remain on its own ports.

## Viewing controls

- **HD / FHD / QHD / UHD:** 720p, 1080p, 1440p, or 2160p per display, scaled on the server. The common setting respects the smallest selected display. Images retain their aspect ratio; unavailable higher settings are disabled. Portrait displays retain their orientation.
- **Color:** Grayscale · 16 shades, 256 colors, 16-bit color, or full color. Reduced-color modes are encoded losslessly after quantization. Grayscale uses a packed 4-bit PNG representation to avoid full RGB encoding work.
- **Automatic / Text & controls / Video:** Automatic balances changed PNG regions for desktop detail and JPEG regions for full-color motion, restoring lossless detail when motion settles. Text & controls favors detail; Video favors motion. Reduced-color modes stay lossless.
- **Frame rate and bandwidth limit:** trade motion smoothness for less traffic. The limit is an average target; individual frames can briefly exceed it. Backpressure bounds pending work so congestion does not create an ever-growing delay.
- **Fit, zoom, fullscreen, and pan:** fit all displays or focus one display, zoom in, and use either scrollbars or **Follow pointer** panning. Offscreen screen regions can stop transmitting.
- **Pause / Allow control / Audio:** pause pictures, turn remote control off, or enable the Mac's system audio. Audio is mono preview quality and adds about 192 kbit/s before transport overhead.

## Saved connections and ZeroTier

Saved connections remember the computer, display selection, picture settings, and view controls. The Mac viewer can store a password separately in Keychain; Windows saved connections do not store passwords.

ZeroTier is optional and must already be installed. The viewers can inspect its local service and attach a network policy to a saved connection. Choose the required network and explicitly list the conflicting networks that the saved connection may temporarily leave. The helper leaves those conflicts before joining the selected network, preserves unrelated networks, and saves enough state to restore memberships and network settings on disconnect. An interrupted restoration appears in network recovery controls. If settings changed outside the app, they are preserved for you to review.

No ZeroTier account token or network credentials are bundled in this repository. The helper talks only to the locally installed service. It does not bundle ZeroTier or change the remote server's VPN configuration.

## OSC

Both viewers listen on **127.0.0.1 UDP 19790** for local automation. Controls include connect/disconnect, saved connections, display selection, resolution/color, zoom/fit, fullscreen, pan mode, pause, view-only, and audio. `/su/remote/state/get` replies with current state and no secrets. See [the protocol](PROTOCOL.md#osc-both-viewers) for addresses and argument types.

Companion modules and Stream Deck profiles are not included in this preview.

## Build and test

On an Apple Silicon Mac with Xcode Command Line Tools:

```sh
./build.sh
python3 -m venv .test-venv
.test-venv/bin/pip install -r tests/requirements.txt
.test-venv/bin/python tests/run_e2e.py
./package.sh
```

The Windows cross-build downloads a pinned LLVM-MinGW toolchain. Set `LLVM_MINGW` to an existing installation to reuse it. The apps use native platform APIs; no browser engine, Python runtime, or third-party GUI framework is needed to run them. Python is only used by integration tests.

The synthetic server test uses temporary credentials/state, binds only to localhost, and never captures a real screen or injects input. Automated Windows jobs execute each architecture's self-tests on Windows. See [validation](VALIDATION.md) for what has and has not been exercised.

## Current limitations

- One active viewer per server. Multiple displays share that one connection; multiple simultaneous viewers are not supported yet.
- H.264 hardware video encoding/decoding is not implemented. Video currently uses JPEG regions, so expect higher bandwidth than a mature video-streaming codec.
- Pre-login and fast-user-switch support are not implemented. **Launch at login** opens the menu-bar app after a user signs in; it does not provide access to the login window. FileVault preboot unlock is separate and unsupported.
- System audio, real desktop control, permissions, and all target Windows versions still need real-machine acceptance testing. Cross-compilation and synthetic tests do not establish that every target machine works.
- No clipboard sync, file transfer, internet relay service, or unattended installation.

## Updating from SU Remote

Quit the previous viewer/host before opening the Portlight apps. Replace their app bundles with the new names and keep the Windows helper alongside Portlight.exe. Passwords, trusted certificates, saved connections, and OSC addresses retain their existing storage and identifiers. Update **Portlight Host as well as the viewer** to receive the grayscale encoding improvements. macOS may require you to review permissions after replacing an unsigned preview app.

## Source and license

Fresh Swift/AppKit and C++/Win32 implementation, licensed under [MIT](LICENSE). No GPL VNC implementation was copied into this product. See [third-party notices](THIRD-PARTY.md). Protocol constants such as keysyms are interoperable values, not a reused VNC implementation.

The macOS capture/input layer is separate from the wire protocol so future Linux and Windows servers can implement the same viewer contract. Improvements and focused bug reports are welcome; include the app version and platform, but do not include passwords, VPN access tokens, or private screen contents.
