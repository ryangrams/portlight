import Foundation

// Session vocabulary shared by the session engine and the app. Phase and failure copy lives here so
// every surface (progress card, failure view, VoiceOver) says the same thing.

/// An unknown or changed certificate awaiting the user's decision. No password has been sent.
public struct TrustPrompt: Equatable, Sendable, Identifiable {
    public let endpoint: HostEndpoint
    public let fingerprint: CertificateFingerprint
    /// The saved pin that no longer matches; nil on first use.
    public let previousFingerprint: CertificateFingerprint?
    public init(endpoint: HostEndpoint, fingerprint: CertificateFingerprint, previousFingerprint: CertificateFingerprint?) {
        self.endpoint = endpoint; self.fingerprint = fingerprint; self.previousFingerprint = previousFingerprint
    }
    public var isChange: Bool { previousFingerprint != nil }
    public var id: String { endpoint.canonicalKey + "|" + fingerprint.value }
}

/// Why a connection attempt or session ended. Distinct cases for distinct user remedies.
public enum ConnectionFailure: Error, Equatable, Sendable {
    case invalidAddress
    case hostNotFound
    /// Nothing is listening on that port (Portlight Host not running or sharing on another port).
    case refused
    case noRoute
    /// No answer within the client-owned connect deadline.
    case timedOut
    case localNetworkDenied
    case offline
    /// An established connection dropped.
    case networkLost
    case tlsFailed(String)
    /// The user declined an unknown certificate.
    case trustDeclined
    /// The saved pin no longer matches. Automatic reconnect stops until the user decides.
    case certificateChanged(TrustPrompt)
    case authenticationRejected(String)
    case busy(String)
    case hostClosed
    /// The host's `timeout` error: image updates were not acknowledged in time.
    case hostTimeout(String)
    case protocolViolation(String)
    case canceled

    /// Transient failures an automatic foreground reconnect may retry. Never credentials, trust,
    /// address or protocol failures. `busy` is handled by the reconnect policy (own zombie session).
    public var allowsAutomaticRetry: Bool {
        switch self {
        case .refused, .noRoute, .timedOut, .offline, .networkLost, .hostClosed, .hostTimeout: return true
        case .invalidAddress, .hostNotFound, .localNetworkDenied, .tlsFailed, .trustDeclined, .certificateChanged,
             .authenticationRejected, .busy, .protocolViolation, .canceled: return false
        }
    }

    public var title: String {
        switch self {
        case .invalidAddress: return "Check the Computer Address"
        case .hostNotFound: return "Computer Not Found"
        case .refused: return "Portlight Host Isn’t Listening"
        case .noRoute: return "Can’t Reach the Computer"
        case .timedOut: return "The Computer Didn’t Answer"
        case .localNetworkDenied: return "Allow Local Network Access"
        case .offline: return "No Network Connection"
        case .networkLost: return "Connection Lost"
        case .tlsFailed: return "Secure Connection Failed"
        case .trustDeclined: return "Computer Not Trusted"
        case .certificateChanged: return "Computer Identity Changed"
        case .authenticationRejected: return "Password Not Accepted"
        case .busy: return "Another Viewer Is Connected"
        case .hostClosed: return "The Mac Ended the Session"
        case .hostTimeout: return "Connection Stalled"
        case .protocolViolation: return "Unexpected Data from the Mac"
        case .canceled: return "Canceled"
        }
    }

    /// What happened and what to do, for the given computer.
    public func message(for endpoint: HostEndpoint?) -> String {
        let place = endpoint.map { $0.description } ?? "the computer"
        let host = endpoint?.host ?? "The computer"
        let port = endpoint.map { String($0.port) } ?? "that port"
        switch self {
        case .invalidAddress:
            return "Enter a host name or IP address, without wss://, a path, or a port."
        case .hostNotFound:
            return "No computer answers to “\(host)”. Check the spelling, or use its IP address."
        case .refused:
            return "\(host) refused the connection on port \(port). Check that Portlight Host is running and sharing on that port."
        case .noRoute:
            return "This iPhone has no route to \(place). Check that both devices are on the same network or VPN."
        case .timedOut:
            return "\(place) didn’t answer. Check that the Mac is awake, on the same network or VPN, and sharing with Portlight Host."
        case .localNetworkDenied:
            return "Portlight needs Local Network access to reach your Mac. Turn it on in Settings › Apps › Portlight, then try again."
        case .offline:
            return "Connect to Wi-Fi or a VPN that can reach your Mac, then try again."
        case .networkLost:
            return "The network connection to \(place) dropped."
        case .tlsFailed(let detail):
            // No claim about the password: a certificate switch mid-connection can happen after hello.
            return "The secure connection to \(place) failed (\(detail)). Check the computer’s identity in Portlight Host, then try again."
        case .trustDeclined:
            return "You didn’t approve this computer’s certificate. Your password was not sent."
        case .certificateChanged:
            return "The certificate for \(place) no longer matches the one you trusted. Continue only if you expected this, for example after reinstalling Portlight Host."
        case .authenticationRejected:
            return "The Mac rejected the password. Enter the password set in Portlight Host and try again."
        case .busy(let detail):
            return detail.isEmpty ? "Another viewer is connected to this Mac. Disconnect it before connecting here." : detail
        case .hostClosed:
            return "Portlight Host closed the connection."
        case .hostTimeout:
            return "The Mac ended the session because image updates weren’t acknowledged in time."
        case .protocolViolation(let detail):
            return "The Mac sent data this app can’t use (\(detail)). Update Portlight Host and this app to matching versions."
        case .canceled:
            return "The connection was canceled."
        }
    }
}

/// User-visible connection phases. A phase is shown only once it is actually reached (a socket that
/// hasn't opened is "Connecting", never "Authenticating").
public enum ConnectionPhase: Equatable, Sendable {
    case idle
    /// Opening TCP and TLS. `patient` turns true after a few seconds without an answer.
    case connecting(patient: Bool)
    /// The host presented a certificate; checking it against the saved pin.
    case checkingIdentity
    case awaitingTrust(TrustPrompt)
    /// Hello sent over the trusted connection.
    case authenticating
    /// Welcome received; the first subscription is waiting for `subscribed`.
    case loadingDisplays
    case connected
    /// Transient loss during a foreground session. The frozen frame stays visible and never controllable.
    case reconnecting(attempt: Int, after: ConnectionFailure)
    case failed(ConnectionFailure)

    public var title: String {
        switch self {
        case .idle: return "Not Connected"
        case .connecting: return "Connecting"
        case .checkingIdentity: return "Checking Computer Identity"
        case .awaitingTrust(let prompt): return prompt.isChange ? "Computer Identity Changed" : "Trust This Computer?"
        case .authenticating: return "Authenticating"
        case .loadingDisplays: return "Loading Displays"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .failed(let failure): return failure.title
        }
    }
    /// Any phase with a live or pending connection attempt.
    public var isInProgress: Bool {
        switch self {
        case .connecting, .checkingIdentity, .awaitingTrust, .authenticating, .loadingDisplays, .reconnecting: return true
        case .idle, .connected, .failed: return false
        }
    }
    public var isConnected: Bool { self == .connected }
}

/// The user's desired stream and control state. The session resends it as a complete subscription.
public struct SessionSettings: Equatable, Sendable, Codable {
    public var resolution: ResolutionPreset
    public var color: ColorMode
    public var quality: ContentPriority
    /// "Smooth gradients": host ordered dithering, effective only for Video with reduced color. Costs data.
    public var smoothGradients: Bool
    /// 0 = automatic, otherwise 100...100000.
    public var bandwidthKbps: Int
    public var audioEnabled: Bool
    public var audioQuality: AudioQuality
    /// false = View Only.
    public var controlEnabled: Bool
    public var paused: Bool
    public var inputMode: InputMode
    public init(resolution: ResolutionPreset = .hd, color: ColorMode = .full, quality: ContentPriority = .automatic,
                smoothGradients: Bool = false, bandwidthKbps: Int = 0, audioEnabled: Bool = false, audioQuality: AudioQuality = .stereo96,
                controlEnabled: Bool = true, paused: Bool = false, inputMode: InputMode = .trackpad) {
        self.resolution = resolution; self.color = color; self.quality = quality; self.smoothGradients = smoothGradients
        self.bandwidthKbps = bandwidthKbps; self.audioEnabled = audioEnabled; self.audioQuality = audioQuality
        self.controlEnabled = controlEnabled; self.paused = paused; self.inputMode = inputMode
    }
    /// Dither actually requested: never in Text or Automatic mode and never with Full Color (QUALITY-02).
    public var effectiveDither: Bool { smoothGradients && quality == .video && color != .full }
    /// Remote input may be sent only with Control On and not paused.
    public var allowsRemoteInput: Bool { controlEnabled && !paused }
}

/// Whether a resolution button can be chosen, with an accessible reason when it can't.
public struct PresetAvailability: Equatable, Sendable, Identifiable {
    public var preset: ResolutionPreset
    public var isAvailable: Bool
    public var reason: String?
    public init(preset: ResolutionPreset, isAvailable: Bool, reason: String? = nil) {
        self.preset = preset; self.isAvailable = isAvailable; self.reason = reason
    }
    public var id: ResolutionPreset { preset }
}

/// Non-fatal host or session conditions shown as a dismissible banner, never over the picture permanently.
public enum SessionNotice: Equatable, Sendable {
    /// The host applied a lower resolution than requested (its `notice`, or the phone's memory budget).
    case resolutionLimited(String)
    /// Screen capture failed on the host; fix it on the Mac. The viewer never asks for capture permission.
    case captureFailed(String)
    /// The host's display arrangement changed; the selection was intersected with the new displays.
    case displaysChanged
    /// The host rejected a subscription; the previous one keeps running.
    case settingsRejected(String)
    /// Audio was requested but the host doesn't provide it.
    case audioUnavailable
    /// Audio output paused by the system (call, route change); the user can resume.
    case audioInterrupted

    public var title: String {
        switch self {
        case .resolutionLimited: return "Resolution Limited"
        case .captureFailed: return "The Mac Can’t Capture Its Screen"
        case .displaysChanged: return "Displays Changed"
        case .settingsRejected: return "Setting Not Applied"
        case .audioUnavailable: return "Audio Unavailable"
        case .audioInterrupted: return "Audio Paused"
        }
    }
    public var message: String {
        switch self {
        case .resolutionLimited(let detail): return detail
        case .captureFailed(let detail): return detail
        case .displaysChanged: return "The Mac’s display arrangement changed. Choose displays again if needed."
        case .settingsRejected(let detail): return detail
        case .audioUnavailable: return "This Mac doesn’t provide audio to viewers."
        case .audioInterrupted: return "Audio paused because the audio route changed. Tap Resume to continue."
        }
    }
}
