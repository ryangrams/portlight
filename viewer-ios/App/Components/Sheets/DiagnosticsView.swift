import SwiftUI
import PortlightKit

/// A selected display's canvas size, labelled by display number: display IDs can identify the Mac's hardware.
struct DiagnosticsCanvas: Equatable, Sendable, Identifiable {
    var number: Int
    var size: PixelSize
    var id: Int { number }
}

/// What the Diagnostics sheet shows. The session owner refreshes it at up to 2 Hz.
struct DiagnosticsReport: Equatable, Sendable {
    var engine: EngineDiagnostics
    var audio: AudioMetrics
    var presentedDraws: Int
    var skippedDraws: Int
    var receiveMbps: Double?
    var changedImagesPerSecond: Double?
    var subscriptionsPerMinute: Double?
    var timeToFreshRegion: TimeInterval?
    var requested: ResolutionPreset
    var effective: EffectiveResolution?
    var canvases: [DiagnosticsCanvas]
    /// Included in the export only when the person opts in.
    var computerName: String?

    /// Plain text for sharing: no passwords, certificate fingerprints, display IDs or pixels, and the computer
    /// name only when `includeComputerName` is on.
    func exportText(includeComputerName: Bool, generated: Date = Date()) -> String {
        typealias F = DiagnosticsFormat
        var lines = ["Portlight diagnostics", "Generated: \(generated.formatted(.iso8601))"]
        if includeComputerName, let computerName { lines.append("Computer: \(computerName)") }
        lines.append("Receive: \(F.mbps(receiveMbps)); changed images \(F.rate(changedImagesPerSecond, unit: "/s")); round trip \(F.milliseconds(engine.lastRTTMilliseconds))")
        lines.append("Rectangles: decoded \(engine.framesDecoded), applied \(engine.framesCommitted), rejected \(engine.framesRejected), stale \(engine.framesStale)")
        lines.append("Draws: presented \(presentedDraws), skipped \(skippedDraws)")
        lines.append("Decoder queue: \(engine.decodeJobsInFlight) jobs, \(F.bytes(engine.decodeBytesInFlight)) (peak \(engine.decodeJobsPeak) jobs, \(F.bytes(engine.decodeBytesPeak)))")
        lines.append("Frame age: \(F.duration(engine.lastPatchAge))")
        lines.append("Subscriptions: \(F.rate(subscriptionsPerMinute, unit: "/min")); time to fresh region \(F.duration(timeToFreshRegion))")
        lines.append("Audio: queued \(F.milliseconds(audio.queuedMilliseconds)), underruns \(audio.underruns), drops \(audio.drops + audio.backlogDrops)")
        lines.append("Resolution: requested \(requested.title), effective \(F.resolution(effective))")
        lines.append("Canvases: " + (canvases.isEmpty ? "none" : canvases.map { "Display \($0.number) \($0.size.width)×\($0.size.height)" }.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }
}

enum DiagnosticsFormat {
    static func mbps(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) + " Mbps" } ?? "—"
    }

    static func rate(_ value: Double?, unit: String) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) + unit } ?? "—"
    }

    static func milliseconds(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0))) + " ms" } ?? "—"
    }

    static func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        return value < 1 ? milliseconds(value * 1000) : value.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func resolution(_ value: EffectiveResolution?) -> String {
        switch value {
        case nil: "—"
        case .native?: "Native"
        case .preset(let preset)?: preset.title
        }
    }
}

/// Read-only diagnostics (UI-SPEC §10) with a privacy-safe export.
struct DiagnosticsView: View {
    let report: DiagnosticsReport
    private let onDone: (@MainActor () -> Void)?
    @State private var includeComputerName = false
    @State private var detent: PresentationDetent
    @Environment(\.dismiss) private var dismiss

    init(report: DiagnosticsReport, startsExpanded: Bool = false, onDone: (@MainActor () -> Void)? = nil) {
        self.report = report
        self.onDone = onDone
        _detent = State(initialValue: startsExpanded ? .large : .medium)
    }

    private typealias F = DiagnosticsFormat

    var body: some View {
        NavigationStack {
            List {
                section("Network") {
                    row("Receive", F.mbps(report.receiveMbps))
                    row("Changed images", F.rate(report.changedImagesPerSecond, unit: " /s"))
                    row("Round trip", F.milliseconds(report.engine.lastRTTMilliseconds))
                }
                section("Rectangles") {
                    row("Decoded", "\(report.engine.framesDecoded)")
                    row("Applied", "\(report.engine.framesCommitted)")
                    row("Rejected", "\(report.engine.framesRejected)")
                    row("Stale", "\(report.engine.framesStale)")
                }
                section("Drawing") {
                    row("Presented", "\(report.presentedDraws)")
                    row("Skipped", "\(report.skippedDraws)")
                    row("Frame age", F.duration(report.engine.lastPatchAge))
                }
                section("Decoder Queue") {
                    row("Jobs", "\(report.engine.decodeJobsInFlight) (peak \(report.engine.decodeJobsPeak))")
                    row("Bytes", "\(F.bytes(report.engine.decodeBytesInFlight)) (peak \(F.bytes(report.engine.decodeBytesPeak)))")
                }
                section("Subscriptions") {
                    row("Sent per minute", F.rate(report.subscriptionsPerMinute, unit: ""))
                    row("Time to fresh region", F.duration(report.timeToFreshRegion))
                }
                section("Audio") {
                    row("Queued", F.milliseconds(report.audio.queuedMilliseconds))
                    row("Underruns", "\(report.audio.underruns)")
                    row("Drops", "\(report.audio.drops + report.audio.backlogDrops)")
                }
                section("Resolution") {
                    row("Requested", report.requested.title)
                    row("Effective", F.resolution(report.effective))
                    ForEach(report.canvases) { canvas in
                        row("Display \(canvas.number) canvas", "\(canvas.size.width) × \(canvas.size.height)")
                    }
                }
                Section {
                    Toggle("Include Computer Name", isOn: $includeComputerName)
                        .disabled(report.computerName == nil)
                    ShareLink(item: report.exportText(includeComputerName: includeComputerName)) {
                        Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("diagnostics.export")
                } footer: {
                    Text("The export never includes passwords, certificate fingerprints or screen images.")
                        .foregroundStyle(PortlightTheme.secondaryText)
                }
            }
            .navigationTitle("Diagnostics")
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

    /// Section headers and values use `PortlightTheme.secondaryText`: the list's own gray measured 3.3:1.
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        Section {
            rows()
        } header: {
            Text(title).foregroundStyle(PortlightTheme.secondaryText)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(PortlightTheme.secondaryText)
        }
    }
}
