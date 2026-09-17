import SwiftUI
import UIKit
import PortlightKit

/// Why an attempt or session ended, and what to do next (UI-SPEC §4). Try Again appears only when retrying
/// without changes can help; Local Network denial adds Open Settings.
struct ConnectionFailureCard: View {
    let failure: ConnectionFailure
    let endpoint: HostEndpoint?
    private let dismissTitle: String
    private let onTryAgain: (@MainActor () -> Void)?
    private let onDismiss: @MainActor () -> Void
    private let onOpenSettings: (@MainActor () -> Void)?

    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - dismissTitle: "Edit Connection" from a saved connection, or "Close".
    ///   - onTryAgain: nil hides Try Again; it is also hidden when the failure can't be fixed by retrying.
    ///   - onOpenSettings: defaults to opening this app's page in Settings.
    init(failure: ConnectionFailure, endpoint: HostEndpoint?, dismissTitle: String = "Edit Connection",
         onTryAgain: (@MainActor () -> Void)?, onDismiss: @escaping @MainActor () -> Void,
         onOpenSettings: (@MainActor () -> Void)? = nil) {
        self.failure = failure
        self.endpoint = endpoint
        self.dismissTitle = dismissTitle
        self.onTryAgain = onTryAgain
        self.onDismiss = onDismiss
        self.onOpenSettings = onOpenSettings
    }

    private var showsTryAgain: Bool { onTryAgain != nil && failure.offersTryAgain }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: failure.cardSymbol)
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(PortlightTheme.error)
                    .accessibilityHidden(true)
                Text(failure.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("failure.title")
                Text(failure.message(for: endpoint))
                    .font(.subheadline)
                    .foregroundStyle(PortlightTheme.secondaryText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            VStack(spacing: 10) {
                if failure == .localNetworkDenied {
                    Button {
                        openSettings()
                    } label: {
                        Text("Open Settings").onAccentLabel().frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if showsTryAgain, let onTryAgain {
                    Button {
                        onTryAgain()
                    } label: {
                        Text("Try Again").onAccentLabel().frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("failure.tryAgain")
                }
                Button {
                    onDismiss()
                } label: {
                    Text(dismissTitle).frame(maxWidth: .infinity, minHeight: 28)
                }
                .secondaryActionStyle()
                .accessibilityIdentifier("failure.dismiss")
            }
            .controlSize(.large)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .cardSurface()
        .padding(20)
        .scrollsWhenTaller()
    }

    private func openSettings() {
        if let onOpenSettings {
            onOpenSettings()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
