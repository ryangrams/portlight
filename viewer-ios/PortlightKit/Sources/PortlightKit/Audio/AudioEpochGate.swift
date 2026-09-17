import Foundation

/// Decides which audio packets belong to the audio configuration the host most recently acknowledged.
///
/// Revision ordering alone can't tell "the same configuration across video-only revisions" (keep
/// playing, as the Mac viewer does) from "audio turned Off and On again with the same codec" (the old
/// stream's late packets must not play). The gate therefore tracks an epoch: the revision at which the
/// current configuration started. It rejects packets stamped before that revision, packets stamped after
/// the newest acknowledged revision (their configuration isn't known yet), and packets whose format
/// doesn't match the configuration.
public struct AudioEpochGate: Equatable, Sendable {
    /// What an acknowledgement did to the epoch.
    public enum Transition: Equatable, Sendable {
        /// Same configuration (a video-only revision), or audio still off. Keep playing.
        case unchanged
        /// Audio turned on, or its codec or bitrate changed. Discard queued audio and wait for the new stream.
        case started
        /// Audio turned off. Stop.
        case stopped
    }

    /// The acknowledged configuration; nil while audio is off.
    public private(set) var configuration: AudioConfiguration?
    /// First revision of the current configuration.
    public private(set) var epochStartRevision: Int?
    /// Newest acknowledged revision.
    public private(set) var latestRevision: Int?

    public init() {}

    public var isEnabled: Bool { configuration != nil }

    /// Records a `subscribed` acknowledgement, in stream order.
    @discardableResult
    public mutating func acknowledged(_ configuration: AudioConfiguration?, revision: Int) -> Transition {
        // Revisions only increase within a connection; a lower one means a new connection, whose audio
        // must never be joined to the old epoch even with an identical configuration.
        let restarted = latestRevision.map { revision < $0 } ?? false
        latestRevision = revision
        guard let configuration else {
            let wasEnabled = self.configuration != nil
            self.configuration = nil
            epochStartRevision = nil
            return wasEnabled ? .stopped : .unchanged
        }
        if configuration == self.configuration && !restarted { return .unchanged }
        self.configuration = configuration
        epochStartRevision = revision
        return .started
    }

    /// True when the packet belongs to the current epoch and matches the configured format.
    public func accept(_ header: AudioHeader) -> Bool {
        guard let configuration, let start = epochStartRevision, let latest = latestRevision,
              header.revision >= start, header.revision <= latest, header.codec == configuration.codec else { return false }
        switch configuration.codec {
        case .aac:
            guard let cookie = header.cookie, !cookie.isEmpty, cookie.count <= AACAccessUnitDecoder.maxCookieBytes else { return false }
            return header.sampleRate == AACAccessUnitDecoder.sampleRate
                && header.samples == AACAccessUnitDecoder.framesPerPacket
                && header.channels == Self.aacChannels(forBitrate: configuration.bitrate)
                && (header.bitrate == nil || header.bitrate == configuration.bitrate)
        case .mulaw:
            return header.sampleRate == MuLaw.sampleRate && header.channels == 1
                && (1...Self.maxMuLawSamples).contains(header.samples)
        }
    }

    /// Back to "audio off" with no revision history (stop, disconnect).
    public mutating func reset() { self = AudioEpochGate() }

    /// The host encodes 48 kbps AAC as mono and every other rate as stereo.
    static func aacChannels(forBitrate bitrate: Int) -> Int { bitrate == 48_000 ? 1 : 2 }

    /// 200 ms. The host sends 480-sample (20 ms) packets; anything longer than the jitter bound is suspect.
    static let maxMuLawSamples = 4800
}
