# What was found on RG Mac Studio

## Identity and inspection scope

The matching project is **Ultimate Remote Connect (URC)** at `/Users/ryangrams/SUDev/Ultimate Remote Connect` on **RG Mac Studio** (`ssh studio`). This is distinct from FPR's Mac Studio, which has been a Portlight deployment target.

Inspected September 10, 2026:

- URC branch `main`, commit `417260991861abcb69b54919828032c911ef02ac`; working tree was clean.
- RG Mac Studio reported macOS 26.3 and Xcode 26.6. Available simulator runtime was iOS 26.5, including iPhone and iPad devices. This is a dated inventory, not a minimum deployment requirement.
- Read product/roadmap/research documents, iOS rules, the prior Fable handoff, connection-state ADR, iOS shell and gesture source, render/viewport source, test structure, and historical alpha reports. Inspected the archived iPhone Simulator image.
- No live URC server was restarted, no studio input was injected, and no current end-to-end URC run was performed. Its historical test reports are evidence of those recorded runs, not a fresh certification.

The user wants URC's functional insights considered, but **does not want its protocol**. The implementation destination is Portlight. Neither the URC instructions nor its older Fable prompt authorize following its build queue, modifying its server, or importing its protocol.

## Protocol boundary verified

URC begins with a server-first 12-byte `URCP` preamble and uses its own TLV messages, capture-pixel pointer coordinates, HID-usage key events, display-select negotiation, and credit flow control. Portlight begins with a client JSON hello inside an already trusted WSS connection, uses JSON plus length-prefixed JSON binary headers, normalized per-display pointer coordinates, keysyms, full-state subscriptions, and frame acknowledgements. Similar product goals do not make these protocols interchangeable. No URC codec or transport package belongs in the new viewer.

## What exists versus what is still an intention

| Area | Evidence in URC | Carry into Portlight iPhone |
|---|---|---|
| Persistent Metal framebuffer | `Apps/URCClient/Sources/Render/FramebufferSurfaceView.swift`; `Packages/URCRender/Sources/URCRender/Render/FramebufferTexture.swift` | Yes: network writes pixels; gestures own geometry. Adapt to decoded PNG/JPEG rectangles. |
| Independent viewport transforms | `Viewport/ViewportGestureDriver.swift`, `ViewportGeometry.swift`, `Render/ViewportTransformStore.swift` | Yes: pinch centroid, incremental gesture deltas, stable rotation anchor. Improve the resolution-change behavior described below. |
| Display-linked rendering | Surface view, `RenderPump.swift`, ADR 0019 | Yes: a single display-link owner; use its supplied drawable, bound pending presentation work. |
| Cumulative updates | `Render/PresentationSlot.swift` | Essential: discard redundant presentations, not required rectangle updates. |
| Basic real client loop | `docs/plan/reports/alpha-demo.md`, phase-03 report, archived simulator images | Historical simulator rendering and tap-to-Mac evidence; use as a testing pattern. It is not a polished iPhone UI. |
| Current gesture source | `ViewportGestureController.swift` | Implements pinch, two-finger local pan, and single tap. Comments explicitly reserve conflicts for later input-mode work. |
| Direct/trackpad modes, sticky modifiers, richer mouse gestures | `.claude/rules/ios-client.md`, research §11, roadmap M2 | Required design ideas, not evidence they are all implemented. Resolve gesture conflicts deliberately. |
| Honest connection phases | `docs/adr/0030-a-dial-is-a-state-of-its-own-and-a-bounded-one.md` | Yes: connecting is distinct from negotiating; bounded attempt; actionable failure; a single owner starts the connection. |
| Frozen-frame reconnect | iOS rules, research §7, roadmap M5 | Adopt as desired behavior; retaining a texture is implemented, but a full phone resume experience was not established by this inspection. |
| Profiles, clipboard, discovery, SSH, file transfer | Product/roadmap | Consider individually. Profiles belong in this viewer. Clipboard has protocol limitations. Discovery needs host work. SSH/file transfer are later product expansion. |
| Pairing/authentication stack | `docs/plan/reports/connecting.md` and session packages | Do not port. That July report says off-machine client pairing was incomplete. Portlight already has a different TLS/password flow. |

## The key rendering insight

URC separates three kinds of state: received pixels, viewport transform, and presentation scheduling. A packet can update texels without changing the user's zoom, pan, or gesture recognizers. A frozen image remains smoothly navigable when the network stops.

Its presentation slot makes a subtle but important distinction: once two dirty rectangles have been applied, one draw can show both. Skipping the first draw is safe. Dropping the first rectangle before application is unsafe if later rectangles do not replace it. Portlight also sends partial updates, so a generic “latest frame wins” queue would corrupt its picture.

The current URC renderer imports `URCProtocol` and `URCClientSession`. It is not a drop-in package for Portlight. Its CPU framebuffer mirror serves URC's CopyRect operation, which Portlight does not currently send. Do not bring over CopyRect machinery, raw-pixel expansion, protocol types, or the entire mirror allocation merely to reuse the drawing approach. Reuse small geometry ideas or appropriately attributed compatible code after reviewing its dependencies and license.

## Improvements over the reference, not blind copying

1. URC's gesture driver refits when negotiated framebuffer dimensions change. Portlight must preserve the same logical desktop location and zoom when only stream resolution changes. Fit changes only according to the user's persistent Fit mode or an explicit display/layout action.
2. URC's basic two-finger local pan conflicts with its planned two-finger remote scroll. Portlight needs a visible local Pan mode and an explicit gesture arbitration table.
3. URC's no-jump source is chiefly one-display oriented. Portlight needs per-display textures plus a shared logical desktop composition, including selected displays 1+3 with the unused middle space removed locally.
4. URC's broader plan includes numerous color depths. Portlight exposes exactly Full Color, 256 Colors, and 16 Shades of Gray. Legacy `rgb565` remains a compatibility detail, not an iPhone button.
5. URC's reference says to drop stale frames. Apply the precise cumulative-rectangle interpretation above; it is not permission to drop arbitrary Portlight tiles.
6. URC's older operational plan grew into a substantial fleet/gate system. This handoff uses a small phase plan, requirement list, and evidence log. The app needs a reliable implementation workflow, not another project management subsystem.

## Broader features considered

- **Bring into the initial viewer:** both input modes, sticky modifier keys, software special keys, hardware keyboard handling, local cursor, saved machines, stable mixed-DPI layout, frozen-frame reconnect, explicit connection progress, optional host audio.
- **Bring in a limited form:** explicit iPhone paste as typed text, accurately labeled; it is not remote clipboard synchronization.
- **Schedule separately:** bidirectional clipboard, Bonjour advertisement/discovery, SSH terminal/tunneling, SMB/SFTP transfers, iPad refinements, Shortcuts/OSC automation.
- **Exclude from this handoff:** ZeroTier management/embedding, URC wire protocol, URC server, third-party VNC compatibility, relays/accounts, background control, camera/microphone streaming.

These are deliberate scope decisions based on Portlight's existing capabilities and the user's iPhone-viewer request. They preserve the useful ideas without silently expanding the assignment into URC's entire roadmap.
