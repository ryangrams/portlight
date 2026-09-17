import SwiftUI
import PortlightKit

/// One saved connection: its name (or "Saved Connection"), then the computer address in secondary style. Both
/// wrap at large text sizes; a one-line address was cut short there ("192.168.1.42:59…").
struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(wrappableSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(PortlightTheme.secondaryText)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.displayTitle)
        .accessibilityValue(profile.subtitle)
    }

    /// A zero-width space after the last colon lets a long address wrap before the port ("192.168.1.42:" / "5921")
    /// instead of inside it ("…:592" / "1"). VoiceOver reads the plain subtitle.
    private var wrappableSubtitle: String {
        var text = profile.subtitle
        guard let colon = text.lastIndex(of: ":") else { return text }
        text.insert("\u{200B}", at: text.index(after: colon))
        return text
    }
}
