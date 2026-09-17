import SwiftUI
import PortlightKit

/// Asks the user to trust an unknown or changed certificate (UI-SPEC §4). No password has been sent yet.
///
/// Both buttons hand back the prompt they were shown for, so the owner can ignore a stale answer (a newer
/// attempt started while the sheet was up). Swipe-to-dismiss is disabled while the decision is pending.
struct TrustSheet: View {
    let prompt: TrustPrompt
    private let onTrust: @MainActor (TrustPrompt) -> Void
    private let onCancel: @MainActor (TrustPrompt) -> Void

    init(prompt: TrustPrompt,
         onTrust: @escaping @MainActor (TrustPrompt) -> Void,
         onCancel: @escaping @MainActor (TrustPrompt) -> Void) {
        self.prompt = prompt
        self.onTrust = onTrust
        self.onCancel = onCancel
    }

    private var isChange: Bool { prompt.isChange }
    private var tint: Color { isChange ? PortlightTheme.error : .accentColor }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: isChange ? "exclamationmark.shield.fill" : "lock.shield")
                    .font(.system(size: 56, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .padding(.top, 8)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(isChange ? "Computer Identity Changed" : "Trust This Computer?")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if isChange {
                        Text("The certificate for this computer no longer matches the one you trusted. Continue only if you expected this, for example after reinstalling Portlight Host.")
                            .font(.callout)
                            .foregroundStyle(PortlightTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text(prompt.endpoint.description)
                            .font(.body.weight(.semibold))
                    } icon: {
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Computer, \(prompt.endpoint.description)")

                    Divider()

                    FingerprintBlock(title: "SHA-256 certificate fingerprint", fingerprint: prompt.fingerprint)
                        .accessibilityIdentifier("trust.fingerprint")

                    if let previous = prompt.previousFingerprint {
                        DisclosureGroup("Previously trusted fingerprint") {
                            FingerprintBlock(title: nil, fingerprint: previous)
                                .foregroundStyle(PortlightTheme.secondaryText)
                                .padding(.top, 6)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PortlightTheme.optionFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if isChange {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tint.opacity(0.6), lineWidth: 1.5)
                    }
                }

                Text("Compare with Connection Details in Portlight Host on the Mac. Your password has not been sent.")
                    .font(.footnote)
                    .foregroundStyle(PortlightTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(role: isChange ? ButtonRole.destructive : nil) {
                    onTrust(prompt)
                } label: {
                    Text("Trust and Connect")
                        .font(.headline)
                        .onAccentLabel()
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .accessibilityIdentifier("trust.approve")

                Button {
                    onCancel(prompt)
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .secondaryActionStyle()
                .accessibilityIdentifier("trust.cancel")
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            // Opaque, like the cards: the accessibility audit can't judge Cancel's contrast over the `.bar` material.
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) { Divider() }
        }
        .interactiveDismissDisabled(true)
    }
}

/// Four lines of eight hex pairs, monospaced and selectable.
private struct FingerprintBlock: View {
    let title: String?
    let fingerprint: CertificateFingerprint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(fingerprint.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "Fingerprint")
        .accessibilityValue(fingerprint.lines.joined(separator: ", "))
    }
}
