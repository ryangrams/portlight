import AVFoundation

/// G.711 μ-law expansion for the host's fallback audio: 24 kHz mono, one byte per sample.
enum MuLaw {
    static let sampleRate = 24_000

    /// Bit-exact with the Mac viewer's `RemoteAudio.decode`: 0xFF and 0x7F → 0, 0x00 → −32124, 0x80 → 32124.
    static func decode(_ encoded: UInt8) -> Int16 {
        let u = Int(~encoded)
        let sign = u & 0x80, exponent = (u >> 4) & 7, mantissa = u & 0x0F
        let magnitude = ((mantissa << 3) + 0x84) << exponent
        return Int16(sign == 0 ? magnitude - 0x84 : 0x84 - magnitude)
    }

    /// All 256 expansions, so a packet decodes with one lookup per byte.
    static let table: [Int16] = (0...255).map { decode(UInt8($0)) }

    /// One packet as a standard 24 kHz mono Float32 buffer; nil for an empty payload.
    static func pcmBuffer(_ payload: Data) -> AVAudioPCMBuffer? {
        guard !payload.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(payload.count)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(payload.count)
        let table = Self.table
        payload.withUnsafeBytes { bytes in
            for (index, byte) in bytes.enumerated() { samples[index] = Float(table[Int(byte)]) / 32768 }
        }
        return buffer
    }
}
