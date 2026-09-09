import Foundation
import AVFoundation

final class RemoteAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var pending = 0
    private var generation = UUID()
    private let lock = NSLock()
    func stop() { lock.lock(); generation = UUID(); pending = 0; lock.unlock(); player?.stop(); engine?.stop(); player = nil; engine = nil }
    func play(_ data:Data,sampleRate:Int,channels:Int) {
        guard sampleRate == 24000, channels == 1, data.count > 0, data.count <= 24000 else { return }
        if engine == nil {
            let e = AVAudioEngine(), p = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate:24000,channels:1) else { return }
            e.attach(p); e.connect(p,to:e.mainMixerNode,format:format)
            do { try e.start(); p.play(); engine = e; player = p } catch { return }
        }
        lock.lock(); let full = pending >= 8; lock.unlock()
        if full { stop(); return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate:24000,channels:1), let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(data.count)), let output = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(data.count)
        for (i,raw) in data.enumerated() { output[i] = Float(Self.decode(raw)) / 32768.0 }
        lock.lock(); pending += 1; lock.unlock(); let active = generation
        player?.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in guard let self else { return }; self.lock.lock(); if self.generation == active { self.pending = max(0,self.pending-1) }; self.lock.unlock() }
    }
    static func decode(_ encoded:UInt8) -> Int16 {
        let u = Int(~encoded), sign = u & 0x80, exponent = (u >> 4) & 7, mantissa = u & 15
        let value = ((mantissa << 3) + 0x84) << exponent
        return Int16(sign == 0 ? value - 0x84 : 0x84 - value)
    }
}
