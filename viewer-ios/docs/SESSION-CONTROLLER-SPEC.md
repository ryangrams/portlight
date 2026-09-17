# SessionController — the app-facing session owner

`PortlightKit/Session/SessionController.swift`: `@MainActor @Observable public final class SessionController`.
It is the single owner of one remote session. It wires together the engine, rendering, audio, viewport,
input, and persistence modules.

Two rules hold throughout:
- SwiftUI observes only low-frequency state.
- The render loop reads high-frequency state (transform, cursor) from lock-protected stores, never from the view tree.

## Composition

| Part | Production | Tests |
|---|---|---|
| Engine | `SessionEngine(transportFactory: { WebSocketTransport() }, …)` | `FakeTransport`, `ManualClock` |
| Framebuffer | `MetalFramebufferStore` sharing `MetalRenderer`'s command queue | `SoftwareFramebuffer` |
| Decoder | `ImageTileDecoder` behind `TileDecoding` | the real decoder |
| Audio | `AudioPipeline` + `AudioSessionController` (iOS) | fake `AudioPacketSink` |
| Viewport | `ViewportModel` (value, main actor) + `TransformStore` (lock) for the renderer | same |
| Input | `GestureInterpreter`, `InputLedger`, `ModifierLatches`, `KeyMapping`, `TextInput` | same |
| Persistence | `ProfileStore`, `KeychainSecretStore`, `FileTrustStore`, `ConnectionCredentials` | in-memory stores + `SpySecretStore` |
| Planner | `DefaultSubscriptionPlanner(settings:, pixelBudget:, capabilities:)` | same |
| Policy | `ReconnectPolicy` with a random source | fixed random |

## Observable state

- `phase: ConnectionPhase` and `endpoint: HostEndpoint?`
- `serverName: String?`
- `displays: [HostDisplay]` (host arrangement)
- `selection: [DisplayID]` (host order)
- `settings: SessionSettings` (desired)
- `effective: EffectiveState?`: accepted revision, `EffectiveResolution`, canvases, audio on/codec, and host notice text
- `presetAvailability: [PresetAvailability]`: from capabilities + `RenderBudget`, with reasons
- `audioAvailable: Bool` and `audioState` (off / starting / playing / interrupted)
- `notices: [SessionNotice]` (a queue; the UI shows the first)
- `controlsHidden`, `keyboardRequested`
- `latches: [ModifierKey: ModifierLatch]` and `buttonLatch: MouseButtons?`
- `diagnostics: DiagnosticsSnapshot`: engine + render + audio + scheduler, merged at up to 2 Hz
- `isShowingFrozenFrame: Bool`: reconnecting with retained textures
- `wantsIdleTimerDisabled: Bool`: connected && foreground && surface visible

## Commands

**Connection**
- `connect(profile:typedPassword:)`
  1. Apply the profile's preferences to `settings`.
  2. Resolve the password through `ConnectionCredentials`. This is the only Keychain read.
  3. Look up the pin in `TrustStore`.
  4. Call `engine.connect` with `previousSelection: nil`, so a fresh connection selects all displays.
- `approveTrust(_:)` → `trustStore.pin(...)` → reconnect with the same parameters and the new pin (new generation).
  `declineTrust(_:)` → `.failed(.trustDeclined)`. Approving a stale prompt (its id is not the current phase's) is a no-op.
- `cancel()`; `disconnect()` (explicit):
  - `releaseInput()`, then stop audio and call `engine.disconnect()`.
  - Clear the in-memory password and `framebuffer.removeAll()`.
  - Phase becomes `.idle`.

**Selection**
- `toggleDisplay(_:)`, `selectAll()`, `selectNone()`, `setSelection(_:)`:
  - Call `releaseInput()` first.
  - Update `selection` and recompute the compact layout (`DesktopLayout.arrange`).
  - Call `viewport.setLayout` (Fit → refit; otherwise keep the anchor), then submit.
- `None` is valid: submit `displays: []`, show the empty state, allow no input.

**Settings.** Setters for resolution, color, quality, smooth gradients, bandwidth, audio enabled, audio
quality, control enabled, paused, and input mode.
- Resolution uses `RenderBudget.highestPreset`. The budget limit is shown in `presetAvailability`.
- Preferences persist to the profile: resolution, color, quality, input mode, audio quality, bandwidth, smooth gradients.
- **Control Off, Pause and mode switch** release input and clear latches first.
- **Pause** sends `paused: true, audio: false` and keeps `settings.audioEnabled`. Resume restores it.
- **Resolution-only changes never touch the viewport** (the world is in logical points).

**Viewport**
- `surfaceGeometryChanged(drawableSize:usableRect:contentScale:)` → `viewport.setGeometry`.
- `fit()`, `actualSize()`, `zoom(in:)`.
- `viewport` is mutated only by gestures, geometry, and explicit layout changes. Frames have no path to it.

**Input** (all on the main actor, in order)
- `touch(_ event: TouchEvent, at:)` and `tick(at:)` feed `GestureInterpreter` with the viewport as `PointerMapping`. Effects:
  - `.viewport` → view points × `contentScale` → `ViewportModel`.
  - `.remote` → gated by `allowsInput(at target)`, then `ledger.apply(action, modifiers: latches.effective)` → `engine.send(input:)`; consumed latches are updated.
  - `.cursorMoved` → `CursorStore`.
  - `.revealControls` → `controlsHidden = false`.
- `allowsInput(at:)` requires `phase == .connected`, `settings.allowsRemoteInput`, a non-empty selection, and
  `framebuffer.hasValidPixels` at the target for presses and scrolls. New or exposed regions are not
  controllable until their pixels arrive.
- Hardware keys: `press(hidUsage:characters:modifiers:down:)` → `KeyMapping` → ledger.
- Soft keys: `pressSoftKey(_:)`; modifier chips: `tapModifier(_:)`.
- Mouse controls: `click(_:)`, `toggleButtonLatch(_:)`.
- Text: `insertText(_:)` → `TextInput` → `ledger.text`; `deleteBackward()` → Backspace.
- Paste: `typePastedText(_:)` reuses the text path with UTF-8-safe chunks. It never reads the pasteboard itself.

**Region refinement** (`RegionScheduler`)
- 150 ms after the last viewport change, with no touches active, not holding input, not paused, and connected:
  - Compute `RegionPlanner.regions(visibleDesktop: viewport.visibleDesktopRect)`.
  - Submit only if `needsRefinement(current: accepted regions, visibleNow:)`.
- If input is held, defer until it is released.
- Record subscriptions per minute and time-to-fresh-region (submit → requested region covered).

**Lifecycle**
- `scenePhaseChanged(.inactive)`: `releaseInput()`.
- `.background`, when connected:
  - Set `resumeOnForeground = true`, stop audio, and call `engine.disconnect()` (graceful close inside the app's background-task window).
  - Keep the textures. Phase becomes `.reconnecting(attempt: 0, after: .networkLost)`, and the UI shows the privacy cover.
- `.active` with `resumeOnForeground`: reconnect with `previousSelection: selection`; missing IDs are dropped by the planner.
- **Automatic retries** follow `ReconnectPolicy` while in the foreground. They stop on non-retryable failures,
  including `certificateChanged`, which surfaces the trust sheet instead.
- **Topology change** (`didReceiveWelcome(topologyChange: true)`):
  - `releaseInput()`, update `displays`, and intersect the selection.
  - Recompute the layout and resubmit, showing the notice.
  - If the selection becomes empty, show the explicit empty state; never pick another display.

**Engine delegate mapping**
- `didAccept` → the effective state. Held input is never forgotten here: the host releases input when it *processes* `subscribe` (`Server.swift:257`), so input sent after the subscribe is still held. The controller therefore releases everything before any subscription goes out. The first accept → `.connected`, and Fit on the new layout.
- `needsRecoverySubscription` → resubmit with `force` at the next safe boundary.
- `canvasBudgetExceeded` → a notice asking for fewer displays. The engine has already paused the stream.
- `hostReported`:
  - capture → `.captureFailed`
  - subscription → `.settingsRejected` (the desired state stays; the old revision keeps streaming)
  - topology → handled as above

## Required tests (Tests/PortlightKitTests/Session/)

**Unit tests (fakes)**
- A fresh connect selects all displays (DISP-01 unit).
- A display toggle sends releases before the subscribe.
- Pause/resume wire values and audio preference.
- View Only and Pause send zero input (VIEW-02).
- A mode switch releases input and clears latches.
- Background → foreground reconnects with the restored selection minus missing IDs.
- A certificate change stops automatic reconnect.
- An authentication failure is never retried.
- `busy` during an automatic reconnect is retried inside its window.
- A topology change intersects the selection and handles the empty case.
- Region refinement happens only after settle, and never while input is held (REGION-01).
- **RENDER-03 no-jump:** a 240-step gesture trace runs while the engine applies a tile flood through
  `SoftwareFramebuffer`. The resulting transforms are bit-identical to the same trace without frames, with
  positive committed and presented counts.

**Integration tests (macOS, real processes; skipped with a message when binaries are missing)**
- Against the real `--fixture` host:
  - DISP-01: revision 1 selects all 3 displays; decoded frames > 0; rejected == 0; transcript saved.
  - NET-01: first use → trust prompt; approve → pinned; reconnect uses the pin; changed certificate → stop.
  - NET-04: wrong password.
  - Busy (two sessions).
  - Refused (unused port).
  - Cancel/disconnect returns to idle.
- Against `scripts/mock-host.py`:
  - Input transcripts per mode.
  - AAC audio across a video-only revision.
  - Stale bursts.
  - Malformed data.
  - No welcome.
  - Stall → network lost.
  - Topology change.
