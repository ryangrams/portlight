# Portlight protocol: implementation contract for the iPhone viewer

This guide reflects the September 10 working-tree source, not just Git HEAD. Read it with the supplied `server-macos/Sources/Server.swift`, `Display.swift`, `viewer-macos/Sources/Transport.swift`, `Viewer.swift`, `Audio.swift`, and `shared/AAC.swift`. Older `PROTOCOL.md` sections have discrepancies listed below. Resolve new discrepancies against actual fixture behavior and document them; do not invent a wire extension to paper over them.

## 1. Transport and trust

One `wss://HOST:PORT/remote` session, default TCP port **5920**. Use a platform WebSocket/TLS implementation; the Mac reference uses `URLSessionWebSocketTask`. This is Portlight's own application protocol over WebSocket, not RFB, TightVNC, or URC. The user's rejection of the other custom protocol means URC's protocol, not a request to replace Portlight.

Use an ephemeral URL session, explicit message-size cap, one ordered receive stream, and a connection-generation identity. Async callbacks, trust decisions, decoder results, timers, and audio belong to that generation. Canceling or reconnecting invalidates the old generation before its callbacks can publish state.

The host uses a generated certificate. Compute SHA-256 over the leaf certificate DER, display a readable hexadecimal fingerprint, and bind trust to the canonical host/port. First use requires explicit fingerprint approval; a changed fingerprint must stop automatic reconnect and require new approval. The password must not be sent until the exact certificate was accepted. Do not indiscriminately accept self-signed certificates, add an insecure fallback, or follow a redirect to another identity. IPv6 authorities must be built with URL components rather than string concatenation.

In iOS, present trust UI asynchronously without blocking a delegate thread. Complete the challenge exactly once. A canceled/superseded trust sheet cannot persist trust or continue the old connection. Separate a user-decision timeout from the network connection deadline. Saved password lookup occurs when connecting, never when selecting/editing a profile. Secret persistence uses Keychain, with no per-selection biometric prompt.

Client hello, after trusted TLS:

```json
{"type":"hello","version":1,"password":"<entered-or-keychain-password>","codecs":["png","jpeg"]}
```

The host replies `welcome` with `version`, `serverName`, `sessionId`, `displays`, and `capabilities`. Current codecs are PNG/JPEG. Real capture hosts advertise AAC and μ-law; the synthetic fixture advertises no audio. `maxViewers` is 1. Test with other viewers disconnected from a consented test host; do not assume a second simultaneous session is supported.

Wrong password produces an `error` with code `authentication` then close. Do not automatically retry a bad password. A busy host and a refused network connection need distinct messages. Capture/Accessibility failure is a host-side permission issue, not a reason for the iPhone to request screen recording or microphone permissions.

## 2. Framing and validation

Text WebSocket messages are UTF-8 JSON objects. A binary WebSocket message is:

| Offset | Meaning |
|---|---|
| 0–3 | Unsigned big-endian JSON header byte length N |
| 4 through 4+N−1 | UTF-8 JSON object |
| 4+N onward | Encoded image or audio payload |

N must be positive and at most 65,536; the entire binary message is at most 32 MiB. Bound text control JSON to 64 KiB too. WebSocket delivers complete messages: do not treat each URLSession receive as arbitrary TCP bytes or implement URC's framing underneath it.

Validate types, finite values, ranges, duplicate display IDs, allowed codecs, overflow-safe rectangle arithmetic, decoded image dimensions, payload size, and total texture budget before allocation/copy. Do not let Foundation's NSNumber Boolean bridging accidentally make `true` a valid revision or width. IDs are opaque strings, not numeric monitor indices. Unknown optional fields should not break forward compatibility; unknown required messages/codecs must not be acted on silently.

## 3. Display identity and geometry

Current host display objects provide `id`, `name`, `index`, native pixel `width`/`height`, global logical-point `x`/`y`, `logicalWidth`/`logicalHeight`, and `scale`. The welcome builder also supplies `primary` based on the host's display index; tolerate its absence for older/other hosts. Use array ordering/index only for presentation labels, never as persistent identity.

Prefer logical dimensions; fall back to native dimensions divided by a validated `scale` when optional geometry is absent. With no origin metadata, use a deterministic horizontal arrangement. Keep native pixels, stream pixels, host logical points, phone points, and drawable pixels as distinct types/values.

The topology selector depicts every host display in its real logical arrangement. The content view may remove empty horizontal/vertical bands between selected displays, following the current Mac viewer's `displayLayout(...compact:true)`. This changes only the viewer's arrangement, not macOS's display layout. A 5K Retina display with a 1920×1080 logical workspace and a 1080p standard display with the same logical workspace should have equal displayed size.

## 4. Complete-state subscriptions

After a fresh welcome, immediately select **all** valid advertised displays and send revision 1. Start fitted so all are visible. Existing profile selection must not silently restore a smaller display subset on a fresh connection. A later `displays` topology message is different: release input, intersect the existing selection with valid IDs, and resubscribe. If none remain, show an explicit empty selection rather than silently switching control to an unrelated monitor.

Example with all three fixture displays:

```json
{
  "type":"subscribe", "revision":1,
  "displays":["fixture-1","fixture-2","fixture-3"],
  "maxWidth":1280, "maxHeight":720,
  "color":"full", "quality":"auto", "fps":60,
  "bandwidthKbps":0, "paused":false, "audio":false,
  "audioCodec":"aac", "audioBitrate":96000,
  "viewOnly":false, "regions":{}, "dither":false
}
```

Choose `audioCodec` from advertised support when enabling audio; omit the AAC choice or use μ-law if the host lacks it. Sending an AAC preference while audio is off is not proof of working audio.

Each state change has a strictly increasing nonnegative integer revision and resends the whole desired state. The host accepts up to 16 distinct selected IDs, though it may enumerate more. For an exceptional >16-display host, show the protocol limit and require a selection; do not promise literal all-display support beyond the wire limit.

| UI | Wire |
|---|---|
| HD | 1280×720 |
| FHD | 1920×1080 |
| QHD | 2560×1440 |
| UHD | 3840×2160 |
| Full Color / 256 Colors / 16 Shades of Gray | `full` / `color256` / `gray16` |
| Automatic / Text / Video | `auto` / `desktop` / `motion` |
| Automatic video data rate | `bandwidthKbps:0` |
| Manual video data rate | integer 100…100000 kbps |
| Smooth gradients | `dither:true`, effective only in `motion` with reduced color |

FPS remains a wire field, 1…60; request 60 without exposing a user FPS selector. Adaptive throughput comes from the existing host pipeline, not a client-side promise of a constant 60 fps. Static content can legitimately have zero changed-image updates.

The host chooses a common supported preset, handles portrait orientation by swapping the bounding axes, and aspect-fits without upscaling. It acknowledges actual full-canvas dimensions in `subscribed` before producing that revision's frames. It may return `resolution:"native"` for displays smaller than HD even though there is no separate native preset in the client request. Allocate from validated acknowledged dimensions, not from the requested box. Disable unsupported UI presets and enforce a separate phone memory budget.

`regions` maps selected display IDs to normalized full-source rectangles. Omitted display entry means **the entire display**, not none. A completely offscreen selected display needs `{x:0,y:0,width:0,height:0}`. Both dimensions must be zero together. Partial regions retain full-canvas coordinates; they do not become new canvas sizes. Bound x/y/w/h, keep x+w and y+h within 1, and send explicit zero regions for hidden displays.

Important current-host behavior: every accepted subscription stops/recreates video capture, resets image encoders, and **releases held input**. Do not send a subscription for every pinch sample or midway through a remote drag/modifier chord. Start with full selected displays while manipulating locally; send a deduplicated viewport change after the gesture settles. Before enabling aggressive viewport updates, measure restart cost. Preserve a full-region subscription for a held remote drag; any subsequent gesture-related refinement waits until buttons/keys are released.

The current host can maintain audio while `paused:true,audio:true`. Portlight's user-facing Pause should stop both by sending `paused:true,audio:false`, retain the user's audio preference separately, and restore it on Resume. Pause also disables control.

## 5. Image application and acknowledgements

```json
{"type":"frame","revision":1,"display":"fixture-1","x":0,"y":0,"width":128,"height":128,"canvasWidth":1280,"canvasHeight":720,"codec":"png","sequence":12}
```

The raw PNG/JPEG follows that header. x/y are top-left coordinates in the full negotiated stream canvas. A message is a rectangle, not necessarily an entire video frame. Use ImageIO for standard decoding, including **4-bit grayscale PNG** and **8-bit indexed PNG**. Expand to a known texture format; do not write new PNG decoders. Decode dimensions must equal header dimensions; validate before allocating a texture-sized buffer.

Apply accepted rectangles in arrival order per display/revision. Rectangles can overlap and later rectangles win. Preserve unchanged areas. Presentation may be coalesced to one pending draw, but received cumulative patches cannot be dropped indiscriminately. If the decoder queue cannot remain bounded, stop/reconnect or request a fresh subscription at a safe input boundary; don't acknowledge an unapplied patch and pretend the picture remains complete.

Send `{"type":"frameAck","sequence":12}` once the valid patch has been committed to ordered framebuffer state. ACK need not wait for a separate on-screen draw of every patch. For a safely identified old-revision frame, discard its image and still ACK its sequence to free the host's in-flight window, as the Mac reference does. Malformed framing, impossible dimensions, or a decoder failure must fail the session or use an explicit recovery path; do not conceal corrupted images with success claims.

Sequence is session-wide and interleaves audio/image packets. Gaps are normal. Do not require consecutive image sequences. Audio packets receive no frameAck. New connections reset sequencing and revision state; generation validation takes precedence over a coincidentally matching number.

Current host limits include a 32-packet in-flight window, 2 MiB in-flight image limit with one larger initial packet permitted alone, a bounded video queue, and audio priority before unsent video. These are implementation facts, not new client promises. Large TCP messages already submitted can still delay audio.

## 6. Input and local cursor

```json
{"type":"pointer","display":"fixture-1","x":0.5,"y":0.5,"buttons":1}
{"type":"pointer","display":"fixture-1","x":0.6,"y":0.5,"buttons":1}
{"type":"pointer","display":"fixture-1","x":0.6,"y":0.5,"buttons":0}
{"type":"wheel","display":"fixture-1","x":0.6,"y":0.5,"dx":0,"dy":-1}
{"type":"key","key":65515,"down":true}
{"type":"key","key":65515,"down":false}
{"type":"text","text":"héllo"}
```

Pointer x/y are normalized **full-display** coordinates. The host maps them to global macOS logical bounds. Send values in [0,1); current host also accepts 1, but the portable contract should use the half-open range. Mouse mask is left=1, right=2, middle=4. Include the full current mask on every pointer event; changing it causes button transitions. Wheel increments are logical lines; positive dy scrolls up. Do not send UIKit pixels as scroll lines. Current host accumulates fractional lines into pixel events.

Keys use X11/RFB **keysyms**, not USB HID usages or Apple's virtual-key codes. Examples: Return 0xff0d, Escape 0xff1b, Backspace 0xff08, Tab 0xff09, arrows 0xff51…0xff54, Delete 0xffff, Shift 0xffe1, Control 0xffe3, Option 0xffe9, Command 0xffeb, F1…F12 0xffbe…0xffc9. Printable Latin-1 is its codepoint; other Unicode is 0x01000000 OR codepoint. Use `text` for completed Unicode composition, maximum 4096 UTF-8 bytes per message, split only at valid text boundaries. Do not double-send text plus printable key events. Shortcut key chords and composed text are separate paths.

Track and release all held buttons/modifiers/keys on control disable, pause, mode switch, backgrounding, topology loss, disconnect, cancellation, or local UI takeover. Release messages should be sent before changing subscription when possible; the host also releases inputs on subscription/disconnect. In view-only mode, local navigation remains available but no pointer/key/text/wheel messages are sent.

Cursor messages contain display ID and normalized x/y. Render locally. Trackpad movement updates a predicted local cursor immediately; reconcile host messages without allowing stale connection/cursor state to jump to another display. No custom cursor shape or cursor acknowledgment is currently provided. Verify whether each capture build includes the source cursor before adding a second visual pointer.

## 7. Audio

Audio is off by default. Prefer negotiated AAC-LC:

- 48 kHz, raw AAC access units, **no ADTS header**.
- 48 kbps mono; 96/160/320 kbps stereo.
- Header: `type:"audio"`, `codec:"aac"`, revision, sequence, sampleRate=48000, channels=1 or 2, samples=1024, bitrate, base64 `cookie`.
- Bound decoded cookie to 4096 bytes and access unit to 16384 bytes; reject invalid channel/rate/sample declarations.
- Configure the decoder using the cookie. `shared/AAC.swift` is the codec reference; isolate platform audio-session concerns from that code.

Fallback μ-law: 24 kHz mono, 480 samples / 20 ms per packet, 480 payload bytes, about 192 kbps before framing. It is not more bandwidth-efficient than AAC.

Decode/play on a dedicated serialized audio path independent of image decode and UI. Keep a bounded jitter queue; the Mac reference begins AAC playback after roughly three packets (~64 ms). Treat this as a starting point to measure on iPhone, not a fixed optimum. Record underruns, queued duration, and drops. Avoid accumulating seconds of delayed audio.

Video-only revisions should not stop audio. Accept compatible audio from prior video revisions of the same active connection, as the current Mac viewer does, but never from a prior connection. Track an audio-configuration epoch: after Off/On or codec/rate changes, reject old-format packets until the new audio configuration is acknowledged. Revision ordering alone is insufficient to distinguish those cases. No host-provided media timestamp currently establishes rigorous A/V synchronization.

Use AVAudioSession playback behavior on iOS; no microphone permission. Handle interruptions and route changes explicitly. Audio remains foreground-only in the initial app. Calls, Bluetooth, and background transitions require real-device checks.

## 8. Document discrepancies and unsupported capabilities

| Older wording/example | Current implementation / handoff decision |
|---|---|
| Horizontal equal preset boxes | Use host logical geometry; compact empty bands only in content layout. |
| Welcome example omits logical geometry | Current host includes `index`, logical dimensions/origins/scale, and adds `primary` in the welcome builder. |
| Audio discarded on every subscription | September 10 host/viewer preserve audio across video-only revisions. |
| Paused means audio stops automatically | Host allows audio-only pause; iPhone sends audio=false for user Pause. |
| Optional H.264 described | Not implemented/advertised here. Never request or expect it. |
| Multiple viewers/reused capture | Current host permits one authenticated viewer. |
| `rgb565` in capabilities | Legacy support; do not expose it in the iPhone color UI. |
| Saved connection restores monitor subset | Fresh connections must select all displays. |
| Clipboard/SSH/discovery in URC roadmap | Not Portlight wire features. No remote clipboard-get/set, file transfer, or SSH messages exist. |

For initial delivery, correct the iPhone-facing contract and tests. Any required host code change must be narrow, documented, backward-compatible, and built separately from the live studio host. A transport redesign requires a new project decision, not an undocumented iPhone workaround.
