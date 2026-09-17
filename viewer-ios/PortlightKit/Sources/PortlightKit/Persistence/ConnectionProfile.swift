import Foundation

// Saved-connection value types. None of them holds a secret: passwords live only in the Keychain
// (`SecretStore`), keyed by `ConnectionProfile.secretAccount`.

/// Viewing choices saved with a connection and applied when it connects.
///
/// Display selection is deliberately absent: every fresh connection selects all displays
/// (notes §4), so a saved subset can never silently narrow what the user sees.
public struct ViewerPreferences: Codable, Equatable, Hashable, Sendable {
    public var resolution: ResolutionPreset
    public var color: ColorMode
    public var quality: ContentPriority
    /// The mode a connection starts in: Trackpad or Direct. Pan is a temporary, local-only mode that suppresses
    /// remote input, so it is never saved as the starting mode (it is stored as Trackpad, the plan's default).
    public var inputMode: InputMode {
        didSet { inputMode = ViewerPreferences.startingInputMode(inputMode) }
    }
    /// Rate used when audio is switched on. Choosing a rate never switches audio on.
    public var audioQuality: AudioQuality
    /// Video data-rate ceiling in kbps: 0 = Automatic, otherwise 100...100000. Kept wire-valid on every write.
    public var bandwidthKbps: Int {
        didSet { bandwidthKbps = ViewerPreferences.wireBandwidthKbps(bandwidthKbps) }
    }
    /// Smooth gradients (`dither` on the wire). Effective only in Video with reduced color, and uses more data.
    public var smoothGradients: Bool

    public init(resolution: ResolutionPreset = .hd, color: ColorMode = .full, quality: ContentPriority = .automatic,
                inputMode: InputMode = .trackpad, audioQuality: AudioQuality = .stereo96,
                bandwidthKbps: Int = 0, smoothGradients: Bool = false) {
        self.resolution = resolution
        self.color = color
        self.quality = quality
        self.inputMode = ViewerPreferences.startingInputMode(inputMode)
        self.audioQuality = audioQuality
        self.bandwidthKbps = ViewerPreferences.wireBandwidthKbps(bandwidthKbps)
        self.smoothGradients = smoothGradients
    }

    /// Phone defaults from the execution plan: HD, Full Color, Automatic, Trackpad, stereo 96 kbps,
    /// automatic data rate, no dither.
    public static let standard = ViewerPreferences()

    /// Nearest wire-valid `bandwidthKbps`: nonpositive means Automatic (0); manual values clamp to 100...100000.
    public static func wireBandwidthKbps(_ value: Int) -> Int {
        value <= 0 ? 0 : min(max(value, 100), 100_000)
    }

    /// The saved form of a starting mode: Pan becomes Trackpad; Trackpad and Direct are kept.
    public static func startingInputMode(_ mode: InputMode) -> InputMode {
        mode == .pan ? .trackpad : mode
    }

    private enum CodingKeys: String, CodingKey {
        case resolution, color, quality, inputMode, audioQuality, bandwidthKbps, smoothGradients
    }

    /// Tolerant decoding: a missing or unrecognized value (for example a case written by a newer build)
    /// falls back to its default instead of making the whole saved library unreadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ViewerPreferences.standard
        self.init(
            resolution: (try? container.decodeIfPresent(ResolutionPreset.self, forKey: .resolution)) ?? fallback.resolution,
            color: (try? container.decodeIfPresent(ColorMode.self, forKey: .color)) ?? fallback.color,
            quality: (try? container.decodeIfPresent(ContentPriority.self, forKey: .quality)) ?? fallback.quality,
            inputMode: (try? container.decodeIfPresent(InputMode.self, forKey: .inputMode)) ?? fallback.inputMode,
            audioQuality: (try? container.decodeIfPresent(AudioQuality.self, forKey: .audioQuality)) ?? fallback.audioQuality,
            bandwidthKbps: (try? container.decodeIfPresent(Int.self, forKey: .bandwidthKbps)) ?? fallback.bandwidthKbps,
            smoothGradients: (try? container.decodeIfPresent(Bool.self, forKey: .smoothGradients)) ?? fallback.smoothGradients
        )
    }
}

/// One saved connection: where to connect and how to view it.
public struct ConnectionProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Title of a profile saved without a name. Never the host address, which appears as the subtitle instead.
    public static let unnamedTitle = "Saved Connection"

    public var id: UUID
    /// Optional user-chosen name, distinct from the computer address; empty means unnamed.
    public var name: String
    /// Computer: host name or IP address as validated by `HostEndpoint` (IPv6 stored without brackets).
    public var host: String
    public var port: Int
    public var groupID: UUID?
    /// Position within its group, or among ungrouped profiles. Owned by `ProfileLibrary`.
    public var sortIndex: Int
    public var createdAt: Date
    public var lastConnectedAt: Date?
    /// Whether a password was saved to the Keychain. A hint for the form, never the secret. It can be stale
    /// (a restored backup does not carry ThisDeviceOnly Keychain items), so connecting still resolves the secret.
    public var hasSavedPassword: Bool
    /// `HostEndpoint.canonicalKey` of the computer the saved password was typed for. The password is only ever
    /// sent to that computer, so editing the Computer field can't carry it to another one. Nil when none is saved,
    /// or for a password saved before passwords were bound to a computer (never sent; the user types it again).
    public var passwordEndpointKey: String?
    public var preferences: ViewerPreferences

    /// With `hasSavedPassword` and no `passwordEndpointKey`, the password counts as saved for this profile's own
    /// computer.
    public init(id: UUID = UUID(), name: String = "", host: String, port: Int = PortlightProtocol.defaultPort,
                groupID: UUID? = nil, sortIndex: Int = 0, createdAt: Date = Date(), lastConnectedAt: Date? = nil,
                hasSavedPassword: Bool = false, passwordEndpointKey: String? = nil,
                preferences: ViewerPreferences = .standard) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.groupID = groupID
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.hasSavedPassword = hasSavedPassword
        self.passwordEndpointKey = hasSavedPassword
            ? (passwordEndpointKey ?? HostEndpoint(host: host, port: port)?.canonicalKey)
            : nil
        self.preferences = preferences
    }

    public var isUnnamed: Bool { trimmedName.isEmpty }

    /// Row title: the user's name, or "Saved Connection" when unnamed.
    public var displayTitle: String { isUnnamed ? Self.unnamedTitle : trimmedName }

    /// The validated address to connect to; nil only for a profile edited outside the draft validation (a
    /// hand-edited or damaged file). Such a row can still be opened and corrected.
    public var endpoint: HostEndpoint? { HostEndpoint(host: host, port: port) }

    /// Secondary row text: the computer address, with the port only when it isn't the default.
    public var subtitle: String {
        guard let endpoint else {
            let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
            return port == PortlightProtocol.defaultPort ? raw : "\(raw):\(port)"
        }
        return endpoint.port == PortlightProtocol.defaultPort ? endpoint.host : endpoint.description
    }

    /// Keychain account holding this profile's password.
    public var secretAccount: String { id.uuidString }

    /// True when a password is saved and it was saved for `endpoint`'s computer (same canonical key).
    public func canUseSavedPassword(for endpoint: HostEndpoint) -> Bool {
        hasSavedPassword && passwordEndpointKey == endpoint.canonicalKey
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, groupID, sortIndex, createdAt, lastConnectedAt, hasSavedPassword,
             passwordEndpointKey, preferences
    }

    /// Identity and address are required. Any other value that is missing or malformed falls back to its default,
    /// so a file from an older or newer build still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        groupID = try? container.decodeIfPresent(UUID.self, forKey: .groupID)
        sortIndex = (try? container.decodeIfPresent(Int.self, forKey: .sortIndex)) ?? 0
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        lastConnectedAt = try? container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        hasSavedPassword = (try? container.decodeIfPresent(Bool.self, forKey: .hasSavedPassword)) ?? false
        // Unlike `init`, a missing key is not filled in: an unbound saved password is never sent.
        let endpointKey = try? container.decodeIfPresent(String.self, forKey: .passwordEndpointKey)
        passwordEndpointKey = hasSavedPassword ? endpointKey : nil
        preferences = (try? container.decodeIfPresent(ViewerPreferences.self, forKey: .preferences)) ?? .standard
    }
}

/// An optional, user-named group of saved connections.
public struct ProfileGroup: Codable, Identifiable, Equatable, Hashable, Sendable {
    public static let defaultName = "New Group"
    public static let maxNameLength = 100

    public var id: UUID
    public var name: String
    /// Position among groups. Owned by `ProfileLibrary`.
    public var sortIndex: Int
    /// Disclosure state of the group row, restored on launch.
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, sortIndex: Int = 0, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.isExpanded = isExpanded
    }

    /// Trimmed and limited to `maxNameLength` characters; nil when nothing remains.
    public static func cleanedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey { case id, name, sortIndex, isExpanded }

    /// Only the identity is required; malformed values fall back to their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? Self.defaultName
        sortIndex = (try? container.decodeIfPresent(Int.self, forKey: .sortIndex)) ?? 0
        isExpanded = (try? container.decodeIfPresent(Bool.self, forKey: .isExpanded)) ?? true
    }
}
