import SwiftUI

/// The app-switcher snapshot cover (UI-SPEC §12): the app icon on a neutral background, never remote pixels.
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image("PrivacyIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                Text("Portlight")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Portlight")
        .accessibilityIdentifier("privacy.cover")
    }
}
