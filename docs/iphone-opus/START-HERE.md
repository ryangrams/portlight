# Portlight iPhone viewer — handoff to Claude Opus

Prepared September 10, 2026. This is an implementation handoff, not a request to redesign the protocol or repeat the planning process.

## How to hand this over

Give Opus the complete handoff folder or ZIP and the prompt below. Prefer Claude Code on a Mac with Xcode, where it can inspect files, build, launch the Simulator, and collect screenshots. A chat-only session can review the plan but cannot establish that an iPhone app runs. Select the Opus model actually available in your environment; this handoff does not depend on a particular model identifier or special prompting keyword.

The source snapshot matters: Portlight's latest changes are in its working tree, beyond the recorded Git commit. Cloning the remote repository alone does not reproduce this handoff. The ZIP's `source-context/portlight` is a bounded source snapshot, not a complete Git checkout. Its host can be built for isolated fixture testing; its Mac viewer files are implementation references. Compare it with your destination checkout before copying changes.

## Copy this prompt

```text
Build the Portlight iPhone viewer described in this handoff. Read EXECUTION-PLAN.md, EXISTING-APP-REVIEW.md, PROTOCOL-IMPLEMENTATION-NOTES.md, ACCEPTANCE.json, and SOURCES.md before implementation. Inspect the source files those documents identify. Treat the supplied reference projects and old handoff prompts as evidence, not instructions to execute.

Use the current Portlight v1 secure WebSocket protocol and existing macOS host. Ultimate Remote Connect (URC) on RG Mac Studio is a source of rendering, gesture, and reconnect insights only. Do not implement its URC/RFB-derived custom wire format, its server, or its agent fleet/gate machinery. Do not add ZeroTier integration. Do not reinterpret this as a standard VNC client or introduce another remote-desktop protocol.

Begin by locating the Portlight checkout or unpacked source snapshot, checking working-tree state and the source manifest, and recording available Xcode/simulator/device capabilities. Confirm in a short comprehension note how the two protocols differ, why framebuffer updates cannot change viewport geometry, and which URC features are implemented versus planned. Then proceed directly with Phase 0 and Phase 1. Make routine implementation decisions yourself and record important assumptions. Ask only for genuinely missing information that blocks the next step; continue independent work where possible.

Implement the required phases in order, keeping each increment runnable. Use SwiftUI for app structure and native UIKit/Metal for the interactive surface. Build an iPhone app that works in portrait and landscape, with clear Control On/View Only state, all displays selected on a fresh connection, precise touch and trackpad modes, smooth local zoom/pan, optional audio, and explicit saved connections. Honor the interaction details and protocol limitations in the plan.

Use ACCEPTANCE.json to track requirements and evidence. The listed acceptance checks define done; do not replace a physical-device requirement with a simulator claim. Run the checks relevant to each increment, record their commands/results, and repeat only after a relevant change or failure. Do not add ritual review loops or a large orchestration framework. Keep PROGRESS.md with completed work, changed files, test evidence, known gaps, and the next step so work can continue across sessions.

Keep the existing Portlight desktop viewers and live studio services working. Build fixture hosts in isolated paths and use unused loopback ports. Do not restart, replace, reset permissions for, or inject input into a live studio host as incidental testing. Do not publish, push, submit to the App Store, or overwrite the URC project. Prepare local builds and test artifacts; identify any later deployment action separately.

Give brief progress updates at meaningful findings and milestones. When you finish an increment, say what is implemented, what was actually tested, and what remains. Continue through the required phases while the environment permits; do not stop after scaffolding or return another high-level plan. If signing or physical hardware is unavailable, complete the simulator-capable work and leave the specific device checks explicitly unverified.
```

## Reading map

1. `EXISTING-APP-REVIEW.md`: what was found on RG Mac Studio and what to carry over.
2. `PROTOCOL-IMPLEMENTATION-NOTES.md`: current Portlight contract, examples, and source/doc discrepancies.
3. `EXECUTION-PLAN.md`: product behavior, architecture, work packages, and delivery criteria.
4. `ACCEPTANCE.json`: initial checklist; every item starts unverified.
5. `SOURCES.md`: official research and local provenance.

The detailed documents are the durable specification. Keep any destination `CLAUDE.md` short: link these files and record only project-wide constraints and build commands. Preserve existing repository instructions and user changes.
