import SwiftUI
import UIKit

// Accessibility settings in one place. Components follow the system settings; the UI gallery can force a
// treatment on for screenshots. A forced value only adds a treatment, it never removes one the user chose.

struct AccessibilityOverrides: Equatable, Sendable {
    var reduceTransparency = false
    var reduceMotion = false
    var increaseContrast = false
}

private struct AccessibilityOverridesKey: EnvironmentKey {
    static let defaultValue = AccessibilityOverrides()
}

extension EnvironmentValues {
    var accessibilityOverrides: AccessibilityOverrides {
        get { self[AccessibilityOverridesKey.self] }
        set { self[AccessibilityOverridesKey.self] = newValue }
    }
}

/// Effective Reduce Transparency / Reduce Motion / Increase Contrast, read inside a view's `body`.
struct PortlightAccessibility: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityOverrides) private var overrides

    init() {}

    var reduceTransparency: Bool { systemReduceTransparency || overrides.reduceTransparency }
    var reduceMotion: Bool { systemReduceMotion || overrides.reduceMotion }
    var increaseContrast: Bool { contrast == .increased || overrides.increaseContrast }

    /// Selected-state outline: 2 pt, thicker with Increase Contrast.
    var selectedOutline: CGFloat { increaseContrast ? 3 : 2 }
    /// Outline of idle controls: a hairline that becomes clearly visible with Increase Contrast.
    var idleOutline: CGFloat { increaseContrast ? 1.5 : 0.5 }

    /// Slides become fades with Reduce Motion.
    func transition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    var animation: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.1) }
}

extension View {
    /// Announces a changed status text to VoiceOver (progress card title and detail, banners).
    func announcesChanges(of text: String) -> some View {
        onChange(of: text) { _, newValue in
            UIAccessibility.post(notification: .announcement, argument: newValue)
        }
    }
}
