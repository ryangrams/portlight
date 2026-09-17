import SwiftUI
import UIKit
import PortlightKit

enum PortlightTheme {
    /// Text and glyphs on an accent fill. The dark-mode accent (#FF8A5C) is too light for white text, so the
    /// colour flips to near-black there: about 5.2:1 in light mode and 7.9:1 in dark mode.
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 1) : .white
    })
    /// Secondary text (details, captions, section headers and footers): the secondary label's colour, less
    /// transparent. About 7:1 on white and grouped backgrounds in light mode, 8:1 on dark ones. The system's
    /// `.secondary` measures 3.4:1 on white, and on materials it turns vibrant, which the accessibility audit rejects.
    static let secondaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.75)
                                           : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.85)
    })
    /// Secondary text on the chrome's materials (bars, rails, paused overlay). Over the black letterbox or the frozen
    /// picture they turn mid-gray in light mode (#BBBCBB under the top bar), so light mode draws the colour opaque:
    /// 5.7:1 there, where `.secondary` measured 2.6:1.
    static let secondaryTextOnMaterial = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.75)
                                           : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 1)
    })
    /// Idle key caps, chips and map tiles.
    static let idleFill = Color(uiColor: .tertiarySystemFill)
    /// Large option buttons inside grouped forms.
    static let optionFill = Color(uiColor: .secondarySystemGroupedBackground)
    /// Cards and banners: opaque (white, or dark gray in dark mode), so their text keeps its contrast over any frozen
    /// picture. The accessibility audit can't judge text on a material: 12:1 on screen was reported as failing.
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    /// Chrome background when Reduce Transparency is on.
    static let solidChrome = Color(uiColor: .secondarySystemBackground)
    /// Errors and destructive actions. Light mode uses the system red's Increase Contrast shade (#D70015): 5.4:1 as
    /// text on white and under white text, where the standard red measured 3.5:1.
    static let error = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemRed : UIColor(red: 215 / 255, green: 0, blue: 21 / 255, alpha: 1)
    })
}

extension View {
    /// Label content of a `.borderedProminent` button. SwiftUI draws white on any tint, which is unreadable on the
    /// light dark-mode accent, so the label picks `PortlightTheme.onAccent` instead. A disabled button keeps the
    /// system's disabled colours: white on its gray fill was invisible.
    func onAccentLabel() -> some View {
        modifier(OnAccentLabel())
    }

    /// A secondary action beside a prominent one: `.bordered`, labelled in the text colour rather than the accent,
    /// which measured 3.9:1 on the gray capsule in light mode.
    func secondaryActionStyle() -> some View {
        buttonStyle(.bordered).tint(Color.primary)
    }

    /// Hugs its content when it fits and scrolls when it's taller than the space offered, so large text scrolls
    /// instead of being clipped. It's one scroll view at every size: the accessibility audit loses track of text that
    /// `ViewThatFits` swaps into a scroll view. For the cards and empty states centred over the session or a list.
    func scrollsWhenTaller() -> some View {
        FitOrScroll {
            ScrollView {
                self.frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Gives its one subview, a vertical scroll view, the height of the scroll view's content, capped at the height
/// offered. When the content fits, nothing outside it takes touches.
private struct FitOrScroll: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scrollView = subviews.first else { return .zero }
        let content = scrollView.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: content.width, height: min(content.height, proposal.height ?? content.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct OnAccentLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(PortlightTheme.onAccent)
        } else {
            content
        }
    }
}

/// Chrome background: a material, or a solid system colour with Reduce Transparency. The default is `.bar`, the
/// material system toolbars use: over the black letterbox `.ultraThinMaterial` turns mid-gray in light mode and
/// the secondary status text becomes unreadable.
struct ChromeFill<S: Shape>: View {
    private let shape: S
    private let material: Material
    private var a11y = PortlightAccessibility()

    init(_ shape: S, material: Material = .bar) {
        self.shape = shape
        self.material = material
    }

    var body: some View {
        if a11y.reduceTransparency {
            shape.fill(PortlightTheme.solidChrome)
        } else {
            shape.fill(material)
        }
    }
}

extension ChromeFill where S == Rectangle {
    init(material: Material = .bar) {
        self.init(Rectangle(), material: material)
    }
}

extension View {
    /// A rounded opaque card (`PortlightTheme.cardFill`) with a soft shadow, outlined with Increase Contrast or
    /// Reduce Transparency.
    func cardSurface(cornerRadius: CGFloat = 20, shadowRadius: CGFloat = 18) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, shadowRadius: shadowRadius))
    }
}

private struct CardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    var a11y = PortlightAccessibility()

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                // The shadow lifts the card off a backdrop of a similar colour.
                shape.fill(PortlightTheme.cardFill)
                    .shadow(color: .black.opacity(0.16), radius: shadowRadius, y: shadowRadius / 3)
            }
            .overlay {
                if a11y.increaseContrast || a11y.reduceTransparency {
                    shape.strokeBorder(Color(uiColor: .separator), lineWidth: a11y.idleOutline)
                }
            }
    }
}

/// "Portlight · by Studio Upgrade" (branding README): Connections only, never over the remote picture.
struct PublisherFooter: View {
    var body: some View {
        Text("Portlight · by Studio Upgrade")
            .font(.footnote)
            .foregroundStyle(PortlightTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Portlight, by Studio Upgrade")
    }
}

// MARK: - Copy and symbols (app-side names, so they can't collide with PortlightKit additions)

extension InputMode {
    var chromeTitle: String {
        switch self {
        case .trackpad: "Trackpad"
        case .direct: "Direct"
        case .pan: "Pan"
        }
    }

    var chromeSymbol: String {
        switch self {
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .direct: "hand.tap"
        case .pan: "hand.draw"
        }
    }

    /// One tap on the Input button cycles Trackpad → Direct → Pan.
    var nextChromeMode: InputMode {
        switch self {
        case .trackpad: .direct
        case .direct: .pan
        case .pan: .trackpad
        }
    }
}

extension ModifierKey {
    var spokenName: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .shift: "Shift"
        case .control: "Control"
        }
    }
}

extension ModifierLatch {
    var voiceOverValue: String {
        switch self {
        case .off: "Off"
        case .latched: "Next action"
        case .locked: "Locked"
        }
    }
}

extension ConnectionFailure {
    /// Whether "Try Again" can help without editing the connection or answering a prompt first.
    var offersTryAgain: Bool {
        switch self {
        case .hostNotFound, .refused, .noRoute, .timedOut, .localNetworkDenied, .offline, .networkLost, .tlsFailed,
             .busy, .hostClosed, .hostTimeout:
            true
        case .invalidAddress, .trustDeclined, .certificateChanged, .authenticationRejected, .protocolViolation, .canceled:
            false
        }
    }

    var cardSymbol: String {
        switch self {
        case .hostNotFound, .noRoute, .timedOut, .localNetworkDenied, .offline, .networkLost: "wifi.exclamationmark"
        case .tlsFailed: "lock.slash.fill"
        case .trustDeclined: "lock.shield"
        case .certificateChanged: "exclamationmark.shield.fill"
        case .authenticationRejected: "lock.fill"
        case .protocolViolation: "exclamationmark.octagon.fill"
        case .canceled: "xmark.circle"
        case .invalidAddress, .refused, .busy, .hostClosed, .hostTimeout: "exclamationmark.triangle.fill"
        }
    }
}

extension SessionNotice {
    var bannerSymbol: String {
        switch self {
        case .resolutionLimited: "arrow.down.right.and.arrow.up.left"
        case .captureFailed: "exclamationmark.triangle.fill"
        case .displaysChanged: "display.2"
        case .settingsRejected: "exclamationmark.circle.fill"
        case .audioUnavailable, .audioInterrupted: "speaker.slash.fill"
        }
    }
}
