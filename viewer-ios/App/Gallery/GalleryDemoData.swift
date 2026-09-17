import Foundation
import PortlightKit

/// Realistic demo values for the UI gallery: the fixture host's three displays, saved connections, a changed
/// certificate with real-format fingerprints, a failure, quality availability, sticky modifiers and diagnostics.
enum GalleryDemo {
    /// Same IDs, names and geometry as the `--fixture` host: 4K, 1080p and 4K, side by side, 1920 × 1080 pt each.
    static let displays: [HostDisplay] = [
        HostDisplay(id: "fixture-1", name: "Test Display 1", number: 1, nativeSize: PixelSize(width: 3840, height: 2160),
                    logicalFrame: LogicalRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2, isPrimary: true),
        HostDisplay(id: "fixture-2", name: "Test Display 2", number: 2, nativeSize: PixelSize(width: 1920, height: 1080),
                    logicalFrame: LogicalRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 1, isPrimary: false),
        HostDisplay(id: "fixture-3", name: "Test Display 3", number: 3, nativeSize: PixelSize(width: 3840, height: 2160),
                    logicalFrame: LogicalRect(x: 3840, y: 0, width: 1920, height: 1080), scale: 2, isPrimary: false),
    ]
    static var displayIDs: [DisplayID] { displays.map(\.id) }
    /// HD canvases, as the host acknowledges them for these displays.
    static let streamSize = PixelSize(width: 1280, height: 720)
    static var streamSizes: [DisplayID: PixelSize] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.id, streamSize) })
    }
    /// The predicted remote cursor, on Display 2 (compact-desktop points).
    static let cursor = LogicalPoint(x: 2_520, y: 430)

    static let endpoint = HostEndpoint(host: "studio-mac.local", port: PortlightProtocol.defaultPort)!
    static let fingerprint = CertificateFingerprint(string: "76ECB1D2D4B59A6F564B37DBE767BA5A74E22B5E3493EB3141B87DC662F90C0B")!
    static let previousFingerprint = CertificateFingerprint(string: "D0480EF72B55C949632707B83B3D1DCD19CF2E21FB0BC18106844F1303861FB6")!
    static let firstUsePrompt = TrustPrompt(endpoint: endpoint, fingerprint: fingerprint, previousFingerprint: nil)
    static let changedPrompt = TrustPrompt(endpoint: endpoint, fingerprint: fingerprint, previousFingerprint: previousFingerprint)
    static let failure = ConnectionFailure.refused

    private static let created = Date(timeIntervalSinceReferenceDate: 779_000_000)

    static let savedProfile = ConnectionProfile(id: UUID(uuidString: "5B1F7C1E-2D4A-4C8B-9E61-0A7D3F2B9C11")!,
                                                name: "Studio Mac", host: "studio-mac.local", createdAt: created,
                                                hasSavedPassword: true)

    static var library: ProfileLibrary {
        var library = ProfileLibrary()
        library.add(savedProfile)
        // Unnamed: its title is "Saved Connection", never the address.
        library.add(ConnectionProfile(id: UUID(uuidString: "0C4E51A2-7B3D-4F61-8A90-2E5C7D1B3F44")!,
                                      host: "192.168.1.42", port: 5921, createdAt: created))
        let suites = library.createGroup(named: "Edit Suites", id: UUID(uuidString: "9A2B6C1D-3E4F-4A5B-8C7D-1E2F3A4B5C6D")!)
        library.add(ConnectionProfile(id: UUID(uuidString: "1F2E3D4C-5B6A-4798-8B7A-6C5D4E3F2A1B")!, name: "Suite A",
                                      host: "suite-a.local", groupID: suites.id, createdAt: created, hasSavedPassword: true))
        library.add(ConnectionProfile(id: UUID(uuidString: "2A3B4C5D-6E7F-4081-9A2B-3C4D5E6F7A8B")!, name: "Suite B Color",
                                      host: "10.0.20.15", groupID: suites.id, createdAt: created))
        let home = library.createGroup(named: "Home", id: UUID(uuidString: "3B4C5D6E-7F80-4192-8A3B-4C5D6E7F8091")!)
        library.add(ConnectionProfile(id: UUID(uuidString: "4C5D6E7F-8091-42A3-9B4C-5D6E7F8091A2")!, name: "Mac mini",
                                      host: "mac-mini.local", groupID: home.id, createdAt: created))
        _ = library.setGroupExpanded(home.id, false)
        return library
    }

    /// A new connection after Connect was pressed with an out-of-range port and no password.
    static var newDraft: ConnectionDraft {
        var draft = ConnectionDraft()
        draft.name = "Studio Mac"
        draft.host = "studio-mac.local"
        draft.port = "70000"
        return draft
    }

    /// FHD selected; UHD needs more framebuffer memory than a phone budget allows for three displays.
    static let availability: [PresetAvailability] = [
        PresetAvailability(preset: .hd, isAvailable: true),
        PresetAvailability(preset: .fhd, isAvailable: true),
        PresetAvailability(preset: .qhd, isAvailable: true),
        PresetAvailability(preset: .uhd, isAvailable: false, reason: "UHD for 3 displays needs more memory than this iPhone allows."),
    ]
    static let qualitySettings = SessionSettings(resolution: .fhd)

    /// Display 2 is a 1080p panel, so the host caps QHD at FHD (its "Resolution limited" notice).
    static func qualityStatus(for settings: SessionSettings) -> QualityStatus {
        switch settings.resolution {
        case .qhd, .uhd:
            QualityStatus(requested: settings.resolution, effective: .preset(.fhd), limitation: "limited by Display 2")
        case .hd, .fhd:
            QualityStatus(requested: settings.resolution, effective: .preset(settings.resolution))
        }
    }

    /// ⌘ latched for the next action; ⇧ locked by a quick second tap.
    static var latches: ModifierLatches {
        var latches = ModifierLatches()
        latches.tap(.command, at: 100)
        latches.tap(.shift, at: 100)
        latches.tap(.shift, at: 100.2)
        return latches
    }

    static let diagnostics: DiagnosticsReport = {
        var engine = EngineDiagnostics()
        engine.bytesReceived = 48_213_512
        engine.framesReceived = 4_210
        engine.framesDecoded = 4_198
        engine.framesCommitted = 4_195
        engine.framesStale = 12
        engine.framesRejected = 0
        engine.decodeJobsInFlight = 2
        engine.decodeJobsPeak = 9
        engine.decodeBytesInFlight = 184_320
        engine.decodeBytesPeak = 2_310_144
        engine.subscriptionsSent = 3
        engine.lastRTTMilliseconds = 7.8
        engine.lastPatchAge = 0.12
        var audio = AudioMetrics()
        audio.configuration = AudioConfiguration(codec: .aac, bitrate: 96_000)
        audio.isPlaying = true
        audio.queuedMilliseconds = 64
        audio.underruns = 1
        return DiagnosticsReport(engine: engine, audio: audio, presentedDraws: 1_842, skippedDraws: 6_120,
                                 receiveMbps: 6.4, changedImagesPerSecond: 18.5, subscriptionsPerMinute: 1.5,
                                 timeToFreshRegion: 0.34, requested: .fhd, effective: .preset(.fhd),
                                 canvases: displays.map { DiagnosticsCanvas(number: $0.number, size: PixelSize(width: 1920, height: 1080)) },
                                 computerName: "Studio Mac")
    }()

    static func chrome(controlEnabled: Bool = true, inputMode: InputMode = .trackpad, paused: Bool = false,
                       hidden: Bool = false, keyboardVisible: Bool = false, audioEnabled: Bool = false,
                       selected: Int = 3, notice: SessionNotice? = nil, status: String = "Connected · HD") -> SessionChromeState {
        SessionChromeState(computerName: "Studio Mac", statusLine: paused ? "Paused" : status,
                           controlEnabled: controlEnabled, inputMode: inputMode, selectedDisplays: selected,
                           totalDisplays: displays.count, keyboardVisible: keyboardVisible, paused: paused,
                           audioEnabled: audioEnabled, controlsHidden: hidden, notice: notice)
    }
}
