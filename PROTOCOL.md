# SU Remote protocol v1

All components implement this exact contract. One secure WebSocket connection per viewer/server session. Server default TCP port **5920**, path `/remote`. TLS with generated server identity. Viewer shows/trusts SHA256 leaf fingerprint before sending password; persist trust per host:port, reject changed identity pending new explicit approval. Fresh implementation, no copied GPL source. Use platform TLS. Passwords only inside verified TLS; server stores PBKDF2-HMAC-SHA256 salted verifier (100000+ iterations), no plaintext logs.

Text messages are UTF-8 JSON objects. Binary messages: first 4 bytes big-endian unsigned JSON-header byte count; then UTF-8 JSON header; then raw payload. Header maximum 64KiB, total WebSocket message maximum 32MiB. Unknown message types return error. Validate all dimensions/ranges. All display IDs are **strings**. Revision is nonnegative integer.

## Authentication

Client first sends `{"type":"hello","version":1,"password":"..."}`.
Server responds `{"type":"welcome","version":1,"serverName":"My Mac","sessionId":"uuid","displays":[{"id":"stable-id","name":"Display 1","width":3840,"height":2160,"primary":true}],"capabilities":{"codecs":["png","jpeg"],"audio":["mulaw"],"colorModes":["gray16","color256","rgb565","full"]}}`.
Width/height are actual source pixel dimensions, not Retina logical dimensions. Displays listed primary first. No image/audio/input before authentication. Wrong password: `{"type":"error","code":"authentication","message":"Incorrect password"}` then close. Rate-limit failed authentication.

## Subscription

Client sends full desired state on each change:
`{"type":"subscribe","revision":1,"displays":["id1","id3"],"maxWidth":1920,"maxHeight":1080,"color":"full","quality":"auto","fps":15,"bandwidthKbps":4000,"paused":false,"audio":false,"viewOnly":false,"regions":{}}`.
Preset boxes: HD1280x720, FHD1920x1080,QHD2560x1440,UHD3840x2160. Do not upscale; common preset cannot exceed any selected display's native limits. Server clamps/fails unsupported choice with clear response. Aspect-fit actual output; no stretching. Color enum gray16,color256,rgb565,full. Quality desktop,motion,auto. fps1..60. bandwidthKbps0=automatic; otherwise100..100000. regions optional map displayID to normalized `{x:0,y:0,width:1,height:1}` visible source region, default whole display. Allow small bounded prefetch margin server-side. Empty display list/paused=true causes no image production. Audio toggle separate; default false. Only capture monitors subscribed by at least one viewer; reuse compatible work.

Server acknowledges BEFORE output for the revision:
`{"type":"subscribed","revision":1,"displays":[{"id":"id1","width":1920,"height":1080},{"id":"id3","width":1728,"height":1080}],"paused":false,"audio":false}`.
Output width/height describe full scaled display, even if viewport requests crop. Viewer arranges display canvases horizontally in equal selected preset areas, preserving aspect. Outdated frame revisions are dropped. Discard stale pending outbound frames when subscriptions change. On switch/resume send fresh frames for exposed region. If topology changes send a new `welcome`-shaped `{"type":"displays",...}` and require valid selected IDs; never target another screen silently.

## Image

Binary header `{"type":"frame","revision":1,"display":"id1","x":0,"y":0,"width":128,"height":128,"canvasWidth":1920,"canvasHeight":1080,"codec":"png","sequence":1}` followed by encoded PNG/JPEG rectangle. Coordinates are in scaled full-display pixels. PNG preferred desktop/quantized; JPEG for motion/full color. Decode dimensions must match header; reject out-of-bounds rectangles. Changed rectangles only; cursor separated if possible, otherwise changed cursor tiles. No unselected-screen payload. Client sends `{"type":"frameAck","sequence":1}` after accepting/painting each frame; server bounds in-flight bytes/frames and drops superseded work safely. Use continuous sequence per session.

Optional capability-negotiated h264: binary frame with codec=h264, full display rect, `keyframe:true/false`; payload Annex-B includes SPS/PPS on keyframes. Only send when client hello includes `"codecs":["png","jpeg","h264"]`. Never require it for initial interoperability; add where native decoders are implemented.

Cursor metadata is a text message `{type:"cursor",display:"id1",x:0.5,y:0.5}` using normalized full-display coordinates. It only describes a selected visible screen. Viewers draw the cursor locally; cursor movement does not require new image tiles.

## Input

Client `{"type":"pointer","display":"id1","x":0.5,"y":0.5,"buttons":0}`. x/y normalized full display coordinates [0,1), buttons bit1left,bit2right,bit4middle; all pointer events include current mask. Server maps normalized position into macOS logical global display bounds. Track transitions and release inputs on disconnect/viewOnly/selection loss. Source must currently be subscribed.

Wheel: `{"type":"wheel","display":"id1","x":0.5,"y":0.5,"dx":0,"dy":-1}` with increments in logical scroll lines (positive dy scrolls up). `{"type":"key","key":65293,"down":true}` key is **X11/RFB keysym** for special keys (Return0xff0d,Escape0xff1b,Backspace0xff08,Tab0xff09,Left0xff51,Up0xff52,Right0xff53,Down0xff54,Delete0xffff,Shift_L0xffe1,Control_L0xffe3,Alt_L0xffe9,Super_L0xffeb,F1..F12 0xffbe..0xffc9); printable Latin-1 uses codepoint, other Unicode 0x01000000|codepoint. Protocol numbers are interoperable constants, not copied GPL implementation. Text composition can send `{"type":"text","text":"..."}` for composed Unicode, max4096 UTF8 bytes. OS-specific key generation must avoid double emitting printable text.

## Audio

When requested only, binary header `{"type":"audio","revision":1,"codec":"mulaw","sampleRate":24000,"channels":1,"sequence":100,"samples":480}` plus G.711 μ-law 8bit mono samples, 20ms per packet. Low-bandwidth preview audio:192kbps nominal; state this honestly. Native SCK system mix once/session (not per monitor). Bounded playback jitter queue; dropping old audio preferable to ever-growing delay. No microphone capture. Turn OFF releases server audio capture when no other subscriber. Server can advertise empty audio capability if actual runtime lacks permission/support. PCM16 optional negotiate later; do not send unsupported codecs.

## State and errors

`{"type":"stats","bytesSent":1234,"fps":15,"streamingDisplays":["id1"],"audio":false}` optional effectiveResolution/quality fields. Client ping `{"type":"ping","time":123}` => pong same time. `{"type":"error","code":"subscription","message":"..."}`. Generic errors must not disclose passwords/token paths.

## OSC (both viewers)

Default UDP listen127.0.0.1:19790, OSC1.0 int/float/string args. Shared actions: `/su/remote/connect` string saved preset/name or host; `/su/remote/disconnect`; `/su/remote/monitors/select` string display IDs; `/su/remote/resolution` string hd/fhd/qhd/uhd; `/su/remote/color` string gray16/color256/rgb565/full; `/su/remote/zoom` float; `/su/remote/zoom/fit`; `/su/remote/fullscreen` int0/1; `/su/remote/pan/mode` stringfollow/manual; `/su/remote/paused` int0/1; `/su/remote/viewonly` int0/1; `/su/remote/audio` int0/1; `/su/remote/preset/recall` string; `/su/remote/state/get`. State query replies to sender `/su/remote/state` one JSON string with no secrets. Never trigger untrusted certificate approval or password dialogs remotely without user-visible UI. Invalid commands return `/su/remote/error` string. OSC networking remains separate local control of viewer; it does not create another server connection.

## ZeroTier helper integration

Bundled optional executable `su-zerotier` accepts one JSON request on stdin and prints one JSON response then exits. Viewers launch directly, never via interpolated shell. No token in args/stdout. Request `{"action":"status"}` => `{ok:true,installed:true,online:true,networks:[{id,name,status,assignedAddresses,...}]}`. Activate: `{action:"activate",networkId:"16hex",managedNetworkIds:["16hex"],sessionId:"viewer-uuid"}` => `{ok:true,transactionId:"uuid",networks:[...]}`. Restore `{action:"restore",transactionId:"uuid"}`. Exclusivity only affects explicit managed list, current desired network preserved. Helper persists transactions, refuses overlapping active network transactions rather than disrupting another session. UI must show plan before first preset policy saves; user-selected networks only.

Conflicting managed memberships are left **before** joining the desired network. The helper stores a checkpoint after each change so interrupted restoration can be retried. Status includes `pendingTransactions` with `transactionId`, `networkId`, `sessionId`, and `phase`. `{action:"forget",transactionId:"..."}` deletes only that recovery record; it never changes networks and the viewer must explain/confirm the loss of saved restoration state. Failure responses use `message` for human-readable detail and optional `code`. Transaction IDs are opaque strings.
