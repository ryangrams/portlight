import SwiftUI

/// An empty state laid out like `ContentUnavailableView`: a symbol, a title, one sentence and an action. Its text
/// wraps at every size and it scrolls when it doesn't fit; `ContentUnavailableView` clipped its text at
/// accessibility sizes and drew the sentence at 3.4:1.
struct EmptyStateView<Actions: View>: View {
    private let title: String
    private let systemImage: String
    private let message: String
    private let actions: Actions

    init(_ title: String, systemImage: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PortlightTheme.secondaryText)
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(PortlightTheme.secondaryText)
                .padding(.top, 4)
            actions
                .padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .scrollsWhenTaller()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
