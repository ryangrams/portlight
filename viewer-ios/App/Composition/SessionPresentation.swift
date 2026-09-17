import Foundation
import CoreGraphics
import PortlightKit

/// Pure mappings from the session controller's state to what the session screen shows. Kept free of views so
/// the hosted unit tests can check them.
enum SessionPresentation {
    /// The top bar's secondary line: the phase, "Paused", or the effective resolution once connected.
    static func statusLine(phase: ConnectionPhase, paused: Bool, effective: EffectiveResolution?) -> String {
        switch phase {
        case .connected:
            if paused { return "Paused" }
            switch effective {
            case .preset(let preset)?: return "Connected · \(preset.title)"
            case .native?: return "Connected · Native"
            case nil: return "Connected"
            }
        default:
            return phase.title
        }
    }

    /// The Audio button's disabled reason: known only once the host's capabilities arrived.
    static func audioUnavailableReason(capabilities: HostCapabilities?) -> String? {
        guard let capabilities, !capabilities.supportsAudio else { return nil }
        return SessionNotice.audioUnavailable.message
    }

    /// The chrome is shown while connected and over a frozen frame while reconnecting; a first attempt, a trust
    /// decision or a failure shows only its card.
    static func showsChrome(phase: ConnectionPhase, isShowingFrozenFrame: Bool) -> Bool {
        phase == .connected || isShowingFrozenFrame
    }

    /// The rect Fit uses, in drawable pixels: the surface's safe area minus the visible chrome and any part of
    /// the keyboard (with its accessory bar) that reaches above the safe area's bottom edge.
    /// - Parameters:
    ///   - chrome: edges the chrome covers, in points, measured inside the safe area (zero when hidden).
    ///   - keyboardOverlap: points the keyboard covers above the safe area's bottom edge.
    static func usableRect(safe: DrawableRect, contentScale: Double, chrome: ChromeInsets, keyboardOverlap: CGFloat = 0) -> DrawableRect {
        let scale = contentScale
        let left = Double(chrome.leading) * scale
        let right = Double(chrome.trailing) * scale
        let top = Double(chrome.top) * scale
        let bottom = Double(chrome.bottom + max(0, keyboardOverlap)) * scale
        return DrawableRect(x: safe.x + left, y: safe.y + top,
                            width: max(1, safe.width - left - right), height: max(1, safe.height - top - bottom))
    }

    /// Points the keyboard (with its accessory bar) covers above the safe area's bottom edge.
    /// - Parameter keyboardTop: the keyboard's top edge in the surface's coordinates (points from the top of the
    ///   full-screen surface); nil when no keyboard is shown.
    static func keyboardOverlap(keyboardTop: CGFloat?, surface: SurfaceGeometry?) -> CGFloat {
        guard let keyboardTop, let surface, surface.contentScale > 0 else { return 0 }
        let safeBottom = (surface.usableRect.y + surface.usableRect.height) / surface.contentScale
        return max(0, CGFloat(safeBottom) - keyboardTop)
    }

    static func qualityStatus(settings: SessionSettings, effective: EffectiveState?, budgetExceeded: Bool) -> QualityStatus {
        QualityStatus(requested: settings.resolution, effective: effective?.resolution,
                      limitation: budgetExceeded ? "choose fewer displays" : nil)
    }

    static func diagnosticsReport(_ snapshot: DiagnosticsSnapshot, displays: [HostDisplay], requested: ResolutionPreset,
                                  computerName: String?) -> DiagnosticsReport {
        let numbers = Dictionary(displays.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        let canvases = snapshot.canvases.compactMap { id, size in numbers[id].map { DiagnosticsCanvas(number: $0, size: size) } }
            .sorted { $0.number < $1.number }
        return DiagnosticsReport(engine: snapshot.engine, audio: snapshot.audio ?? AudioMetrics(),
                                 presentedDraws: snapshot.presented ?? 0, skippedDraws: snapshot.skippedPresentations ?? 0,
                                 receiveMbps: snapshot.receiveMbps, changedImagesPerSecond: snapshot.changedImagesPerSecond,
                                 subscriptionsPerMinute: Double(snapshot.regions.subscriptionsLastMinute),
                                 timeToFreshRegion: snapshot.regions.lastTimeToFreshRegion,
                                 requested: snapshot.requestedResolution ?? requested, effective: snapshot.effectiveResolution,
                                 canvases: canvases, computerName: computerName)
    }
}

extension ModifierLatches {
    /// A value showing exactly `states` (the controller's published latches), for the keyboard bar. It is display
    /// state only: taps still go to the controller, which owns the real state machine.
    init(displaying states: [ModifierKey: ModifierLatch]) {
        self.init()
        for key in ModifierKey.allCases {
            switch states[key] ?? .off {
            case .off:
                break
            case .latched:
                tap(key, at: 0)
            case .locked:
                tap(key, at: 0)
                tap(key, at: Self.lockInterval / 2)
            }
        }
    }
}
