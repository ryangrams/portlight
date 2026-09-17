import Foundation

/// Turns packets the epoch gate accepted into PCM blocks. Keeps one AAC decoder for the current
/// (channels, cookie) and replaces it when either changes. Confined to the audio queue.
struct AudioPacketDecoder {
    private var aac: AACAccessUnitDecoder?

    mutating func decode(_ header: AudioHeader, payload: Data) -> PCMBlock? {
        switch header.codec {
        case .aac:
            guard let cookie = header.cookie else { return nil }
            if aac?.channels != header.channels || aac?.cookie != cookie {
                aac = AACAccessUnitDecoder(channels: header.channels, cookie: cookie)
            }
            guard let pcm = aac?.decode(payload), let block = PCMBlock(pcm),
                  block.format == PCMFormat(sampleRate: Double(AACAccessUnitDecoder.sampleRate), channels: header.channels) else { return nil }
            return block
        case .mulaw:
            guard payload.count == header.samples, let pcm = MuLaw.pcmBuffer(payload) else { return nil }
            return PCMBlock(pcm)
        }
    }

    mutating func reset() { aac = nil }
}
