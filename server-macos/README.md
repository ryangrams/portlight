# Portlight Host for macOS

Native Swift/AppKit menu-bar application for macOS 15 and later on Apple Silicon. No third-party runtime, Terminal launcher, VNC service, or existing studio installation is required.

## Build and run

Run `./build.sh --test` with Apple's Command Line Tools installed. The result is `build/Portlight Host.app`. Copy that app to Applications and open it. The preview is ad-hoc signed; a public release needs a Developer ID signature and notarization.

Use the menu-bar display icon to set an eight-or-more-character connection password. Grant the app Screen & System Audio Recording permission for capture and Accessibility permission for control. Start Sharing, then use Connection Details to obtain the port and certificate fingerprint. Default port is 5920; the viewer must compare and trust the displayed fingerprint before entering the password.

The menu includes Stop Sharing, port/password controls, monitor identification, launch at login, and optional automatic server start when the app opens. Changing the password disconnects the current viewer. Quitting the app stops its server and all capture streams.

## Working implementation

- TLS WebSocket with one authenticated viewer session, one port, stable monitor UUIDs, and a monitor subscription revision.
- Only subscribed, visible displays capture and produce images. Switching monitor selections stops their previous streams. Empty visible regions stop that display's capture; audio may retain one 2×2, 1-fps capture stream solely to capture the system mix.
- HD/FHD/QHD/UHD caps enforced before encoding, with one common limit and native fallback. Portrait sources preserve orientation and aspect ratio.
- Desktop sends changed PNG rectangles; motion sends JPEG regions. Auto uses JPEG for broadly changing images and restores lossless detail when motion settles. Reduced-color modes quantize to 16 grayscale shades, RGB332 (256 colors), or RGB565 and use PNG. Gray16 uses a standard 4-bit grayscale PNG with two pixels per byte; its decoded intensity levels stay identical to version 0.1. Other modes retain their established pixel representation.
- Region subscriptions crop before encoding. Bounded 32-MiB output queue, up to 32 acknowledged packets in flight with a 2-MiB in-flight byte limit (one larger initial image is allowed alone), latest-frame dropping before encoding, and average bandwidth token bucket. A single large frame can temporarily exceed a configured one-second budget; subsequent output pays that debt. This is not a strict instantaneous wire-rate guarantee.
- Optional system audio is off by default. ScreenCaptureKit system mix is converted to 24-kHz mono G.711 μ-law, 20-ms packets (192 kbit/s payload before transport). No microphone capture. Audio shares the configured bandwidth budget and drops stale data under congestion.
- Remote pointer/button/wheel and keyboard events target only selected display UUIDs. Held input releases on pause, view-only, display change, disconnect, or server stop.
- Password verifier is PBKDF2-HMAC-SHA256 (150,000 iterations) with random salt. EC TLS identity is generated locally with the system OpenSSL executable; PKCS#12 is imported into process memory only. Identity and verifier files remain in user Application Support with restrictive permissions. Failed authentication is rate limited. No passwords are logged.

## Testing without screen permissions

The synthetic fixture has three monitors, with monitor 2 limited to FHD and monitors 1 and 3 supporting UHD. It does not capture the computer, inject input, or transmit audio. It only listens on 127.0.0.1.

```sh
printf '%s\n' 'temporary-test-password' | \
  'build/Portlight Host.app/Contents/MacOS/SURemoteServer' \
  --fixture --port 15920 --data-dir /tmp/su-remote-fixture --password-stdin
```

`--self-test` validates scaling, common native limits, portrait display geometry, color-mode tile generation, unchanged-frame suppression, visible cropping, μ-law silence, password persistence, native TLS identity loading, and binary framing. End-to-end WebSocket tests live in the parent application's tests directory.

Protocol stats include average capture-raster/quantization/difference/codec time, queue bytes, and frames skipped under backpressure. They measure host production; viewer decoding, network delay, and OS capture overhead are separate.

## Preview limits

One active viewer at a time; another authenticated connection receives an explicit busy response. H.264 hardware encoding and shared multi-viewer capture are not implemented. Audio and actual ScreenCaptureKit/input permissions require real-machine verification. Codec choice remains a desktop/motion heuristic, not a video-playback guarantee. Repeatable encoder benchmarks and their scope are documented in `../benchmarks/README.md`.

**Login at startup is not login-window access.** The app runs in a logged-in user's GUI session. Login-window/fast-user-switch support needs a separately signed privileged transport daemon and a capture/input agent installed for both LoginWindow and Aqua sessions, plus tested handover and consent. This preview does not install a root daemon or claim unattended pre-login access. FileVault preboot unlock is separate and unsupported.
