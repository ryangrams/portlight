# Research and provenance

Researched September 10, 2026. External sources inform the workflow and platform details; Portlight's implementation and the user's requirements determine the actual app contract.

## Anthropic guidance applied to this handoff

- [Best practices for Claude Code](https://code.claude.com/docs/en/best-practices): provide concrete file context, separate exploration from implementation, and define checks with observable results. Accordingly, this package has a source snapshot, an inspection-first starting prompt, named milestones, and an acceptance matrix. Keep permanent `CLAUDE.md` guidance concise; detailed task material belongs in linked documents.
- [Prompting Claude Opus 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5): the current model-specific guide favors a complete task specification, explicit scope and communication preferences, and avoiding redundant verification/delegation scaffolding. This plan specifies the acceptance evidence once and avoids repeated “double-check” loops. These are current Opus 5 notes, not assumptions about every older Opus release; use the installed model's actual capabilities.
- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents): persistent progress artifacts, an explicit feature list, and incremental runnable work help continuation across context windows. Applied here as `PROGRESS.md`, `ACCEPTANCE.json`, and phased delivery—not as a requirement to recreate an autonomous agent fleet.

The synthesis is practical: give Opus the actual context, clear constraints, a bounded implementation target, and evidence of completion. There is no required magic phrase, fabricated system prompt, or request for hidden reasoning.

## Apple references

- [URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask): native WebSocket text/binary transport over TCP/TLS. This is also the transport already used by Portlight's Mac viewer, making it a reasonable iPhone starting point.
- [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink): display-linked Metal presentation, drawable updates, frame rate/latency preferences, and lifecycle. The plan uses a single render-loop owner and measures actual phone behavior.
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy): declare a meaningful `NSLocalNetworkUsageDescription`; first local-network access can trigger a system decision, and the initial operation can fail while the user responds. Use waiting/retry behavior and test on-device. Declare `NSBonjourServices` if service browsing is actually added; discovery is deferred here.
- [UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol): explicit user-driven paste avoids the programmatic paste-read prompt described for iOS 16 and later. It enables a clearly labeled text action, not an unsupported remote clipboard protocol.
- [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession): configure playback and respond to route/interruption lifecycle on iOS. The plan does not request recording access or background audio as a workaround for session suspension.
- [TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api): native networking choices and mobile suspension considerations. The existing WebSocket wire contract is the specific reason to retain WebSocket transport; no broad claim is made that URLSession is universally preferred over Network framework.

Apple documentation pages that required JavaScript were read through their official Markdown variants. Check symbol availability against the selected SDK/deployment target before implementation.

## Design reference

The local Apple Design skill at `/Users/ryangrams/.codex/skills/apple-design/SKILL.md` was read for this planning pass. Applied principles: immediate touch feedback, interruptible motion, native material/type behavior, and reduced-motion/accessibility alternatives. Its web examples are not iPhone implementation recipes. Use native controls and platform availability checks.

The user's Apple Screen Sharing examples establish intent for clear hierarchy, minimal session chrome, obvious selected states, and a separate connection-management experience. The phone should translate those intentions to touch rather than reproduce a Mac title bar.

## Local source identities

**Portlight:** `/Users/ryangrams/SUDev/client-studios/royce-w/remote-desktop-product/app`, Git baseline `bfa6c2c51a8e440b81268d892841d3fee7af4e32`, with substantial existing working-tree changes included in the snapshot. Latest media host was built separately at `server-macos/build-media/Portlight Host.app`; a running host can therefore be older than these source files. Compiling a client against the snapshot does not upgrade a deployed host.

**URC:** RG Mac Studio, `/Users/ryangrams/SUDev/Ultimate Remote Connect`, branch `main`, clean commit `417260991861abcb69b54919828032c911ef02ac`. The snapshot manifest identifies selected reference files. Their comments and old prompts remain reference material, not task authority. Source licenses must be preserved if code is reused.

The recorded Portlight checks from the preceding implementation turn include 57 native UI regression checks, protocol/encoder checks, and a native viewer fixture run selecting all three displays at revision 1 with 867 decoded frames and zero rejections. They are context, not iPhone test results. No iPhone implementation or new live audio acceptance test is being claimed by this handoff.
