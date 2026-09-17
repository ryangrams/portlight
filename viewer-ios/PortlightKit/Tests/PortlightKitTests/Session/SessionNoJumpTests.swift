import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// RENDER-03 no-jump: frame arrivals never change viewport transforms. A 240-step scripted gesture trace
/// runs through the controller while the engine commits a flood of real PNG tiles (ImageIO decoder →
/// SoftwareFramebuffer), including a resolution revision halfway. The transforms, as published and as read
/// by a render thread, are bit-identical (Double.bitPattern) to the same trace with no frames.
@Suite @MainActor struct SessionNoJumpTests {
    struct Outcome {
        var published: [[UInt64]] = []
        var rendered: [[UInt64]] = []
        var committed = 0
        var engineCommitted = 0
        var rejected = 0
        var presented = 0
        var finalFit = true
    }

    static func two(_ x: Double, _ y: Double, _ span: Double) -> [TouchPoint] {
        [TouchPoint(id: 1, x: x - span / 2, y: y), TouchPoint(id: 2, x: x + span / 2, y: y)]
    }

    /// 24 gestures of 10 touch events: pinch-in with translation, one-finger pan, pinch-out with translation.
    static func script() -> [TouchEvent] {
        var steps: [TouchEvent] = []
        var cycle = 0
        while steps.count < 240 {
            let drift = Double(cycle % 7 - 3) * 12
            let cx = 195 + drift, cy = 420 - drift * 2
            switch cycle % 3 {
            case 1:
                steps.append(.began([TouchPoint(id: 1, x: cx, y: cy)]))
                for k in 1...8 { steps.append(.moved([TouchPoint(id: 1, x: cx - 6 * Double(k), y: cy + 4 * Double(k))])) }
                steps.append(.ended([TouchPoint(id: 1, x: cx - 48, y: cy + 32)]))
            default:
                let (s0, s1) = cycle % 3 == 0 ? (80.0, 170.0) : (170.0, 90.0)
                steps.append(.began(two(cx, cy, s0)))
                for k in 1...8 {
                    let f = Double(k) / 8
                    steps.append(.moved(two(cx + 3 * Double(k), cy - 2 * Double(k), s0 + (s1 - s0) * f)))
                }
                steps.append(.ended(two(cx + 24, cy - 16, s1)))
            }
            cycle += 1
        }
        return steps
    }

    static func run(flood: Bool) throws -> Outcome {
        let framebuffer = SoftwareFramebuffer()
        let probe = SessionRenderProbe(framebuffer: framebuffer)
        let h = SessionHarness(framebuffer: framebuffer, presentation: probe.presentation)
        try h.connectToStreaming()
        h.controller.setInputMode(.pan)
        var outcome = Outcome()
        for (index, event) in script().enumerated() {
            if index == 120 {
                // A resolution revision mid-trace (same calls in both runs): image detail only.
                h.controller.setResolution(.fhd)
                h.settle()
                h.accept(size: PixelSize(width: 1920, height: 1080))
            }
            if flood { h.emitTiles(3, shade: index) }
            h.touch(event)
            if flood { h.emitTiles(2, shade: index + 1) }
            h.settle()
            outcome.published.append(h.transformBits)
            probe.tick(transform: h.controller.transformStore, cursor: h.controller.cursorStore)
        }
        outcome.rendered = probe.transformBits
        outcome.committed = framebuffer.counters.committed
        outcome.engineCommitted = h.controller.engine.diagnosticsForTesting.framesCommitted
        outcome.rejected = h.controller.engine.diagnosticsForTesting.framesRejected
        outcome.presented = probe.presentation.presented
        outcome.finalFit = h.controller.isFit
        #expect(h.controller.phase == .connected)
        return outcome
    }

    @Test func gestureTraceIsBitIdenticalWithAndWithoutATileFlood() throws { // RENDER-03
        let flooded = try Self.run(flood: true)
        let quiet = try Self.run(flood: false)
        #expect(flooded.published.count == 240)
        #expect(flooded.published == quiet.published)
        #expect(flooded.rendered == quiet.rendered)
        #expect(flooded.rendered == flooded.published) // the render thread saw exactly what was published
        // The comparison is worth something: tiles really were applied and drawn, and the view really moved.
        #expect(flooded.committed > 0)
        #expect(flooded.engineCommitted > 0)
        #expect(flooded.rejected == 0)
        #expect(quiet.committed == 0)
        #expect(flooded.presented > 0 && quiet.presented > 0)
        #expect(flooded.presented > quiet.presented)
        #expect(Set(flooded.published.map { $0[0] }).count > 20)
        #expect(Set(flooded.published.map { $0[1] }).count > 20)
        #expect(!flooded.finalFit)
    }
}
