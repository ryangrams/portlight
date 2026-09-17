import SwiftUI
import UIKit
import PortlightKit

/// A transient session notice under the top bar (UI-SPEC §5). It dismisses itself after `autoDismissAfter`
/// and on a tap, so it never covers the picture for long.
struct SessionNoticeBanner: View {
    let notice: SessionNotice
    private let actionTitle: String?
    private let onAction: (@MainActor () -> Void)?
    private let autoDismissAfter: Duration?
    private let onDismiss: @MainActor () -> Void

    init(notice: SessionNotice, actionTitle: String? = nil, onAction: (@MainActor () -> Void)? = nil,
         autoDismissAfter: Duration? = .seconds(6), onDismiss: @escaping @MainActor () -> Void) {
        self.notice = notice
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.autoDismissAfter = autoDismissAfter
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: notice.bannerSymbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(PortlightTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notice.text")
            if let actionTitle, let onAction {
                Button(actionTitle) { onAction() }
                    .secondaryActionStyle()
                    .controlSize(.small)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(PortlightTheme.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.vertical, 4)
        // A tight shadow, so it stays off the top bar just above.
        .cardSurface(cornerRadius: 16, shadowRadius: 6)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onDismiss() }
        .task(id: notice) {
            guard let autoDismissAfter else { return }
            try? await Task.sleep(for: autoDismissAfter)
            if !Task.isCancelled { onDismiss() }
        }
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: "\(notice.title). \(notice.message)")
        }
    }
}
