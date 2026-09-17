import SwiftUI
import PortlightKit

/// Requested versus effective stream resolution, for the Quality sheet's status line.
struct QualityStatus: Equatable, Sendable {
    var requested: ResolutionPreset
    /// From the accepted `subscribed`; nil before the first one.
    var effective: EffectiveResolution?
    /// Why the effective resolution differs or the request is capped, e.g. "limited by Display 2".
    var limitation: String?

    init(requested: ResolutionPreset, effective: EffectiveResolution? = nil, limitation: String? = nil) {
        self.requested = requested
        self.effective = effective
        self.limitation = limitation
    }

    var text: String {
        let reason = limitation.map { " · \($0)" } ?? ""
        switch effective {
        case nil:
            return "\(requested.title) selected\(reason)"
        case .native?:
            return "Streaming at native size\(reason)"
        case .preset(let preset)?:
            if preset == requested { return "Streaming \(preset.title)\(reason)" }
            return "Streaming \(preset.title)" + (reason.isEmpty ? " · \(requested.title) not available" : reason)
        }
    }
}

/// Stream quality (UI-SPEC §7): four resolution ceilings, three colour choices, content priority, optional
/// smoothing, and data rates. Edits `settings`; the owner resubscribes. There is deliberately no FPS control.
struct QualitySheet: View {
    @Binding var settings: SessionSettings
    let availability: [PresetAvailability]
    let status: QualityStatus
    let audioUnavailableReason: String?
    private let onDone: (@MainActor () -> Void)?

    @State private var detent: PresentationDetent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let smoothingRequirement = "Available for Video with 256 Colors or 16 Shades of Gray."
    /// Common manual video limits, in kbps (0.1 to 100 Mbps).
    static let manualSteps = [100, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 25_000, 50_000, 100_000]
    static let defaultManualKbps = 8_000

    init(settings: Binding<SessionSettings>, availability: [PresetAvailability], status: QualityStatus,
         audioUnavailableReason: String? = nil, startsExpanded: Bool = false, onDone: (@MainActor () -> Void)? = nil) {
        _settings = settings
        self.availability = availability
        self.status = status
        self.audioUnavailableReason = audioUnavailableReason
        self.onDone = onDone
        _detent = State(initialValue: startsExpanded ? .large : .medium)
    }

    private var smoothingAvailable: Bool { settings.quality == .video && settings.color != .full }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(status.text, systemImage: "gauge.with.dots.needle.50percent")
                        .font(.subheadline)
                        .accessibilityIdentifier("quality.status")
                }

                Section {
                    resolutionGrid
                } header: {
                    Text("Resolution").foregroundStyle(PortlightTheme.secondaryText)
                } footer: {
                    resolutionFootnote
                }

                Section {
                    colorOptions
                } header: {
                    Text("Color").foregroundStyle(PortlightTheme.secondaryText)
                }

                Section {
                    Picker("Content", selection: $settings.quality) {
                        ForEach(ContentPriority.allCases, id: \.self) { priority in
                            Text(priority.title).tag(priority)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("quality.content")
                    Toggle("Smooth Gradients", isOn: Binding(get: { smoothingAvailable && settings.smoothGradients },
                                                             set: { settings.smoothGradients = $0 }))
                        .disabled(!smoothingAvailable)
                        .accessibilityHint(smoothingAvailable ? "" : Self.smoothingRequirement)
                        .accessibilityIdentifier("quality.smoothGradients")
                } header: {
                    Text("Content").foregroundStyle(PortlightTheme.secondaryText)
                } footer: {
                    Text(smoothingAvailable ? "Reduces banding in video with fewer colors. Uses more data."
                                            : "Reduces banding in video with fewer colors. Uses more data. " + Self.smoothingRequirement)
                        .foregroundStyle(PortlightTheme.secondaryText)
                }

                Section {
                    videoRate
                    Picker("Audio Quality", selection: $settings.audioQuality) {
                        ForEach(AudioQuality.allCases, id: \.self) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(audioUnavailableReason != nil)
                    .accessibilityHint(audioUnavailableReason ?? "")
                    .accessibilityIdentifier("quality.audio")
                } header: {
                    Text("Data Rate").foregroundStyle(PortlightTheme.secondaryText)
                } footer: {
                    Text(audioUnavailableReason ?? "Choosing an audio quality doesn’t turn audio on.")
                        .foregroundStyle(PortlightTheme.secondaryText)
                }
            }
            .navigationTitle("Quality")
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

    // MARK: Resolution

    private var resolutionGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(ResolutionPreset.allCases, id: \.self) { preset in
                resolutionButton(preset)
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .listRowBackground(Color.clear)
    }

    private func resolutionButton(_ preset: ResolutionPreset) -> some View {
        let state = availability(of: preset)
        let selected = settings.resolution == preset
        return Button {
            settings.resolution = preset
        } label: {
            OptionCard(title: preset.title, detail: preset.detail, isSelected: selected, isAvailable: state.isAvailable) {
                ResolutionGridGlyph(side: preset.gridSide)
            }
        }
        .buttonStyle(.plain)
        .disabled(!state.isAvailable)
        .accessibilityLabel("\(preset.title), \(preset.detail)")
        .accessibilityValue(state.isAvailable ? "" : "Unavailable")
        .accessibilityHint(state.isAvailable ? "" : (state.reason ?? "Not available for the selected displays."))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("quality.resolution.\(preset.rawValue)")
    }

    @ViewBuilder
    private var resolutionFootnote: some View {
        let unavailable = ResolutionPreset.allCases.map { availability(of: $0) }.filter { !$0.isAvailable }
        if !unavailable.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(unavailable) { item in
                    Text(Self.footnote(for: item))
                }
            }
            .foregroundStyle(PortlightTheme.secondaryText)
        }
    }

    /// "QHD: <reason>", except when the reason already starts with the preset's name ("UHD for 3 displays needs
    /// more memory…"), which would otherwise read "UHD: UHD for 3 displays…".
    static func footnote(for item: PresetAvailability) -> String {
        let title = item.preset.title
        let reason = item.reason ?? "Not available for the selected displays."
        if reason.hasPrefix(title + " ") || reason.hasPrefix(title + ":") { return reason }
        return "\(title): \(reason)"
    }

    private func availability(of preset: ResolutionPreset) -> PresetAvailability {
        availability.first { $0.preset == preset } ?? PresetAvailability(preset: preset, isAvailable: true)
    }

    // MARK: Color

    private var colorOptions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12))
                                                         : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            ForEach(ColorMode.allCases, id: \.self) { mode in
                let selected = settings.color == mode
                Button {
                    settings.color = mode
                } label: {
                    OptionCard(title: mode.title, detail: nil, isSelected: selected, isAvailable: true) {
                        ColorModeSwatch(mode: mode)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("quality.color.\(mode.rawValue)")
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .listRowBackground(Color.clear)
    }

    // MARK: Data rate

    private enum VideoRate: Hashable { case automatic, limited }

    @ViewBuilder
    private var videoRate: some View {
        LabeledContent("Video") {
            Picker("Video", selection: Binding(get: { settings.bandwidthKbps == 0 ? VideoRate.automatic : .limited },
                                               set: { settings.bandwidthKbps = $0 == .automatic ? 0 : Self.defaultManualKbps })) {
                Text("Automatic").tag(VideoRate.automatic)
                Text("Limit").tag(VideoRate.limited)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("quality.videoRate")
        }
        if settings.bandwidthKbps > 0 {
            Stepper(onIncrement: { step(by: 1) }, onDecrement: { step(by: -1) }) {
                LabeledContent("Limit") {
                    Text(Self.formatMbps(settings.bandwidthKbps))
                        .monospacedDigit()
                }
            }
            .accessibilityIdentifier("quality.videoLimit")
        }
    }

    private func step(by delta: Int) {
        let steps = Self.manualSteps
        let current = settings.bandwidthKbps
        let nearest = steps.indices.min(by: { abs(steps[$0] - current) < abs(steps[$1] - current) }) ?? 0
        settings.bandwidthKbps = steps[min(max(nearest + delta, 0), steps.count - 1)]
    }

    static func formatMbps(_ kbps: Int) -> String {
        (Double(kbps) / 1000).formatted(.number.precision(.fractionLength(0...2))) + " Mbps"
    }
}
