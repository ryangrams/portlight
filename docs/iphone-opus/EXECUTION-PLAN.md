# Portlight for iPhone — execution plan

## 1. Outcome and scope

Build a native iPhone viewer for the existing Portlight macOS host. It should make a remote Mac usable on a phone for studio applications, editing interfaces, and live video, while prioritizing responsive control and limited bandwidth. This work creates a viewer, not a new host or protocol.

The first usable version includes saved connections, secure connection/trust, every monitor selected on initial connection, logical display layout, one-tap display selection access, local Fit/zoom/pan, direct-touch and trackpad control, modifier/special keys, three color choices, four resolution ceilings, optional system audio, and reliable foreground reconnect. The iPhone UI should feel native and intentionally designed rather than a shrunken desktop toolbar.

**Excluded:** URC protocol/server, standard VNC interoperability, ZeroTier integration, accounts/relay services, SSH/file-transfer subsystems, camera/microphone passthrough, App Store publication, and permanent background sessions. Bidirectional clipboard and discovery require separate host work and are not prerequisites for the viewer. iPad should compile and adapt sensibly where practical, but full iPad acceptance follows iPhone.

### Working defaults — assumptions, not newly claimed user decisions

| Choice | Starting default | Reason / adjustment rule |
|---|---|---|
| Minimum iOS | 17 | Matches the useful URC rendering approach and gives a clear initial deployment floor. Verify SDK availability; lower only after measuring compatibility cost. |
| UI stack | SwiftUI shell, UIKit gesture surface, Metal framebuffer | Native structure with independent high-frequency drawing. |
| Start view | All displays, Fit | Explicit user requirement; initial overview gives context. |
| Stream ceiling | HD (720p) initially on phone | Proposed phone-specific default to reduce data; retain FHD/QHD/UHD choices and save user preference. |
| Color / content priority | Full Color / Automatic | Avoid a surprise gray first impression; 256/gray remain immediate choices. |
| Input | Trackpad, Control On clearly labeled | Small desktop targets favor relative cursor movement. Control state must be unmistakable. |
| Audio | Off; 96 kbps stereo when enabled and AAC supported | Existing Portlight behavior/options. |
| Video data rate | Automatic | No user FPS selector. Manual Mbps ceiling belongs in the quality sheet. |
| Dither | Off | Optional Video smoothing increases bytes; never claim it is free. |
| Credentials | Device-local Keychain, no forced biometric check on every selection | Consistent with user's dislike of repeated credential prompts. Optional app lock can follow. |
| Reconnect | Automatic for transient foreground loss; stop on auth/trust errors | Fast recovery without repeatedly prompting or retrying rejected credentials. |

Store these decisions in the app's concise decision log. They can be tuned after a real-phone review without altering the protocol.

## 2. iPhone experience

### Connections

Use a native navigation list with compact saved connections and optional groups. Rows show name plus secondary host detail where space permits. Connection name is optional and distinct from Computer; a saved unnamed item becomes “Saved Connection,” not an IP masquerading as a name. A plus menu offers New Connection and New Group. Edit/reorder/delete use native list affordances. Group disclosure responds to a single tap.

Follow the existing desktop intent: tapping a saved row selects it and opens its editable details; it does not silently connect or read Keychain. The detail view has a prominent Connect action and a visible Save Connection / Update Connection action. An explicit row context-menu Connect action is acceptable. Do not add a double-tap-only path on iPhone. Validate host, port, and required password inline. Return/Next key ordering follows Name → Computer → Password → Port as appropriate; external keyboard Tab/Shift-Tab must traverse fields normally.

Show real connection phases: Connecting, Checking Computer Identity, Authenticating, Loading Displays, Connected, Reconnecting, Failed. A cancel action is available throughout. Distinguish refused port, no route, timeout, rejected password, changed certificate, busy host, and capture failure. Never label an unopened socket “Negotiating.”

### Session layout

The picture owns the screen. In portrait, keep a compact native top bar with Back/Disconnect, computer identity/status, and a labeled Control On/View Only button. Put frequent session controls in a reachable bottom strip: Displays, Input Mode, Keyboard, Pause, Audio, and a Quality/More entry if needed. In landscape, move controls to a compact edge arrangement that respects safe areas; don't squeeze every desktop setting into one row.

An unobtrusive Hide Controls action may expand the canvas. A visible recovery affordance must remain, and a canvas tap used to reveal controls must not also click the remote Mac. Do not cover content with a permanent oversized status card. Use an anchored popover on larger layouts and a native sheet on phone-sized layouts.

Control On uses a clear icon plus persistent label and selected treatment. View Only uses a different icon and explicit wording; color is supplementary. Pause retains and dims the image, shows a large pause symbol and “Paused,” disables input, and stops requested media. Resume restores selected displays, quality, and the previous audio preference. Local zoom/pan may still inspect the paused image.

### Displays

On phone, the toolbar control should normally be `display.2` plus “Displays” and a selected count. A tiny map is not an acceptable touch target. Only use inline toggles when every target has at least a 44-point touch area without ambiguity; otherwise open the selector sheet.

The sheet shows the complete physical arrangement using host logical points, with active displays clearly filled/outlined and inactive displays dimmed. Pair the map with a compact labeled list when unusual layouts make the map ambiguous. Include All and None, and allow toggling individual displays without reconnecting. None is a valid paused-picture/empty-selection state with no input, not a crash or automatic fallback to another display.

Selected content uses the same logical proportions. If 1+2+3 are horizontal and 2 is disabled, 1+3 become adjacent in the viewer. The map still shows 2 in its real location. Never change the host's actual arrangement. Cross-display remote drags maintain the pressed mask and switch target IDs as the cursor crosses the compacted local boundary; test in a harmless app because the host's real gap still exists.

When selection changes in Fit mode, fit the new collection. Outside Fit mode, preserve the anchored logical location when that display remains; otherwise fit the new selection. Changing stream resolution alone must not move the viewport.

### Quality controls

Use four labeled resolution buttons: HD, FHD, QHD, UHD, with the existing 2×2, 3×3, 4×4, 5×5 grid motifs. Use exactly three labeled color buttons: Full Color (gradient), 256 Colors (palette), 16 Shades of Gray (four gray bars). Selected items need more than subtle tint: outline/fill, selected accessibility trait, and readable text. Unavailable choices are disabled with an accessible reason.

Offer Automatic / Text / Video content priority. Add Smooth gradients only as the existing optional Video/reduced-color feature; explain briefly that it uses more data. A combined Data Rate section includes video Automatic/manual Mbps and audio mono 48 / stereo 96 / 160 / 320 kbps. Audio quality selection does not enable audio automatically. Show actual throughput and changed-image rate in an optional diagnostics view, not as primary controls.

Fit is a persistent mode that follows viewport size/orientation. Zoom +/− use roughly 10% steps. Define 100% as one host logical point per phone UI point, consistent with Portlight's logical layout; label it “Actual Size” with explanatory help because it is not one stream pixel per physical phone pixel. Pinch preserves its centroid, and user zoom exits Fit.

### Keyboard and pointer controls

Both Trackpad and Direct modes are required, with a one-tap switch. Provide an explicit local Pan mode to avoid assigning two-finger movement to both remote scroll and local viewport movement at once. The active mode is always visible.

| Gesture/control | Trackpad | Direct |
|---|---|---|
| One-finger move | Move local predicted remote cursor | No remote action until a deliberate drag recognizer commits |
| Single tap | Left click at cursor | Left click at mapped location |
| Double tap | Two remote clicks, without delaying the first click unnecessarily | Same at mapped location |
| Two-finger tap | Right click | Right click at gesture location |
| Two-finger pan | Remote scroll | Remote scroll |
| Pinch | Local zoom | Local zoom |
| Drag | Tap, then press-and-hold/move; explicit left-button latch fallback | Long press then move; explicit left-button latch fallback |
| Right drag | Explicit right-button latch; optional two-finger hold after validation | Same |
| Middle click | Explicit mouse-actions control | Same |
| Local Pan mode | One-finger local pan; remote input suppressed | Same |

Three-finger gestures conflict with system editing/accessibility interactions; don't make middle click or any essential action depend on them. Expose mouse-button controls in the keyboard/accessory palette. Add a short first-use gesture guide accessible later. Separate pinch from two-finger remote scroll: once pinch wins, cancel remote scrolling for that gesture. Never dispatch speculative mouse-down events while a local gesture is unresolved.

Sticky modifiers ⌘ ⌥ ⇧ ⌃ remain available in the input accessory strip. Define states explicitly: Off, Latched for the next action/chord, Locked until toggled. Tap latches immediately; tap again clears; double tap can lock without delaying the first down-state visual. After the next complete click/drag/key chord, release a Latched modifier; Locked remains visibly distinct. All states clear on disconnect, background, mode change, or Control Off. This must be a real input state machine, not four cosmetic toggles.

Provide Esc, Tab, arrows, Home/End, Page Up/Down, Delete, and F1–F12 in an expandable key palette. Use a UIKit text-input responder for software keyboard composition, sending committed Unicode once. Hardware keyboard uses explicit keysyms and modifiers; iOS-reserved shortcuts need visible soft-key equivalents. Do not promise to intercept Home/app-switching shortcuts that the OS owns.

### Clipboard, audio, and reconnect

Portlight currently has `text`, not clipboard-get/set. An explicit “Type Pasted Text” action may use `UIPasteControl` and send bounded committed text. Explain that this types into the focused remote control; it does not set the Mac clipboard. Do not silently read the phone pasteboard or imply bidirectional sync.

Audio is foreground-only and off by default. Keep its playback running across display/quality changes, handle route/interruption events, and stop immediately when disabled. No microphone access. If the host advertises no audio, disable it with an explanation.

When backgrounding, mark the connection inactive, release input, stop media, and close gracefully within the OS's available task window. Keep the last framebuffer in memory where feasible, cover it in the app-switcher snapshot for privacy, and never persist remote screen images to disk by default. On foreground resume, show “Reconnecting” over the frozen frame while connecting; the frozen frame remains locally zoomable but never controllable. Cancel/retry stays visible. A deliberate new connection starts with all displays; a transient reconnect within the same foreground session may restore the user's current selection, with missing IDs removed. Document this distinction in state tests.

## 3. Architecture and ownership

Create a new `viewer-ios/` target under Portlight. Do not modify URC in place. Suggested source boundaries are responsibilities, not a mandate for a large package graph:

```text
viewer-ios/
  Portlight.xcodeproj or a documented project.yml generator
  Sources/
    App/                 SwiftUI navigation, lifecycle, theme
    Connections/         profile list/detail, validation, save/update
    Session/             one SessionController, desired/accepted state
    Protocol/            typed JSON messages, binary envelope, validation
    Transport/           WebSocket, trust, deadlines, generation checks
    Rendering/           per-display textures, image decode, render loop
    Viewport/            logical topology, transform, hit testing, regions
    Input/               recognizers, modes, button/key ledger, text input
    Audio/               AAC/mulaw player, bounded queue, AVAudioSession
    Persistence/         profiles and Keychain adapter
  Tests/                 protocol, geometry, state, queue correctness
  UITests/               connection/session/gesture workflows
  scripts/               build, fixture, simulator integration
```

Keep pure geometry/message parsing testable without UIKit. Extract narrowly reusable Portlight code into a small shared target only where needed; do not refactor the entire Mac viewer to enable the phone. `shared/AAC.swift` may be shared directly after an iOS compile check. Mac AppKit classes, NSAlert, Keychain CLI workarounds, and desktop event handling require native replacements.

### Ownership rules

- One session owner serializes connect/cancel/subscribe/disconnect. The view does not initiate a second connection as it appears.
- One ordered receiver parses bounded messages off the main actor. Image decoding uses a bounded serial path; parallel decoding needs an explicit reorder barrier.
- A render coordinator owns texture mutation and GPU synchronization. A UIView owns its CAMetalLayer and display-link lifecycle. Avoid CPU writes racing GPU sampling; use an ordered command queue/staging strategy and bound in-flight resources.
- A viewport model owns logical arrangement, Fit, zoom, pan, and gesture state. Receiving a frame has no API that can mutate them.
- An input ledger owns held keys/buttons and locally predicted cursor. It serializes transitions promptly. Never coalesce away a button/key transition or replay held state after reconnect.
- Audio has its own serial codec/playback path and bounded queue. Heavy image decode must not run on it or on the main actor.
- SwiftUI observes low-frequency user/session state. Do not publish every tile or audio packet into the SwiftUI view tree.

### Coordinate and memory model

Use named conversions: phone point → inverse viewport transform → compacted logical desktop → display-local logical coordinate → normalized full-display coordinate. Stream texels are used only for image sampling and dirty rectangles. Phone drawable pixels derive from the current window/screen, not a global `UIScreen.main` assumption. Negative host origins and portrait displays must work.

Maintain one bounded texture per selected display and a shared camera transform. Four UHD BGRA textures alone cost about 126.6 MiB; a CPU mirror doubles that before decoder and GPU staging overhead. Start with an explicit aggregate pixel/resource budget, request lower stream resolution when necessary, and never lower the number of selected monitors silently. Reconcile the all-displays requirement with the host's 16-ID limit and the device memory budget visibly. Do not blindly reuse the desktop's four-UHD budget on all phones.

Only actual topology/selection/viewport changes may change geometry. At a resolution revision, map the current logical anchor to the replacement texture, preserve user zoom, and swap acknowledged framebuffer state atomically. New/exposed regions need valid pixels before remote input there is allowed. A revision's first patch need not cover the whole display; track coverage for the requested region instead of calling any one packet “complete.”

### Throughput and responsiveness

First make full selected-display streaming correct. Add viewport regions after stable gestures and input. Deduplicate equivalent desired subscriptions, send local manipulation instantly, and send the region refinement after a short settle period (start around 120–200 ms, measure). The current host restarts video and releases input on subscription changes, so never tie every pan sample to the network. Defer refinement while remote buttons/modifier chords are held. If this prevents useful bandwidth reduction during very long drags, document the measured limitation; a narrowly scoped host lifecycle improvement is a separate decision.

Keep full-frame/canvas state authoritative. Apply cumulative patches in order; coalesce presentation. Bound decoder backlog by bytes and jobs. Backpressure must not create unbounded socket→Task queues. Audio priority on the host helps only before bytes enter TCP; a large image already in transit can still block audio. Do not promise latency-independent sound or perfect A/V synchronization from this protocol.

## 4. Phases and work packages

### Phase 0 — establish the exact starting point

**Inputs:** this handoff, source manifest, current destination repo, Xcode inventory. **Output:** runnable project shell, reproducible fixture entry point, `PROGRESS.md`, and a short `DECISIONS.md`.

1. Compare destination source with supplied hashes; preserve unrelated edits. Record Portlight baseline plus working-tree snapshot identity and URC reference commit.
2. Confirm minimum deployment target, active Xcode, available runtimes, and physical-device/signing availability. Record unavailable checks without claiming failure or success.
3. Create the iPhone target, app icon from supplied Portlight branding, native light/dark shell, and test targets. Add a meaningful `NSLocalNetworkUsageDescription` and connection waiting/retry behavior for the initial system prompt; do not request capture or microphone permissions in the viewer. Reuse existing project tooling if suitable; pin/document a generator only if introduced.
4. Build the Portlight host to a new fixture-only directory, never over the running host. Start it with `--fixture`, an unused loopback port, a temporary data directory, and password on stdin. Read its generated certificate fingerprint for exact test pinning.
5. Create scripts that choose an available simulator UDID and produce an `.xcresult`; fail when tests execute zero cases. The proposed scripts in this plan do not exist until this phase creates them.

**Exit:** simulator app launches; shell changes with appearance; isolated host protocol test passes; baseline is recorded; no live service was touched. If fixture protocol fails, resolve that discrepancy before building a speculative client.

### Phase 1 — secure session and correct pixels

**Dependencies:** Phase 0. **Primary files:** Protocol, Transport, Session, Rendering, minimal Connect view.

1. Implement typed bounded message decoding and encoding, including PNG4/indexed PNG8 fixtures and malformed-envelope tests.
2. Implement trust sheet, exact pin storage, password-at-connect, cancelable connection deadline, generation isolation, welcome/subscribed handling, and explicit errors.
3. Select every advertised display and request HD/Automatic/all visible on revision 1. Validate acknowledged sizes before allocation.
4. Decode PNG/JPEG off-main, apply rectangles to persistent textures, compose displays using logical geometry, send frame ACKs at the correct acceptance point.
5. Implement basic local Fit/pinch/pan with no remote input yet; verify network traffic cannot reset its transform.

**Demonstration:** an iPhone Simulator connects to the real isolated Portlight fixture, selects all three displays in revision 1, draws visibly changing decoded content, handles an old-revision frame without leaking ACK capacity, and returns to Connections after cancel/disconnect.

**Exit:** TLS rejection/approval cases pass, malformed inputs fail safely, real pixels are captured in screenshots, and no-jump deterministic tests pass. A screenshot of a mock preview is not this gate.

### Phase 2 — precise control and complete gesture behavior

**Dependencies:** Phase 1. **Primary files:** Input, Viewport, session controls, keyboard accessory.

1. Implement normalized hit testing, local cursor, Direct/Trackpad/Pan modes, mouse masks, scroll units, and immediate serialized input.
2. Implement the gesture arbitration table, explicit mouse-button fallback, sticky modifier states, Unicode composition, software special keys, and hardware-key mappings.
3. Implement Control On/View Only and Pause overlays with functional blocking, not just appearance changes.
4. Add real display selector, compact content layout, 1+3 boundary handling, and safe release before topology/selection changes.
5. Add orientation/keyboard-safe-area changes that preserve the logical anchor; Fit follows the usable viewport persistently.

**Demonstration:** run against a controlled test app on an authorized test Mac. Exercise left/right/middle click, drag, modifier-click, text with accents/emoji, key releases, and cross-display coordinates on mixed-DPI displays. Use the synthetic host for message assertions; it intentionally does not inject real input, so it cannot prove the physical result.

**Exit:** no stuck input after every interruption path; a pinch trace under incoming tiles produces the same transform sequence as the same trace without packets; no remote clicks result from local control taps; a physical iPhone gesture session is explicitly recorded when available.

### Phase 3 — bandwidth, quality, and resilient audio

**Dependencies:** Phase 2. **Primary files:** Quality UI, Subscription scheduler, Rendering queue, Audio.

1. Implement all four resolution ceilings, three color modes, Automatic/Text/Video, dither option, video data rate, and capability-aware audio rates. Distinguish requested and effective state.
2. Add settled viewport subscriptions and explicit zero regions for offscreen selected displays. Preserve input holds; track subscriptions/sec and time-to-fresh-region so a bandwidth optimization cannot hide a capture-restart regression.
3. Port AAC decoding and μ-law fallback, add AVAudioSession handling, a measured bounded jitter queue, and audio-epoch validation. Preserve audio across video-only revisions.
4. Add bounded recovery for invalid/decode-overflow state. Ensure ACK behavior does not deadlock the host and cumulative tiles are not lost.
5. Expose optional diagnostics: receive Mbps, changed-image updates, decoded/applied/rejected rectangles, presentation count, decoder queue bytes, frame freshness, audio queued ms/underruns/drops, active/effective resolution.

**Demonstration:** text, scrolling UI, gradient/video, and audio test tone under stable and constrained network profiles. Switch monitors, resolution, color, and regions while audio plays. Compare results with audio enabled versus disabled and with video saturated. Use a test profile with enough capacity for chosen AAC rate before blaming packet scheduling.

**Exit:** no audio restart from a video-only setting change; no unbounded playback backlog; only selected/nonempty regions produce image payload; reduced-color images decode correctly; measurements distinguish network delay from local interaction latency. If TCP head-of-line remains audible, document it as a protocol limitation rather than “fixing” it with an undocumented second connection.

### Phase 4 — daily-use iPhone beta

**Dependencies:** Phases 1–3. **Primary files:** Connections/Persistence, lifecycle, native UX, diagnostics export.

1. Complete names/groups/save/update/edit/reorder, Keychain behavior, and safe profile deletion. Export diagnostics without credentials, fingerprints if user considers them sensitive, private host details, or remote pixels by default.
2. Implement frozen-frame foreground reconnect, bounded retry/backoff with jitter, cancel, no auto-retry on auth/trust failure, privacy cover, and idle-timer ownership. Disable auto-lock only during a visible active session and restore normal behavior afterward.
3. Add explicit Type Pasted Text, native paste control, UTF-8-safe chunking, and focus/input safeguards.
4. Finish portrait/landscape layouts, Dynamic Type, VoiceOver labels/selected states, increased contrast/reduced transparency/reduced motion, 44-point hit areas, accessible display list fallback, and app icon.
5. Run the full acceptance matrix on simulator and on at least one real iPhone. Check an older supported phone before promising the iOS 17 floor performs acceptably. Build a local signed development app when the account/device is available; don't upload it automatically.

**Exit:** all required automated cases pass and device-dependent cases have explicit evidence or an honest unresolved status. Deliver a usable build, short user test script, known-limits list, and exact source revision/snapshot. No placeholder Connect buttons, silent unsupported controls, or “tests configured” claimed as tests passed.

### Later, separately authorized increments

- Native iPad refinement, multitasking, hardware trackpad/keyboard and memory-budget tests.
- Capability-negotiated clipboard get/set with consent and no polling; real remote copy back to phone.
- Bonjour service advertisement on Portlight Host plus phone discovery and matching declared service type. Do not scan arbitrary LAN ports as a substitute.
- SSH terminal/tunneling and file transfer only after a separate product decision. They are URC ideas, not hidden requirements of a viewer.
- Shortcuts or OSC adapters over the same local session actions; no new remote transport, no default unauthenticated LAN listener.
- A measured future media transport/codec effort if JPEG/PNG/TCP cannot meet real video/audio targets. H.264/WebRTC/QUIC are not part of the initial client.

## 5. Verification and measurement

### Existing commands and proposed tooling

From a complete Portlight checkout or the supplied host-buildable source snapshot, the existing isolated host path can be used:

```sh
SU_REMOTE_BUILD_DIR="$PWD/verification/iphone-host-build" bash server-macos/build.sh
python3 -m venv .test-venv
.test-venv/bin/python -m pip install -r tests/requirements.txt
PORTLIGHT_TEST_SERVER="$PWD/verification/iphone-host-build/Portlight Host.app/Contents/MacOS/SURemoteServer" .test-venv/bin/python tests/run_e2e.py
```

Use the Python version supported by the pinned test dependencies. The build needs Apple silicon macOS with the relevant SDK; these are observed repo commands, not Linux instructions. The fixture auto-selects a port in `run_e2e.py`. The iPhone integration harness must additionally launch the simulator client with that port and exact fixture fingerprint, keeping the fixture process alive until the test ends. Never put a real password in arguments, source, screenshots, or logs.

Phase 0 should create and document these **proposed** commands (names may change once, then update the plan):

```text
viewer-ios/scripts/build-simulator
viewer-ios/scripts/test-unit
viewer-ios/scripts/test-integration
viewer-ios/scripts/capture-ui
viewer-ios/scripts/test-device --udid <explicit-test-device>
```

Each reports actual executed test count, exit status, artifacts, and simulator/device identity. A simulator with no network permission prompt is not evidence of phone permission behavior.

### Test matrix

| Group | Essential cases |
|---|---|
| Protocol | Truncated/oversized/nonobject JSON, invalid UTF-8, header overflow, invalid Booleans/numbers, unknown codec, malformed PNG, decoded-size mismatch, stale revisions, duplicate IDs, sequence gaps. |
| Authentication | First trust approve/cancel, matching pin, changed pin, cancel while sheet open, late approval after new connection, wrong password, host busy, timeout/no-route/refused, malicious redirect. |
| Composition | 3 horizontal; 1+3 only; vertical stack; negative origins; mixed-DPI equal logical size; portrait; odd tile widths; overlapping patches; partial first frame; topology replacement. |
| Input | Every button/chord, release/cancel, drag across selected displays, no event on local toolbar touch, view-only silence, pause silence, background mid-drag, no duplicate Unicode composition, soft alternatives to system shortcuts. |
| Viewport | Same trace with/without tile flood, continuous pinch centroid, pinch+translation counted once, resolution change anchored, rotation anchored, persistent Fit, controls/keyboard appearing, frozen-frame interaction. |
| Media | PNG4/PNG8/JPEG, unchanged image suppression, zero-region behavior, ACK capacity, decoder budget, AAC cookie/rate/channels, audio Off/On epochs, video revision continuity, interruption/route changes. |
| Persistence/lifecycle | Save/update names, group moves, no Keychain lookup on selection, deleted credential cleanup, cancel retry, network handoff, app switcher privacy, resume after termination versus transient reconnect. |
| UX | Light/dark, large text, VoiceOver, reduced motion/transparency, short landscape viewport, smallest supported phone, clearly selected quality and control states. |

### Performance method and acceptance intent

Do not import URC's old beacon threshold as a Portlight latency promise. Measure separately:

1. **Local interaction:** display-link timing and main-thread stalls during a scripted pinch/pan trace, with and without incoming rectangles. Proposed target is p95 local processing below one 60-Hz frame budget on the named test phone; tune only with documented evidence. Smoothness must not depend on a live connection.
2. **Input-to-photon:** a consented test app changes a visible marker on input; use timestamped instrumentation with a defined clock relationship or high-speed camera. WebSocket RTT and decode time are not substitutes for end-to-end latency.
3. **Throughput/freshness:** bytes/sec, received/applied/presented counts, age of visible content, queue depth, and subscription restarts for static text, scrolling text, UI dragging, and motion.
4. **Audio:** underruns, discontinuities, queued ms, dropped packets, startup time, and route/interruption recovery while video is saturated. The current wire has no shared media timeline; label any synchronization estimate accordingly.
5. **Resources:** peak/resident memory, Metal allocations, CPU/GPU load, thermal state, and a 30-minute physical-device session. Request lower resolution rather than allowing memory growth.

Use named baseline profiles such as unconstrained LAN, 10 Mbps/30 ms RTT, and 2 Mbps/80 ms RTT, then a deliberate connection stall. They are proposed reproducible test conditions, not advertised support guarantees. Record the shaping method and whether it affected both directions. Report median/p95 and sample count, with at least three comparable runs for a performance claim. Repeat only when relevant code or conditions change.

## 6. Handoff discipline and definition of completion

Keep `PROGRESS.md` short and durable: current phase, source identity, completed requirement IDs, commands/evidence, unresolved issues, and the next executable step. Update `ACCEPTANCE.json` without deleting hard cases or relabeling them passed because they are inconvenient. It is fine to record a test as blocked by missing device/signing; it is not fine to claim a daily-use beta is verified while those checks remain undone.

Make local implementation choices independently. If source disagrees with this plan, record the exact difference and its effect. Narrow compatibility fixes are allowed in an isolated development copy. Ask before a materially different protocol, architecture, or product scope is required. Do not spend days building a gate framework or repeatedly checking the same successful build.

Final delivery consists of the source, reproducible local build, test evidence, simulator screenshots of both connection and session states, a short physical-iPhone test script, known limitations, and installation/signing steps. App Store/TestFlight submission is a later action. The work is complete when the required app behavior is implemented and supported by the required evidence, not when the project skeleton compiles.
