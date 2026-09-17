import Foundation
import PortlightKit

/// How this launch stores its data. Production uses Application Support/Portlight and the Keychain. UI tests
/// launch with PORTLIGHT_TEST_DATA_DIR, which selects a fresh directory and an in-memory secret store, so a test
/// never reads or writes the simulator's Keychain.
struct AppConfiguration: Equatable {
    /// Where Connections.json and TrustedComputers.json live; nil = `ProfileStore.defaultDirectory()`.
    var dataDirectory: URL?
    /// true for UI tests: in-memory secrets and a separate UserDefaults suite.
    var usesTestStores: Bool
    /// The engine transcript file (PORTLIGHT_TRANSCRIPT=1); it never contains passwords or typed text.
    var transcriptURL: URL?
    /// The UserDefaults suite for UI state such as "gesture guide seen"; nil = `.standard`.
    var defaultsSuiteName: String?

    static let defaultTranscriptName = "portlight-transcript.log"

    static let production = AppConfiguration(dataDirectory: nil, usesTestStores: false, transcriptURL: nil, defaultsSuiteName: nil)

    /// Reads the launch environment.
    /// - PORTLIGHT_TEST_DATA_DIR: an absolute path, or a name resolved inside this app's temporary directory.
    /// - PORTLIGHT_TRANSCRIPT=1: write the transcript to Documents/portlight-transcript.log, or to
    ///   Documents/<PORTLIGHT_TRANSCRIPT_FILE> when that names a plain file.
    static func from(environment: [String: String], temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                     documentsDirectory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        -> AppConfiguration {
        var configuration = AppConfiguration.production
        if let raw = environment["PORTLIGHT_TEST_DATA_DIR"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let directory = raw.hasPrefix("/") ? URL(fileURLWithPath: raw, isDirectory: true)
                                               : temporaryDirectory.appendingPathComponent(raw, isDirectory: true)
            configuration.dataDirectory = directory
            configuration.usesTestStores = true
            configuration.defaultsSuiteName = "studio.upgrade.portlight.test." + directory.lastPathComponent
        }
        if environment["PORTLIGHT_TRANSCRIPT"] == "1", let documentsDirectory {
            configuration.transcriptURL = documentsDirectory.appendingPathComponent(
                transcriptFileName(environment["PORTLIGHT_TRANSCRIPT_FILE"]), isDirectory: false)
        }
        return configuration
    }

    /// A plain file name (no path separators, no leading dot); anything else falls back to the default name.
    static func transcriptFileName(_ requested: String?) -> String {
        guard let name = requested?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), name.count <= 100 else { return defaultTranscriptName }
        return name
    }

    /// Hosted unit tests run inside the app; the app then builds no session, audio or Keychain machinery.
    static func isHostingUnitTests(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}

/// The app's composition root: storage, the Metal renderer, audio, and the one `SessionController`.
///
/// Built once per launch. Views receive it through `AppModel`; nothing else creates sessions or stores.
@MainActor
final class AppEnvironment {
    let configuration: AppConfiguration
    let dataDirectory: URL
    let profileStore: ProfileStore
    let trustStore: FileTrustStore
    let secrets: any SecretAccountListing
    /// nil when Metal is unavailable; the session then uses a software framebuffer and draws nothing.
    let renderer: MetalRenderer?
    let audio: AudioPipeline
    let controller: SessionController
    let transcript: FileTranscriptSink?
    let defaults: UserDefaults
    /// Set when storage couldn't be prepared as usual (shown on the Connections screen).
    let storageNotice: String?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        var notice: String?
        let directory: URL
        if let configured = configuration.dataDirectory {
            directory = configured
        } else if let standard = try? ProfileStore.defaultDirectory() {
            directory = standard
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Portlight", isDirectory: true)
            notice = "Portlight can’t use its storage folder right now, so connections you save may not be kept."
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            notice = "Portlight can’t create its storage folder right now, so connections you save may not be kept."
        }
        dataDirectory = directory
        storageNotice = notice

        let profiles = ProfileStore(directory: directory)
        let trust = FileTrustStore(directory: directory)
        let secrets: any SecretAccountListing = configuration.usesTestStores ? InMemorySecretStore() : KeychainSecretStore()
        let renderer = try? MetalRenderer()
        let audio = AudioPipeline()
        let transcript = configuration.transcriptURL.flatMap { try? FileTranscriptSink(url: $0) }
        let framebuffer: FramebufferSink = renderer?.framebuffers ?? SoftwareFramebuffer()

        profileStore = profiles
        trustStore = trust
        self.secrets = secrets
        self.renderer = renderer
        self.audio = audio
        self.transcript = transcript
        defaults = configuration.defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        // Known before the first connection fails, so an offline iPhone and an unreachable Mac read differently.
        WebSocketTransport.startMonitoringNetwork()
        controller = SessionController(dependencies: SessionDependencies(
            transportFactory: { WebSocketTransport() },
            framebuffer: framebuffer,
            audio: audio,
            audioControl: SystemAudioSessionControl(output: audio),
            audioMetrics: { audio.metrics },
            presentation: renderer?.presentation,
            secrets: secrets,
            trust: trust,
            profiles: profiles,
            transcript: transcript))
    }

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        AppEnvironment(configuration: AppConfiguration.from(environment: environment))
    }
}
