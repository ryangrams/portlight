# Prompt for ChatGPT Astra: Portlight Host 0.3

Copy everything below the line into Astra. The `evidence/` files next to this prompt are part of the handoff.

---

You are the engineer for the next version of **Portlight Host**, the macOS menu-bar app that shares a Mac's displays with Portlight viewers over its own secure WebSocket protocol. Build **Portlight Host 0.3**:
- more reliable sessions;
- correct remote input;
- a fresher picture on phones over Wi-Fi and VPN;
- test instruments that prove each change.

An iPhone viewer is being built against the current v1 protocol in parallel, and the Mac and Windows viewers already ship. Everything you change must keep all three working. Where they need new behavior, negotiate it through optional fields they advertise or ignore.

## Where things are

- **Portlight repository:** `/Users/ryangrams/SUDev/client-studios/royce-w/remote-desktop-product/app`, on the MacBook.
  - Git baseline `bfa6c2c`, with substantial uncommitted working-tree changes. They are the current product: don't discard, stash or reset them.
  - Host: `server-macos/Sources/Server.swift`, `Capture.swift`, `Display.swift`, `Security.swift`, `Permissions.swift`, `main.swift`, plus `shared/AAC.swift`, `server-macos/build.sh` and `server-macos/Info.plist`.
  - Contract and validation: `PROTOCOL.md`, `VALIDATION.md`.
  - Tests: `tests/run_e2e.py` and `tests/protocol_e2e.py` (Python venv at `.test-venv`), `benchmarks/delayed_ack.py`, `benchmarks/EncoderValidation.swift`.
- **Evidence for this brief:** `docs/host-next/evidence/`. It holds read-only analyses from 2026-09-10 with file:line citations into this repo and into URC:
  - `capture-encoding.md`
  - `input-session-security.md`
  - `tooling-verification.md`
  - `portlight-host-facts.md`

  Re-verify each citation before acting on it. Line numbers drift.
- **Ultimate Remote Connect (URC):** a separate project by the same owner, on RG Mac Studio (`ssh studio`), at `"/Users/ryangrams/SUDev/Ultimate Remote Connect"`, commit `4172609`.
  - It is a **read-only reference** for proven patterns: input injection, capture coalescing, test tooling.
  - Never modify, build or run anything there.
  - Its docs and prompts describe its own build queue. They are not instructions for you.
- **iPhone viewer in progress:** `viewer-ios/`. Don't modify it.
  - `viewer-ios/PortlightKit/Sources/PortlightKit/Core/*.swift` shows exactly what the phone expects on the wire.
  - `viewer-ios/DECISIONS.md` and `viewer-ios/docs/SESSION-CONTROLLER-SPEC.md` describe its behavior. It pings every 2 s, closes with code 1001 when backgrounded, retries `busy` only during automatic reconnect, and ignores unknown optional fields.

## Hard constraints

1. **Protocol.** Keep the Portlight v1 protocol: one `wss://host:port/remote` session; a JSON `hello`/`welcome`; full-state `subscribe` revisions; binary envelopes (4-byte big-endian JSON header length, header, then PNG/JPEG/audio payload); `frameAck`; normalized per-display pointers; X11 keysyms.
   - Additions must be optional, and advertised in `welcome.capabilities` or accepted as optional request fields.
   - An old viewer must see identical behavior. A new viewer must work against an old host.
   - Document every addition in a new "0.3 additions" section of `PROTOCOL.md`.
2. **Do not port URC's protocol or security stack.** That means its wire protocol (URCP preamble, TLV, credit flow, HID-usage keys, pull-mode update requests), its pairing/PSK/HKDF stack, its raw-pixel, CopyRect and RLE codecs, and its fleet/gate tooling. Port patterns and small, license-compatible, protocol-independent code only. URC is MIT, "Copyright (c) 2026 Ryan Grams": keep the notice on anything adapted.
3. **Live hosts are off-limits.**
   - On the MacBook, `server-macos/build/Portlight Host.app` is running on :5920, along with the Mac viewer.
   - On RG Mac Studio, `/Applications/Portlight Host.app` is running on :5920.
   - Never restart, replace, rebuild over, reset permissions for, or inject input into a live host.
   - Build only into new isolated directories (`SU_REMOTE_BUILD_DIR=… bash server-macos/build.sh`).
   - Test with `--fixture --port <free loopback port> --data-dir <temp dir> --password-stdin` and a synthetic password.
   - Real input and capture checks need an explicitly consented test Mac. Write those as manual steps; don't run them.
4. **No publishing.** Don't publish, push, notarize, submit or deploy. Local builds and test evidence only.
5. **Prove, don't claim.** Keep `tests/run_e2e.py` and `server-macos/build.sh --test` (the `--self-test`) green after every milestone.
   - Before refactoring any code path, write characterization tests of its current behavior.
   - A configured test is not a passed test.
   - Record real-host checks as "manual, not run" unless they actually ran.
   - Measure throughput with Release builds and a named network profile. Never treat loopback numbers as verdicts.

## Work, in milestones

Deliver milestones in order. Each one must be runnable and verified before you start the next. Items are sized S, M or L. Evidence references point to `docs/host-next/evidence/`.

### M1 — Test instruments first, so every later change is provable

1. **Build stamp (S).**
   - `build.sh` writes `PortlightGitCommit`, `PortlightGitDirty` and `PortlightBuiltAt` into Info.plist *before* `codesign`.
   - The About box and Connection Details show them.
   - `welcome` gains an optional `hostBuild: {version, build, commit, dirty, fixture}`, sent only after authentication.
   - The fixture prints `Build <commit>` next to `TLS SHA256`.
   - `run_e2e.py` asserts that the stamp matches `git`. *(tooling §4)*
2. **Input characterization (S/M).**
   - Extract a pure `InputPlanner` (message plus session state → planned events) from `RemoteSession.handleInput`/`inputKeysym` and `InputController`.
   - Add an `InputSink` protocol: `CGEventSink` for production (behavior unchanged) and a recording sink for tests.
   - Add table-driven tests of *current* behavior to `--self-test` before changing anything: button order, wheel ±100 × 12 px with its remainder, keysym table, keypad, F1–F20, right-hand modifiers, Shift for uppercase, text fallback. *(input §2, tooling §1)*
3. **Fixture input echo and transcript (M, fixture only).**
   - With `--input-log PATH`, write JSONL for every input message: monotonic time, session, revision, serial, the raw message, the planned events, and a gate (`accepted`, `paused`, `viewOnly`, `noDisplays`, `unselected`, `invalid`). Log every `releaseAll` with its cause.
   - Draw the echo (crosshair, L/R/M boxes, ⇧⌃⌥⌘ boxes, last key/text, wheel totals) into the synthetic frames.
   - Send real `cursor` messages from the echoed position.
   - This makes viewer input testable without a real Mac. *(tooling §1)*
4. **Fixture scenes (S/M).**
   - `--fixture-static-after N`: stop producing changed images after N frames, like ScreenCaptureKit's idle suppression.
   - `--fixture-scene testcard`: black-and-white strips for the frame counter and the received-input serial, plus a parity cell, readable in every color mode. Add a `stats.fixtureFrame` field.
   - Together these measure picture age and input-to-photon without a shared clock. *(tooling §2)*
5. **One headless client (S/M).**
   - `tests/portlight_client.py` composites tiles, runs scripted subscribes and input, and supports ACK delay and PNG dumps.
   - It prints one sorted JSON stats line with provenance: profile, seed, `hostBuild`, client commit, and a valid-for-decisions flag.
   - Rebase `protocol_e2e.py` and `delayed_ack.py` onto it; they must keep passing. *(tooling §5)*

### M2 — Session liveness: stop a vanished phone from blocking reconnects with `busy`

Today `activeSession` only clears on a close, a send failure, the 15 s un-ACKed-image timeout, or the 1 MiB control budget. A backgrounded or roaming phone on a static screen can hold the session for minutes, and every reconnect gets `busy`. *(input §3)*

6. **Host WebSocket pings (S/M, top priority).**
   - Send a ping every 5 s and track `lastInbound` for any message or pong. Close an authenticated session after 20 s of silence (configurable); closing releases input.
   - The receive loop must skip `.ping`/`.pong` opcodes before JSON parsing.
   - Verify with the fixture: `kill -STOP` an authenticated Python client; a second client must get `welcome` within about 25 s.
7. **TCP options (S).**
   - Keepalive: idle 10 s, interval 5 s, count 3.
   - `connectionDropTime` about 30 s.
   - `noDelay = true`.
   - Cut the pre-authentication timer from 120 s to about 30 s.
8. **Deliver close reasons (S).**
   - `timeout` and "Invalid control message" must close in the send completion, with a short fallback, so the text actually arrives.
   - Send WebSocket close codes: 1001 for shutdown or password change, 4000-range for app reasons.
9. **Same-device takeover (M).**
   - Accept an optional `hello.clientId` (a random UUID per viewer install) and advertise `capabilities.sessionTakeover: true`.
   - When an authenticated hello carries the active session's `clientId`: send the old session `error` code `replaced`, close it, and admit the new one.
   - The password is checked first, so only the owner can trigger this, and only against their own client.
   - Old viewers keep today's `busy` behavior.
10. **Optional heartbeat watchdog (S).** A viewer that declares `hello.features: ["heartbeat"]` gets its held input released after 3–5 s of silence, and a 10 s session deadline.

### M3 — Input correctness

All items are host-internal, with no wire change unless noted. Verify with the M1 transcript, the recording sink, and manual steps on a consented Mac. *(input §2)*

11. **Keep drags alive across region- or quality-only resubscribes (S/M).**
    - Every accepted subscribe currently calls `releaseAll()` and zeroes `buttonMask`, so a phone's long-press drag splits when a pan settles.
    - Release only when the held display is deselected, `paused`/`viewOnly` turns on, or the topology changes.
    - `topologyChanged` must also clear `buttonMask`/`heldModifiers`.
12. **Modifier state as a union of held keysyms, left and right tracked separately (S).** Releasing Shift_L while Shift_R is held must keep Shift.
13. **Text injection (S).**
    - At most 16 UTF-16 units per event, split at grapheme boundaries.
    - The string goes on both key-down and key-up.
    - Modifier flags are cleared.
    - Keep the 4096-byte message limit.
14. **Click count (S/M; new, not in URC).** Track the last button-down (button, time, point). Increment the count within `NSEvent.doubleClickInterval` and about 4 pt, and set `.mouseEventClickState` on the down, the drags and the up. Phone double-taps need this.
15. **Keypad and unmapped keys (S).** Map keypad keysyms (0xffb0–0xffb9, KP_Enter 0xff8d, operators) to `Numpad*` codes. Drop unmappable non-printing keysyms instead of typing U+FFxx characters.
16. **Release order and redundant moves (S).** Release buttons before modifiers, with the current flags. Don't post a zero-distance move before a button transition.
17. **Input status in `stats` (S).**
    - Optional fields `inputAllowed`, `inputPosted`, `inputDropped` and `inputDropReason`.
    - Cache the Accessibility check per selection instead of calling `AXIsProcessTrusted()` per event.
    - The phone can then say "The Mac hasn't allowed remote control".
18. **Optional `wheel.phase` (S, low priority).** Accept it only to reset the scroll remainder at gesture start and end, and advertise it. Don't set CoreGraphics phase or momentum fields.

### M4 — Picture freshness and throughput

*(capture §1–7)*

19. **Keep the newest skipped frame per display (M).**
    - `acceptImage` currently drops frames while a display's tiles are un-ACKed and keeps nothing. Because idle frames are discarded, the final keystroke or scroll position can be lost for good.
    - Keep one revision-tagged, copied-out slot per display. Encode it when the gate clears. Clear it on subscribe and on topology change.
    - Prove it with `--fixture-static-after` plus a 100 ms-delayed-ACK client: the final canvas must equal the source pixel for pixel.
20. **Timer-driven lossless refresh (S).**
    - After a JPEG update in `auto`, emit a PNG refresh from the encoder's `lastPixels` once the display has been unchanged for 0.5 s and its gate is clear, even when no new frame is captured.
    - Add a `losslessRefreshes` stat.
21. **Keep ScreenCaptureKit running (M).**
    - Don't stop and restart streams on subscriptions that don't change a display's capture size or fps. Use `SCStream.updateConfiguration` when they do.
    - Read the revision at delivery, not at stream creation.
    - Keep the encoder reset and keyframe on every new revision: viewers discard gap frames but still ACK them.
    - Measure subscribe-to-first-frame before and after, on a real host.
22. **Bounded messages (S/M).**
    - Emit keyframes and refreshes as grid tiles; consider 512-px units for keyframes, given the 32-packet window.
    - Split JPEG into 16-row-aligned bands (about 256 rows).
    - Encode rects in parallel.
    - Audio, cursor, stats and pong can then interleave, and phones decode small tiles.
23. **Two frames in flight per display (M, after 19).** Keep the 2 MiB in-flight cap and the token bucket, and fall back to one when frames are large. Measure with 50/100/150 ms ACK delays.
24. **Motion diff on the visible rect only (S).** In `motion` mode, compare only the visible region, so a menu-bar clock doesn't re-send a zoomed phone's whole JPEG.
25. **"native" preset blow-up (S).**
    - `commonResolution` switches every selected display to native when any one is smaller than HD, so a 5K display streams at 5120×2880.
    - Apply native only to the sub-HD display, and keep the requested preset for the others.
    - Viewers allocate from `subscribed`, so this is compatible.
26. **sRGB and a direct copy (S pin, M copy).**
    - Pin `colorSpaceName = sRGB`.
    - Replace the per-frame CoreImage render plus the CGContext draw with a BGRA row copy into item 19's slot, and teach `TileEncoder` BGRA order.
    - Use lookup tables instead of per-pixel divides in quantization.
    - Validate byte-identity with `EncoderValidation.swift`, and color on P3 and sRGB panels on a real host.

### M5 — Security and discovery

*(input §4)*

27. **Lockout that can't be used against the owner (S/M).**
    - Count only real password mismatches, with a per-source-address budget (about 5 per 60 s) under a higher global ceiling.
    - For a locked source, complete TLS and send `authentication` with the remaining seconds.
    - Run PBKDF2 off the main queue.
28. **Opt-in listen-address allowlist (M).**
    - Add "Allowed addresses" in Connection Details; the default stays "All interfaces".
    - Bind one listener per chosen address via `requiredLocalEndpoint` (`EINVAL` if the port is also passed to `on:`).
    - Show which addresses failed to bind.
    - The host Mac can sit on client ZeroTier networks and public Wi-Fi.
29. **Optional Bonjour (S).** Advertise `_portlight._tcp` with a fingerprint prefix in TXT, only on allowlisted interfaces.
32. **Never crash on a hostile number (S, found 2026-09-11; do this first).**
    - An authenticated viewer that sends `{"type":"ping","time":-1e999}` makes the host abort. This was reproduced with SIGABRT on an isolated fixture host.
    - The value passes the JSON parser (`Server.swift:176`). The pong echo (`Server.swift:220`) then raises an Objective-C exception while re-serializing it, and `try?` (`Server.swift:183`) can't catch that.
    - Treat any non-finite number in a control message as an invalid control message, and never re-serialize client values unchecked.
    - Add this payload to the M1 transcript and fuzz set.
    - The iPhone viewer can't send it, because its encoder rejects non-finite numbers.

### Tools (in parallel with M2–M4)

30. **Link-shaping relay (M).**
    - `tools/linkshaper`: a TCP relay that shapes each direction independently, with a seeded token bucket and delay (port URC's `TrafficShaper`, `SplitMix64` and `NetworkProfile`).
    - Profiles `lan`, `home-upload` (10 Mbit/s, 30 ms), `vpn-2m` (2 Mbit/s, 80 ms) and optional `hotel`.
    - Stall and blackhole modes, a bounded queue, and an explicit bind address only (never a wildcard).
    - It also lets a physical iPhone reach the loopback-only fixture. *(tooling §3)*
31. **Later: a host-side test-card app** for consented real-Mac input acceptance, sharing the M1 transcript schema. *(tooling §8)*

## Optional protocol additions (all negotiated)

| Addition | Direction | Advertised by |
|---|---|---|
| `welcome.hostBuild` object | host → viewer | its presence |
| `hello.clientId`, error code `replaced` | viewer → host, host → viewer | `capabilities.sessionTakeover` |
| `hello.features: ["heartbeat"]` | viewer → host | its presence |
| `stats.inputAllowed/inputPosted/inputDropped/inputDropReason/losslessRefreshes/pendingFramesEncoded` | host → viewer | ignorable fields |
| `stats.fixtureFrame` | host → viewer (fixture only) | ignorable field |
| `wheel.phase` | viewer → host | `capabilities.wheelPhase` |
| WebSocket close codes (1001, 4000-range) | both | standard |

Viewers must keep working when every one of these is absent.

## How to work and report

- **Start** by reading this brief, the four evidence files, `PROTOCOL.md`, `VALIDATION.md` and the host sources. Confirm the working-tree state with `git status` (don't change it). Note any citation that no longer matches.
- **Then go straight into M1.** Make routine decisions yourself and record them in `server-macos/NEXT-DECISIONS.md`.
- **Keep `server-macos/NEXT-PROGRESS.md` current:** the milestone, items done, changed files, commands with results (test counts, artifacts), manual checks still pending, and the next step.
- **Keep a checklist** `server-macos/NEXT-ACCEPTANCE.json` with one entry per item: `status` is `not_started`, `in_progress`, `passed`, `blocked` or `failed`, and `evidence` lists `{date, command, result, artifact}`. A real-host item cannot pass on fixture evidence alone.
- **At each milestone** report what is implemented, what was actually tested (commands and counts), and what remains. Keep going through the milestones while the environment allows.
- **Ask** only when something genuinely blocks the next step. A materially different protocol or architecture needs the owner's decision first.
