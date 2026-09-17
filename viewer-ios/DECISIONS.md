# Portlight iPhone viewer — decision log

Concise record of working assumptions and implementation decisions. The handoff in
`verification/Portlight-iPhone-Opus-Handoff-2026-09-10/` (mirrored at `docs/iphone-opus/`) is the
specification; this file records choices made while implementing it. Tune after a real-phone review.

## Comprehension note (Phase 0)

- **Two protocols, one borrowed idea set.** Portlight v1 is a client-first JSON `hello` inside an
  already-trusted `wss://host:5920/remote` WebSocket, then JSON control messages plus
  length-prefixed binary envelopes (4-byte big-endian header length, JSON header, PNG/JPEG/audio
  payload), full-state `subscribe` revisions, per-display *normalized* pointer coordinates, X11
  keysyms, and `frameAck` flow control. URC is server-first (12-byte `URCP` preamble), TLV
  messages, capture-pixel pointer coordinates, HID usages, display-select negotiation and credit
  flow control. They are not interchangeable; nothing of URC's wire, server, pairing stack or
  fleet/gate tooling is used. URC contributes rendering, gesture, input-mode and reconnect *ideas*.
- **Why framebuffer updates cannot change viewport geometry.** A Portlight frame is a rectangle of
  texels in a negotiated stream canvas; stream resolution is image detail, not layout. Layout is
  defined by host *logical points* (and the viewer-only compaction of empty bands between
  selected displays). The viewport model is owned by gestures, Fit mode, rotation/safe-area and
  explicit topology/selection changes; the frame path has no API that can reach it. A resolution
  revision re-maps the same logical anchor onto a replacement texture and keeps user zoom.
- **URC implemented vs planned (per handoff review; refreshed by a full read-only sweep).**
  Implemented: persistent Metal framebuffer texture, independent viewport transforms with pinch
  centroid and incremental deltas, display-linked rendering, cumulative presentation slot, a basic
  simulator client loop, pinch/two-finger local pan/single tap gestures, bounded dial state (ADR
  0030). Planned/doc-only: Direct/Trackpad modes, sticky modifiers, richer mouse gestures, full
  frozen-frame resume UX, profiles/clipboard/discovery/SSH/file transfer.

## Environment

| Item | Decision |
|---|---|
| Source of truth | Portlight checkout `app/` on this MacBook (git baseline `bfa6c2c`, dirty working tree preserved). New code lives only in `app/viewer-ios/`. |
| Xcode builds | This MacBook has Command Line Tools only (Swift 6.2.3, macOS 15.7.3). iOS builds, simulator runs and screenshots run on RG Mac Studio (Xcode 26.6, iOS 26.5 simulators) in the isolated mirror `~/SUDev/portlight-ios-work/app` via `scripts/studio`. URC and `/Applications/Portlight Host.app` there are never touched. |
| Live hosts | Both machines run a live Portlight Host on :5920. Tests use only fixture hosts built into `verification/iphone-host-build` (gitignored) on random loopback ports with temporary data dirs. |
| Local tests | `PortlightKit` (platform-neutral core) runs under `swift test` on macOS with Swift Testing; CLT needs explicit `-F` flags (in `scripts/lib.sh`). |
| Device builds | `scripts/test-device --udid <id>` signs with the Studio's Apple Development identity (team `QJQY4YSGUQ`, overridable with `PORTLIGHT_TEAM_ID`), installs through `devicectl`, and never uploads. Registering the device or App ID with the developer account happens only with an explicit `--allow-provisioning`, which needs the owner's go-ahead. |

## Architecture

| Choice | Decision | Reason |
|---|---|---|
| Package split | `PortlightKit` SwiftPM package (protocol, transport, session, viewport, input, decode, audio, persistence) + thin iOS app target (SwiftUI shell, UIKit gesture surface, Metal view). | Keeps geometry/parsing/state machines testable without UIKit or Xcode; fast local iteration against the real fixture host. |
| Xcode project | Hand-written `Portlight.xcodeproj` using folder-synchronized groups (objectVersion 77); no generator dependency. | No per-file project edits; nothing to install on either Mac. |
| Language mode | Swift 5 mode with complete strict-concurrency *diagnostics*. | Surfaces data-race issues without blocking velocity; ownership rules in the plan are enforced by design + tests. |
| Shaders | Metal Shading Language compiled at runtime from source strings. | Works in `swift test` under CLT (no `metal` compiler) and avoids Xcode's separate Metal toolchain component. |
| Trust flow | Probe-then-pin: an unknown/changed certificate fails the TLS challenge immediately (no password sent), the fingerprint is shown, and approval saves the exact pin and starts a fresh connection generation that requires that pin. | Challenge completes exactly once; no handshake is held open during a user decision; a stale sheet cannot continue an old connection. |
| Bundle IDs | `studio.upgrade.remote.viewer.ios` (+ `.tests`, `.uitests`), matching the Mac viewer's `studio.upgrade.remote.viewer`. | Consistent family naming. |
| Icon | `scripts/render-ios-icon.swift` re-renders the original Portlight mark full-bleed and opaque for iOS masking. | Uses supplied branding geometry; macOS artwork has transparent margins unsuitable for iOS. |
| Accent color | Light `#C43E0C` (≈5.2:1 on white), dark `#FF8A5C`. | Studio Upgrade fire family with WCAG AA text contrast; surfaces stay system-colored per branding README. |

## Session and input behavior

| Choice | Decision | Reason |
|---|---|---|
| Frame acceptance | `accepted` revision changes only on `subscribed`. Stale frames are ACKed and never decoded; future or unknown frames are ACKed and dropped; a committed patch is ACKed only after it is committed to the ordered framebuffer. | The Mac viewer drops every frame while a rejected subscription is pending, and ACKs decode failures as if they succeeded. The host's 32-packet window already bounds the backlog. |
| Image failures | ACK, count, and request a recovery subscription at a safe input boundary. More than three failures within 10 s fails the session with a protocol error. | This is the plan's "explicit recovery path". The picture is never passed off as complete when it isn't. |
| Canvas budget | If the host's acknowledged canvases exceed the budget (for example the host's "native" rule with a 5K display), the viewer does not allocate them. It resubscribes paused and asks the user to choose fewer displays. | Displays are never dropped silently, and memory never grows past the budget. |
| Half-open sockets | While streaming, the viewer pings every 2 s. Six seconds with no inbound message ends the session as "network lost". | The host sends stats every second, so silence means a dead path. |
| Reconnect | Backoff is 0.25 → 8 s with full jitter, at most 6 attempts, and only for transient failures. During an automatic reconnect, `busy` is retried for up to 20 s, because the host can still hold the phone's own vanished session; a user-initiated connect shows `busy` immediately. | Combines URC's ladder (plus jitter) with the host's zombie-session behavior. |
| Touch input | A pure raw-touch reducer (`GestureInterpreter`) instead of stacked UIKit recognizers. | The plan's arbitration table becomes deterministic, and every row is unit-testable without a device. |
| Direct mode, one-finger pan | Pans the local viewport and sends nothing remote. Remote drag requires a long press first. | Satisfies "no remote action until a deliberate drag commits" and matches phone expectations. |
| Trackpad taps | The first click is sent immediately. Tap-then-hold starts a drag. | The plan says not to delay the first click. Whether the host reads click-then-press as a double-click drag needs physical verification, and the tap delay stays configurable. |
| Sticky modifiers | Applied around actions: modifiers go down right before the action that needs them. Latched ones come up after it; locked ones stay down and are re-asserted after the host releases input. | The host releases all input on every accepted subscription, so a modifier "held" across one would silently vanish. |
| Password lifetime | Read from the Keychain only when Connect is pressed. Kept in memory for automatic reconnects during the app session, and cleared on explicit disconnect. It is sent only in `hello`, after certificate approval. | Meets NET-03 without re-prompting on transient reconnects. |
| Audio session | `.playback`, activated only while audio is on. Headphones unplugged → output suspended, with a Resume notice. | Follows Apple's guidance for route changes, and never uses the microphone or background audio. |

## Transport, persistence and UI (wave 2b)

| Choice | Decision |
|---|---|
| **Transport trust** | Exact pin only: no `SecTrustEvaluate` and no system trust. An unknown or changed certificate cancels the handshake before the WebSocket upgrade. One ephemeral `URLSession` per attempt: no cookies, cache or credential storage; TLS 1.2 minimum; 15 s request timeout; 32 MiB message limit. Redirects are refused and end the attempt. |
| **Engine password gate** | Defense in depth. An `.opened` without a pin, or an `identityVerified` that isn't the pin, fails as `tlsFailed` and never sends `hello`. |
| **Retiring an attempt** | `connect`, `disconnect` and `cancel` retire the old generation on the caller's thread. Once the call returns, no callback, commit or revision of it lands. |
| **Close mapping (measured)** | ENOTCONN or a close frame → `.hostClosed`. ECONNRESET, EPIPE, ECONNABORTED and -1005 → `.networkLost`. After open, would-be refused, no-route, timeout or host-not-found become `.networkLost`. A missing welcome is `.timedOut` (retryable), not a protocol violation. |
| **Local network rule** | "No usable network" (-1009, ENETDOWN or an unsatisfied path) is split by the device's own network, from an `NWPathMonitor` started at launch. No network at all → `.offline` for any address. With a network, a loopback/RFC 1918/link-local/ULA/`.local` address → `.localNetworkDenied`, and any other address → `.noRoute` ("Can't Reach the Computer"). Measured on the Studio: `wss://[100::1]` with IPv4-only routing fails at once with a bare -1009, while BSD `connect` says EHOSTUNREACH. Before the first path update, the address alone decides: local → `.localNetworkDenied`, else `.offline`. An explicit "prohibited" path reason always means `.localNetworkDenied`. |
| **Framebuffer loss** | `.failed` is kept separate from `.stale`. A lost patch invalidates its coverage cells (input stays gated there) and the engine requests a recovery subscription. |
| **Saved passwords** | Bound to their canonical endpoint (`passwordEndpointKey`). Updating with a changed Computer and an empty field deletes the old item. Save writes the list without the hint, then the Keychain, then the list with the binding. The orphan sweep runs only after a clean launch load. |
| **Persisted files** | `Connections.json` and `TrustedComputers.json` live in Application Support/Portlight, written atomically with iOS protection `completeUntilFirstUserAuthentication`. A newer-schema file is never replaced or moved. Damaged elements are dropped one at a time after copying the original aside. Pan is never the saved starting mode. |
| **Chrome material** | `.bar` (the system toolbar material), solid under Reduce Transparency. `.ultraThinMaterial` over the black letterbox rendered unreadable mid-gray in light mode. |
| **Text on accent** | White on the light accent (5.2:1), near-black on the dark accent (7.9:1). White on `#FF8A5C` was 2.4:1. |
| **Saved-password prompt** | The field shows "Saved in Keychain". The Keychain is still read only on Connect. |

## Review outcomes (wave 2c)

| Choice | Decision |
|---|---|
| **Established drops** | Once the WebSocket is open, "no usable network" errors map to `.offline` when the device has no network and to `.networkLost` when it still has one (both retryable). Local Network permission is suspected only before open, because a socket that reached the host proves permission. An explicit "Local network prohibited" path reason still means `.localNetworkDenied`. |
| **`.opened` requires a pin match** | `.opened` is delivered only after this attempt matched the pin. A different certificate after the match ends the attempt as `tlsFailed` ("switched certificates mid-connection"). The `tlsFailed` copy makes no claim about the password. |
| **Message size** | URLSession's 32 MiB limit is inclusive (measured). A larger message → `protocolViolation`. |
| **Pinch stays local** | A pinch stays local until every finger lifts, re-grips included. Adding a finger to a leftover pinch finger never becomes a remote scroll. |
| **Text chunking** | `text` messages are capped at 20 UTF-16 units (and 4096 bytes). The current host posts each message as one `CGEvent`, whose Unicode string is reportedly truncated beyond about 20 units. To verify on a consented Mac; relax the cap if the host starts splitting. |
| **Wheel steps** | A scroll step over ±100 lines is split into several `wheel` messages that sum exactly (at most 16), instead of being clamped away. |
| **Audio Resume** | Resume during an interruption activates the session. If that is refused, it keeps waiting for the system's interruption end. |
| **Zoom across density** | Zoom is kept in UI points across a pixel-density change. The zoom ceiling uses the whole-drawable fit, so showing the keyboard never lowers it. |
| **Control On symbol** | `cursorarrow.click.2`. `cursorarrow.rays` read as a loading spinner. |
| **Test launch variables** | `PORTLIGHT_TEST_DATA_DIR` gives isolated persistence, in-memory secrets and a separate defaults suite. `PORTLIGHT_TRANSCRIPT=1` and `PORTLIGHT_TRANSCRIPT_FILE` write a redacted control transcript to Documents. The app composes nothing when hosting unit tests. |
| **Profile field ownership** | The session owns `preferences` and `lastConnectedAt`; the app re-reads them from the file before every list save. |

## Final verification (wave 3)

| Choice | Decision |
|---|---|
| **Failure fixtures (NET-04)** | The E2E reproduces each failure on loopback, or without sending anything. **Busy:** the UI test holds the fixture's single viewer slot with its own viewer, pinned to the exact fingerprint and authenticated with the synthetic password. **Timeout:** a loopback listener accepts TCP and never answers TLS. **No route:** `[100::1]`, in the IPv6 discard-only prefix. A non-blocking BSD connect must first return EHOSTUNREACH or ENETUNREACH, otherwise the test skips, so nothing leaves the Mac. No external address (such as 192.0.2.1) is used, because its outcome depends on the LAN router. |
| **Lifecycle UI test (LIFE-01, simulator part)** | Press Home, make the app-switcher gesture, and take a screenshot; activating the app reconnects with the pin. test-e2e checks the transcript: the session ends (`· disconnect`) between two welcomes, and no input is sent. The real app-switcher snapshot and Auto-Lock remain device checks. |
| **Accessibility audit (UX-01, simulator part)** | Xcode's `performAccessibilityAudit` runs on every gallery page: in light, contrast and then every other audit type; in dark, contrast. The first run found 180 issues. The fixes: opaque cards and banner (the audit misjudges text on materials); a darker secondary-text color (about 7:1 in light, 8:1 in dark); label-colored secondary buttons; Dynamic Type caps only on the chrome's strip, rails and grabber (the top bar stops at xxxLarge) and on the keyboard bar; wrapping instead of truncation; custom empty states that don't clip. Any issue fails the test except those matched by `acceptedAuditIssue`'s narrow rules, each by page, audit type and element: Dynamic Type in the two capped bars; the system sheet "Done"; disabled controls (WCAG-exempt); UIKit single-line text fields; a few List/Form cells the large-text screenshots show growing; and the Diagnostics header under the system scroll-edge blur. `accessibility-audit.txt` lists the accepted issues too. VoiceOver walkthroughs and real system settings remain device checks. |
| **Delivery manifest** | `scripts/delivery-manifest.py` writes `DELIVERY-MANIFEST.json`: the source commit, a SHA-256 for every source and evidence file, the toolchains, the acceptance status, and a required-deliverables check that exits 1 when one is missing. |
| **Nothing held when a subscription goes out** | The host releases held input when it *processes* `subscribe` (`Server.swift:257`), before it sends `subscribed`, so input pressed in between stays held. The controller releases everything before every subscription it sends, and a Locked modifier goes up and is re-asserted before the next action. It never forgets input on accept. A canvas-budget refusal also releases input. |
| **Pasted and committed text** | Bounded to 4,096 whole characters, with a "Text Shortened" alert when cut. Sent 64 messages per 1/60 s, never splitting a key press. Other input flushes the rest first. Pause, View Only, input turning off and a lost connection drop the unsent rest. |
| **Session alerts** | `SessionController.alerts` ("Audio Couldn't Start", "Text Shortened") are shown one at a time as system alerts over the session. Resume appears when the alert offers it. |
| **Profile saves** | The app runs every load, merge and save of `Connections.json` inside `controller.withProfileWritesSerialized`, so a session preference write can't land between its load and its save. |
| **Missing password reason** | The form uses `controller.missingPassword` (missing from the Keychain, a different computer, or none saved) instead of inferring the reason from the profile. |

## Product defaults (from the plan, unchanged)

iOS 17 minimum; all displays + Fit on fresh connect; HD ceiling on phone; Full Color / Automatic;
Trackpad input with Control On clearly labeled; audio off (96 kbps stereo AAC when enabled);
Automatic data rate; dither off; Keychain credentials without per-selection biometrics; automatic
foreground reconnect for transient loss only.
