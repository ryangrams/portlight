import SwiftUI
import PortlightKit

/// One gesture and what it does.
struct GestureGuideRow: Identifiable, Hashable, Sendable {
    let symbol: String
    let gesture: String
    let effect: String
    var id: String { gesture }
}

/// The gesture guide (UI-SPEC §9): shown once on the first session and later from More. Rows follow the
/// execution plan's gesture table for each input mode.
struct GestureGuideView: View {
    @State private var mode: InputMode
    @State private var detent: PresentationDetent
    private let onDone: (@MainActor () -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(mode: InputMode = .trackpad, startsExpanded: Bool = false, onDone: (@MainActor () -> Void)? = nil) {
        _mode = State(initialValue: mode)
        _detent = State(initialValue: startsExpanded ? .large : .medium)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Input Mode", selection: $mode) {
                        ForEach(InputMode.allCases, id: \.self) { choice in
                            Text(choice.chromeTitle).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("gestures.mode")
                } footer: {
                    Text(Self.summary(for: mode))
                        .foregroundStyle(PortlightTheme.secondaryText)
                }

                Section {
                    ForEach(Self.rows(for: mode)) { row in
                        GestureRowView(row: row)
                    }
                } header: {
                    Text("Gestures").foregroundStyle(PortlightTheme.secondaryText)
                }

                Section {
                    ForEach(Self.extras) { row in
                        GestureRowView(row: row)
                    }
                } header: {
                    Text("Also Available").foregroundStyle(PortlightTheme.secondaryText)
                }
            }
            .navigationTitle("Gesture Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let onDone { onDone() } else { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    static func summary(for mode: InputMode) -> String {
        switch mode {
        case .trackpad: "Your finger moves a pointer, like a laptop trackpad. Good for small controls."
        case .direct: "The Mac responds where you touch."
        case .pan: "Look around without sending anything to the Mac."
        }
    }

    static func rows(for mode: InputMode) -> [GestureGuideRow] {
        switch mode {
        case .trackpad:
            [
                GestureGuideRow(symbol: "hand.point.up.left", gesture: "Move one finger", effect: "Moves the pointer."),
                GestureGuideRow(symbol: "hand.tap", gesture: "Tap", effect: "Clicks at the pointer."),
                GestureGuideRow(symbol: "hand.tap.fill", gesture: "Double-tap", effect: "Double-clicks at the pointer."),
                GestureGuideRow(symbol: "list.bullet.rectangle", gesture: "Two-finger tap", effect: "Right-clicks."),
                GestureGuideRow(symbol: "arrow.up.and.down", gesture: "Drag two fingers", effect: "Scrolls."),
                GestureGuideRow(symbol: "hand.draw", gesture: "Tap, then hold and move", effect: "Drags, for example to move a window."),
                GestureGuideRow(symbol: "plus.magnifyingglass", gesture: "Pinch", effect: "Zooms this iPhone’s view. Nothing is sent to the Mac."),
            ]
        case .direct:
            [
                GestureGuideRow(symbol: "hand.tap", gesture: "Tap", effect: "Clicks where you tap."),
                GestureGuideRow(symbol: "hand.tap.fill", gesture: "Double-tap", effect: "Double-clicks where you tap."),
                GestureGuideRow(symbol: "list.bullet.rectangle", gesture: "Two-finger tap", effect: "Right-clicks where you tap."),
                GestureGuideRow(symbol: "arrow.up.and.down", gesture: "Drag two fingers", effect: "Scrolls."),
                GestureGuideRow(symbol: "hand.draw", gesture: "Touch and hold, then move", effect: "Drags on the Mac."),
                GestureGuideRow(symbol: "hand.point.up.left", gesture: "Drag one finger", effect: "Pans this iPhone’s view."),
                GestureGuideRow(symbol: "plus.magnifyingglass", gesture: "Pinch", effect: "Zooms this iPhone’s view. Nothing is sent to the Mac."),
            ]
        case .pan:
            [
                GestureGuideRow(symbol: "hand.draw", gesture: "Drag one finger", effect: "Pans this iPhone’s view."),
                GestureGuideRow(symbol: "plus.magnifyingglass", gesture: "Pinch", effect: "Zooms this iPhone’s view."),
                GestureGuideRow(symbol: "hand.raised", gesture: "Tap", effect: "Does nothing on the Mac. Switch to Trackpad or Direct to control it."),
            ]
        }
    }

    static let extras: [GestureGuideRow] = [
        GestureGuideRow(symbol: "computermouse", gesture: "Mouse buttons in the keyboard bar",
                        effect: "Middle click, and Hold Left or Hold Right for long drags and right drags."),
        GestureGuideRow(symbol: "command", gesture: "⌘ ⌥ ⇧ ⌃ in the keyboard bar",
                        effect: "Tap for the next click or key; tap twice quickly to lock."),
        GestureGuideRow(symbol: "eye", gesture: "View Only",
                        effect: "Look without touching the Mac. Pinch and pan still work."),
    ]
}

private struct GestureRowView: View {
    let row: GestureGuideRow

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.gesture)
                    .font(.body.weight(.semibold))
                Text(row.effect)
                    .font(.subheadline)
                    .foregroundStyle(PortlightTheme.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
