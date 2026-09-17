import AVFoundation

// Adapted from app/shared/AAC.swift (`AACDecoder`). Ported instead of symlinked: the shared file's
// converter input block mutates a captured flag and captures a non-Sendable buffer inside a
// `@Sendable` closure, which strict-concurrency diagnostics flag (Swift 6 mode rejects it), and the
// phone has no use for the encoder. Decoding behavior is unchanged: raw AAC-LC access units (no ADTS)
// at 48 kHz configured by the host's ESDS magic cookie, one 1024-frame packet in, standard Float32 out.

/// Decodes one raw AAC-LC access unit at a time. Not thread-safe; confined to the audio queue.
final class AACAccessUnitDecoder {
    static let sampleRate = 48_000
    static let framesPerPacket = 1024
    /// Protocol bounds (notes §7): decoded cookie ≤ 4096 bytes, access unit ≤ 16384 bytes.
    static let maxCookieBytes = 4096
    static let maxAccessUnitBytes = 16_384

    let channels: Int
    let cookie: Data
    private let converter: AVAudioConverter

    init?(channels: Int, cookie: Data) {
        guard (1...2).contains(channels), !cookie.isEmpty, cookie.count <= Self.maxCookieBytes,
              let input = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                   AVSampleRateKey: Self.sampleRate,
                                                   AVNumberOfChannelsKey: channels]),
              let output = AVAudioFormat(standardFormatWithSampleRate: Double(Self.sampleRate), channels: AVAudioChannelCount(channels)),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.magicCookie = cookie
        converter.primeMethod = .none
        self.channels = channels
        self.cookie = cookie
        self.converter = converter
    }

    /// PCM for one access unit, or nil when the unit is empty, oversized or undecodable.
    func decode(_ accessUnit: Data) -> AVAudioPCMBuffer? {
        guard !accessUnit.isEmpty, accessUnit.count <= Self.maxAccessUnitBytes else { return nil }
        let packet = AVAudioCompressedBuffer(format: converter.inputFormat, packetCapacity: 1, maximumPacketSize: accessUnit.count)
        accessUnit.copyBytes(to: UnsafeMutableRawBufferPointer(start: packet.data, count: accessUnit.count))
        packet.byteLength = UInt32(accessUnit.count)
        packet.packetCount = 1
        packet.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: UInt32(Self.framesPerPacket), mDataByteSize: UInt32(accessUnit.count))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(Self.framesPerPacket * 2)) else { return nil }
        let source = OneShotPacketSource(packet)
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in source.next(inputStatus) }
        return status != .error && pcm.frameLength > 0 ? pcm : nil
    }
}

/// Hands the converter exactly one packet, then reports "no data now" so it doesn't wait for more.
/// `@unchecked Sendable`: AVAudioConverter calls its input block synchronously on the thread running
/// `convert(to:error:withInputFrom:)`, so this box is never accessed concurrently.
private final class OneShotPacketSource: @unchecked Sendable {
    private var packet: AVAudioCompressedBuffer?
    init(_ packet: AVAudioCompressedBuffer) { self.packet = packet }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let packet else { status.pointee = .noDataNow; return nil }
        self.packet = nil
        status.pointee = .haveData
        return packet
    }
}
