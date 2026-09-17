# Portlight iPhone — build, install and signing

Everything is local. Nothing here uploads to App Store Connect or TestFlight.

## Requirements

- **For iOS builds:** a Mac with Xcode 26.6 or later and an iOS 17+ SDK. In this setup that is RG Mac
  Studio (`ssh studio`). Other Macs drive it with `scripts/studio`, which syncs the sources to an isolated
  mirror (`~/SUDev/portlight-ios-work/app`) and copies the evidence back.
- **For core tests only:** any Apple silicon Mac with Command Line Tools. The PortlightKit package tests
  run there under `swift test`.

## Simulator

```sh
scripts/studio scripts/build-simulator        # prints the .app path
scripts/studio scripts/capture-ui shell       # installs, launches, screenshots light + dark
scripts/studio scripts/test-e2e               # isolated fixture host + UI run: trust, three real displays
```

The app appears on the simulator's home screen as **Portlight**. To connect a simulator to a Portlight Host
yourself, start an isolated fixture host on the same Mac (`eval "$(scripts/fixture-host start)"`) and add a
connection to `127.0.0.1` on the printed port with the password `fixture-password`. The fixture's password
is synthetic; never use a studio password in scripts.

## Physical iPhone (development signing)

1. Connect and unlock the iPhone. Trust the Mac, and turn on Developer Mode
   (Settings › Privacy & Security › Developer Mode).
2. Find its identifier with `xcrun devicectl list devices`. It must show as available.
3. Build, install and launch:
   ```sh
   scripts/studio scripts/test-device --udid <device-udid>
   ```
   - The build signs with the Studio's Apple Development identity, team `QJQY4YSGUQ`. Override it with
     `PORTLIGHT_TEAM_ID`.
   - The first install on a new device, or of a new App ID (`studio.upgrade.remote.viewer.ios`), needs
     `--allow-provisioning`. That lets Xcode register the device and create the development profile on
     the developer account, so the account owner decides when to use it.
   - Add `--ui-test` to run the launch UI test on the device.
4. On the iPhone, trust the developer if asked (Settings › General › VPN & Device Management).
5. Follow `docs/DEVICE-TEST-SCRIPT.md`, and record the results in `ACCEPTANCE.json`.

## Connecting to a Mac

Install Portlight Host on the Mac, set a password, and start sharing. In the viewer, tap **+ › New
Connection**, enter the Mac's name or IP address, the password, and the port (default 5920), then Connect.
The first time, compare the fingerprint shown with **Connection Details** on the Mac before choosing
**Trust and Connect**. Your password is sent only after the Mac's identity is trusted.

## Tests

```sh
scripts/test-unit                 # PortlightKit on this Mac (+ iOS Simulator runs where Xcode exists)
scripts/test-integration          # real fixture host + mock host, macOS
scripts/studio scripts/test-unit  # macOS + iOS Simulator + hosted app tests
scripts/studio scripts/test-ui    # UI tests and gallery screenshots
```
