import SwiftUI

/// Control On / View Only (UI-SPEC §5): a labeled toggle with its own icon and word for each state. Control On
/// is filled and carries the selected trait; View Only is outlined. Colour only supplements icon and word.
struct ControlModeButton: View {
    let isOn: Bool
    let compact: Bool
    private let action: @MainActor () -> Void

    /// - Parameter compact: the landscape rail's layout (icon over the word).
    init(isOn: Bool, compact: Bool = false, action: @escaping @MainActor () -> Void) {
        self.isOn = isOn
        self.compact = compact
        self.action = action
    }

    static func title(isOn: Bool) -> String { isOn ? "Control On" : "View Only" }
    private var title: String { Self.title(isOn: isOn) }
    /// `cursorarrow.click.2` (a pointer that is clicking): the owner's review found `cursorarrow.rays` read as a
    /// loading spinner.
    static func symbol(isOn: Bool) -> String { isOn ? "cursorarrow.click.2" : "eye" }
    private var symbol: String { Self.symbol(isOn: isOn) }

    var body: some View {
        Button {
            action()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(isOn ? "Switches to View Only. Your touches stop reaching the Mac."
                                : "Switches to Control On. Your touches control the Mac.")
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
        .accessibilityIdentifier("chrome.control")
    }

    @ViewBuilder
    private var label: some View {
        if compact {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 56)
            .modifier(ControlStateBackground(isOn: isOn, shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            // The state word never truncates; the computer name beside it gives way instead.
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .modifier(ControlStateBackground(isOn: isOn, shape: Capsule()))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}

/// Filled accent for Control On, an outline for View Only; Increase Contrast thickens both.
private struct ControlStateBackground<S: InsettableShape>: ViewModifier {
    let isOn: Bool
    let shape: S
    var a11y = PortlightAccessibility()

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isOn ? PortlightTheme.onAccent : Color.primary)
            .background {
                if isOn { shape.fill(Color.accentColor) }
            }
            .overlay {
                if isOn {
                    if a11y.increaseContrast {
                        shape.strokeBorder(Color.primary, lineWidth: a11y.selectedOutline)
                    }
                } else {
                    shape.strokeBorder(Color.primary.opacity(a11y.increaseContrast ? 0.9 : 0.55),
                                       lineWidth: a11y.increaseContrast ? 2 : 1.5)
                }
            }
    }
}
