import SwiftUI
import PortlightKit

/// The progress card shown while a connection attempt runs (UI-SPEC §4), layered over the frozen frame or a
/// neutral backdrop. Everything it says is derived from the phase, so it can't disagree with the session.
struct ConnectionStatusCard: View {
    let phase: ConnectionPhase
    let endpoint: HostEndpoint?
    private let onCancel: @MainActor () -> Void

    init(phase: ConnectionPhase, endpoint: HostEndpoint?, onCancel: @escaping @MainActor () -> Void) {
        self.phase = phase
        self.endpoint = endpoint
        self.onCancel = onCancel
    }

    static let patienceNotice = "Not answering yet — check that the Mac is awake and on the same network."

    private var target: String { endpoint?.description ?? "the computer" }

    private var detail: String {
        switch phase {
        case .reconnecting(let attempt, let failure):
            // The computer's name is already in the top bar; keep this to one short line.
            return attempt > 0 ? "Attempt \(attempt) · \(failure.title)" : "Resuming \(target)"
        case .checkingIdentity:
            return "Checking the certificate of \(target)"
        case .awaitingTrust:
            return "Waiting for you to trust \(target)"
        case .authenticating, .loadingDisplays:
            return "Connected to \(target)"
        case .connecting, .idle, .connected, .failed:
            return "Connecting to \(target)"
        }
    }

    private var isPatient: Bool {
        if case .connecting(patient: true) = phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text(phase.title)
                    .font(.headline)
                    .accessibilityIdentifier("status.title")
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(PortlightTheme.secondaryText)
                if isPatient {
                    Label(Self.patienceNotice, systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(PortlightTheme.secondaryText)
                        .padding(.top, 4)
                        .accessibilityIdentifier("status.patience")
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .announcesChanges(of: phase.title + ". " + detail + (isPatient ? ". " + Self.patienceNotice : ""))

            Button(role: .cancel) {
                onCancel()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 120, minHeight: 28)
            }
            .secondaryActionStyle()
            .controlSize(.large)
            .accessibilityIdentifier("status.cancel")
        }
        .padding(24)
        .frame(maxWidth: 420)
        .cardSurface()
        .padding(20)
        .scrollsWhenTaller()
    }
}
