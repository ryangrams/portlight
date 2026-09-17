import SwiftUI
import PortlightKit

/// Chooses which host displays this iPhone shows (UI-SPEC §6). Toggling applies immediately (the owner
/// resubscribes without reconnecting). The map shows the host's real arrangement; the list is always present,
/// because a map tile is a control only when every tile is at least 44 × 44 pt.
struct DisplaysSheet: View {
    let displays: [HostDisplay]
    let selection: Set<DisplayID>
    private let streamSizes: [DisplayID: PixelSize]
    private let onToggle: @MainActor (DisplayID) -> Void
    private let onSelectAll: @MainActor () -> Void
    private let onSelectNone: @MainActor () -> Void
    private let onDone: (@MainActor () -> Void)?

    @State private var detent: PresentationDetent
    @Environment(\.dismiss) private var dismiss

    /// - Parameter streamSizes: acknowledged canvas sizes of the selected displays.
    init(displays: [HostDisplay], selection: Set<DisplayID>, streamSizes: [DisplayID: PixelSize] = [:],
         startsExpanded: Bool = false,
         onToggle: @escaping @MainActor (DisplayID) -> Void,
         onSelectAll: @escaping @MainActor () -> Void,
         onSelectNone: @escaping @MainActor () -> Void,
         onDone: (@MainActor () -> Void)? = nil) {
        self.displays = displays
        self.selection = selection
        self.streamSizes = streamSizes
        self.onToggle = onToggle
        self.onSelectAll = onSelectAll
        self.onSelectNone = onSelectNone
        self.onDone = onDone
        _detent = State(initialValue: startsExpanded ? .large : .medium)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DisplayArrangementMap(displays: displays, selection: selection, onToggle: onToggle)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    HStack(spacing: 12) {
                        Button {
                            onSelectAll()
                        } label: {
                            Text("All").frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .secondaryActionStyle()
                        .disabled(displays.allSatisfy { selection.contains($0.id) })
                        .accessibilityIdentifier("displays.all")
                        Button {
                            onSelectNone()
                        } label: {
                            Text("None").frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .secondaryActionStyle()
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("displays.none")
                    }
                } footer: {
                    Text("This changes only what this iPhone shows. Your Mac’s display arrangement stays the same.")
                        .foregroundStyle(PortlightTheme.secondaryText)
                }

                Section {
                    ForEach(displays) { display in
                        DisplayRow(display: display, isSelected: selection.contains(display.id),
                                   streamSize: streamSizes[display.id]) {
                            onToggle(display.id)
                        }
                    }
                } header: {
                    Text("\(selection.count) of \(displays.count) shown")
                        .foregroundStyle(PortlightTheme.secondaryText)
                }
            }
            .navigationTitle("Displays")
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
}

/// Every host display in its real logical arrangement (`DesktopLayout.arrange(compact: false)`), scaled to
/// fit. Active displays are filled with the accent; inactive ones are dimmed with a dashed outline. When any
/// tile would be smaller than 44 × 44 pt the map is decorative and hidden from VoiceOver (the list remains).
struct DisplayArrangementMap: View {
    let displays: [HostDisplay]
    let selection: Set<DisplayID>
    let onToggle: @MainActor (DisplayID) -> Void

    static let minimumTarget: CGFloat = 44

    var body: some View {
        let frames = DesktopLayout.arrange(displays, selected: displays.map(\.id), compact: false)
        let bounds = MapPlacement.union(frames.values)
        let aspect = bounds.map { $0.width / max($0.height, 1) } ?? 16.0 / 9.0
        GeometryReader { proxy in
            let placement = MapPlacement(frames: frames, bounds: bounds, size: proxy.size)
            let interactive = placement.smallestSide >= Self.minimumTarget
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    if let rect = placement.rects[display.id] {
                        MapTile(display: display, isSelected: selection.contains(display.id), interactive: interactive) {
                            onToggle(display.id)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .accessibilityElement(children: interactive ? .contain : .ignore)
            .accessibilityHidden(!interactive)
        }
        .aspectRatio(CGFloat(aspect), contentMode: .fit)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 200)
    }
}

/// Map geometry: host logical points scaled into the available size, centred, with a small gap between tiles.
struct MapPlacement {
    private(set) var rects: [DisplayID: CGRect] = [:]
    /// The shortest side of any tile, in points (0 when nothing is placed).
    private(set) var smallestSide: CGFloat = 0

    init(frames: [DisplayID: LogicalRect], bounds: LogicalRect?, size: CGSize, inset: CGFloat = 6, gap: CGFloat = 4) {
        guard let bounds, bounds.width > 0, bounds.height > 0,
              size.width > 2 * inset, size.height > 2 * inset else { return }
        let width = CGFloat(bounds.width), height = CGFloat(bounds.height)
        let scale = min((size.width - 2 * inset) / width, (size.height - 2 * inset) / height)
        let originX = (size.width - width * scale) / 2
        let originY = (size.height - height * scale) / 2
        var smallest = CGFloat.greatestFiniteMagnitude
        for (id, frame) in frames {
            let rect = CGRect(x: originX + CGFloat(frame.x - bounds.x) * scale,
                              y: originY + CGFloat(frame.y - bounds.y) * scale,
                              width: CGFloat(frame.width) * scale,
                              height: CGFloat(frame.height) * scale).insetBy(dx: gap / 2, dy: gap / 2)
            rects[id] = rect
            smallest = min(smallest, rect.width, rect.height)
        }
        smallestSide = rects.isEmpty ? 0 : smallest
    }

    static func union(_ rects: some Sequence<LogicalRect>) -> LogicalRect? {
        rects.reduce(nil) { partial, rect in partial?.union(rect) ?? rect }
    }
}

private struct MapTile: View {
    let display: HostDisplay
    let isSelected: Bool
    let interactive: Bool
    let toggle: @MainActor () -> Void
    var a11y = PortlightAccessibility()

    var body: some View {
        if interactive {
            Button {
                toggle()
            } label: {
                tile
            }
            .buttonStyle(.plain)
            .accessibilityLabel(display.label)
            .accessibilityValue(isSelected ? "Shown" : "Hidden")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("displays.tile.\(display.number)")
        } else {
            tile
        }
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let ink = isSelected ? PortlightTheme.onAccent : PortlightTheme.secondaryText
        return ZStack(alignment: .top) {
            // A hidden display is dimmed; its number stays at full strength so it remains readable.
            shape.fill(isSelected ? Color.accentColor : PortlightTheme.idleFill)
                .opacity(isSelected ? 1 : 0.75)
            if display.isPrimary {
                // The main display's menu bar, as in the Mac's arrangement settings.
                Capsule()
                    .fill(ink.opacity(0.5))
                    .frame(height: 3)
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
            }
            Text(verbatim: String(display.number))
                .font(.headline.monospacedDigit())
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            shape.strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.6),
                               style: StrokeStyle(lineWidth: isSelected ? a11y.selectedOutline : (a11y.increaseContrast ? 2 : 1),
                                                  dash: isSelected ? [] : [4, 3]))
        }
        .contentShape(shape)
    }
}

/// "N · Name", logical size and stream size, and a Main badge, with a leading checkmark toggle.
private struct DisplayRow: View {
    let display: HostDisplay
    let isSelected: Bool
    let streamSize: PixelSize?
    let toggle: @MainActor () -> Void

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : PortlightTheme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(display.label)
                            .foregroundStyle(.primary)
                        if display.isPrimary {
                            Text("Main")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PortlightTheme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
                        }
                    }
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(PortlightTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.label + (display.isPrimary ? ", main display" : ""))
        .accessibilityValue(isSelected ? "Shown" : "Hidden")
        .accessibilityHint(detail)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("displays.row.\(display.number)")
    }

    private var detail: String {
        let logical = "\(Int(display.logicalFrame.width.rounded())) × \(Int(display.logicalFrame.height.rounded())) pt"
        guard isSelected else { return "\(logical) · not shown" }
        guard let streamSize else { return logical }
        return "\(logical) · stream \(streamSize.width) × \(streamSize.height)"
    }
}
