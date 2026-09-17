import Foundation
import AVFoundation

// One raw AAC-LC access unit per audio envelope, with its decoder cookie in the header.
final class AACEncoder {
    let channels:Int
    let bitrate:Int
    private let inputFormat:AVAudioFormat
    private let converter:AVAudioConverter
    var cookie:Data { converter.magicCookie ?? Data() }
    init?(bitrate:Int) {
        guard [48000,96000,160000,320000].contains(bitrate) else { return nil }
        self.bitrate = bitrate; channels = bitrate == 48000 ? 1 : 2
        guard let input = AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:48000,channels:AVAudioChannelCount(channels),interleaved:true),
              let output = AVAudioFormat(settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:channels]),
              let converter = AVAudioConverter(from:input,to:output) else { return nil }
        inputFormat = input; self.converter = converter; converter.bitRate = bitrate; converter.primeMethod = .none
    }
    func encode(_ data:Data) -> Data? {
        guard data.count == 1024*channels*2, let input = AVAudioPCMBuffer(pcmFormat:inputFormat,frameCapacity:1024), let pointer = input.int16ChannelData?[0] else { return nil }
        input.frameLength = 1024; data.copyBytes(to:UnsafeMutableRawBufferPointer(start:pointer,count:data.count))
        let output = AVAudioCompressedBuffer(format:converter.outputFormat,packetCapacity:1,maximumPacketSize:max(4096,converter.maximumOutputPacketSize))
        var supplied = false; var error:NSError?
        let status = converter.convert(to:output,error:&error) { _,state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, output.packetCount == 1, output.byteLength > 0 else { return nil }
        return Data(bytes:output.data,count:Int(output.byteLength))
    }
}

final class AACDecoder {
    let channels:Int
    let cookie:Data
    private let converter:AVAudioConverter
    init?(channels:Int,cookie:Data) {
        guard (1...2).contains(channels), cookie.count <= 4096,
              let input = AVAudioFormat(settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:channels]),
              let output = AVAudioFormat(standardFormatWithSampleRate:48000,channels:AVAudioChannelCount(channels)),
              let converter = AVAudioConverter(from:input,to:output) else { return nil }
        self.channels = channels; self.cookie = cookie; self.converter = converter; converter.magicCookie = cookie; converter.primeMethod = .none
    }
    func decode(_ data:Data) -> AVAudioPCMBuffer? {
        guard !data.isEmpty, data.count <= 16384 else { return nil }
        let input = AVAudioCompressedBuffer(format:converter.inputFormat,packetCapacity:1,maximumPacketSize:data.count)
        data.copyBytes(to:UnsafeMutableRawBufferPointer(start:input.data,count:data.count)); input.byteLength = UInt32(data.count); input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset:0,mVariableFramesInPacket:1024,mDataByteSize:UInt32(data.count))
        guard let output = AVAudioPCMBuffer(pcmFormat:converter.outputFormat,frameCapacity:2048) else { return nil }
        var supplied = false; var error:NSError?
        let status = converter.convert(to:output,error:&error) { _,state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        return status != .error && output.frameLength > 0 ? output : nil
    }
}

func testAACRoundTrip() -> Bool {
    for bitrate in [48000,96000,160000,320000] {
        guard let encoder = AACEncoder(bitrate:bitrate) else { return false }
        var decodedFrames = 0; var decoder:AACDecoder?; var encodedBytes = 0
        for block in 0..<48 {
            var samples = [Int16](repeating:0,count:1024*encoder.channels)
            for frame in 0..<1024 { for channel in 0..<encoder.channels {
                samples[frame*encoder.channels+channel] = Int16(sin(Double(block*1024+frame)*2*Double.pi*Double(440+channel*220)/48000)*8000)
            } }
            let pcm = samples.withUnsafeBytes { Data($0) }
            if let packet = encoder.encode(pcm) {
                encodedBytes += packet.count
                if decoder == nil { decoder = AACDecoder(channels:encoder.channels,cookie:encoder.cookie) }
                if let output = decoder?.decode(packet) { decodedFrames += Int(output.frameLength) }
            }
        }
        guard decodedFrames >= 40000, encodedBytes > 1000, encodedBytes < 70000 else { return false }
    }
    return true
}
