import SwiftUI

/// Over the dimmed retained picture while paused (UI-SPEC §5). The renderer does the dimming; only the Resume
/// button takes touches here, so local zoom and pan keep working around and under the card.
struct PausedOverlay: View {
    private let onResume: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(onResume: @escaping @MainActor () -> Void) {
        self.onResume = onResume
    }

    /// At accessibility sizes the large symbol goes and the card takes the full width, so the text and Resume fit
    /// between the bars without scrolling (a scroll view would stop pinch and pan under the card).
    private var compact: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                if !compact {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 72, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                }
                Text("Paused")
                    .font(.title2.bold())
                Text("Nothing is sent to the Mac while paused. Pinch and pan still work.")
                    .font(.subheadline)
                    .foregroundStyle(PortlightTheme.secondaryTextOnMaterial)
            }
            .multilineTextAlignment(.center)
            // At large text sizes the sentence wraps instead of being squeezed.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .allowsHitTesting(false)

            Button {
                onResume()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .font(.headline)
                    .onAccentLabel()
                    .frame(minWidth: 150, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("paused.resume")
        }
        .padding(28)
        .frame(maxWidth: compact ? .infinity : 360)
        .background {
            ChromeFill(RoundedRectangle(cornerRadius: 24, style: .continuous), material: .ultraThinMaterial)
                .allowsHitTesting(false)
        }
        .padding(24)
        // It always sits on the dimmed picture, so it uses dark styling in either appearance.
        .environment(\.colorScheme, .dark)
    }
}

/// The picture area with nothing selected (UI-SPEC §5): a valid state, not an error. No input is sent.
struct EmptySelectionView: View {
    private let onChooseDisplays: @MainActor () -> Void

    init(onChooseDisplays: @escaping @MainActor () -> Void) {
        self.onChooseDisplays = onChooseDisplays
    }

    var body: some View {
        EmptyStateView("No Displays Selected", systemImage: "display.2",
                       message: "Choose at least one display to see it. Nothing is sent to the Mac until you do.") {
            Button {
                onChooseDisplays()
            } label: {
                Text("Choose Displays").onAccentLabel()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("empty.chooseDisplays")
        }
        // It sits on the dark letterbox.
        .environment(\.colorScheme, .dark)
    }
}
