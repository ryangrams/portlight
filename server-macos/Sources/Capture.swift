import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

final class CaptureStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let display: DisplayInfo
    let width: Int
    let height: Int
    private(set) var stream: SCStream!
    private let queue = DispatchQueue(label: "com.studioupgrade.suremote.capture", qos: .userInteractive)
    var onImage: ((CGImage) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    private var active = true
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var audioConverter: AVAudioConverter?
    private var audioSourceDescription: AudioStreamBasicDescription?

    init(display: DisplayInfo, scDisplay: SCDisplay, size: (Int,Int), fps: Int, audio: Bool) throws {
        self.display = display; self.width = size.0; self.height = size.1
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = size.0; config.height = size.1
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false; config.preservesAspectRatio = true
        config.capturesAudio = audio; config.sampleRate = 24000; config.channelCount = 1
        config.excludesCurrentProcessAudio = true; config.captureMicrophone = false
        config.streamName = "SU Remote — \(display.name)"
        super.init()
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
    }
    func start() async throws { try await stream.startCapture() }
    func stop() async { active = false; try? await stream.stopCapture() }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard active, sampleBuffer.isValid else { return }
        if type == .screen {
            guard let buffer = sampleBuffer.imageBuffer else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let statusRaw = attachments.first?[.status] as? Int, statusRaw != SCFrameStatus.complete.rawValue { return }
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = ci.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) { onImage?(cg) }
        } else if type == .audio { processAudio(sampleBuffer) }
    }
    private func processAudio(_ sample: CMSampleBuffer) {
        guard let formatDescription = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: asbd),
              let destination = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else { return }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return }
        input.frameLength = frames
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard result == noErr else { return }
        if audioConverter == nil || audioConverter?.inputFormat != sourceFormat { audioConverter = AVAudioConverter(from: sourceFormat, to: destination) }
        guard let converter = audioConverter,
              let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: AVAudioFrameCount(Double(frames) * 24000 / sourceFormat.sampleRate + 32)) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return input
        }
        guard status != .error, output.frameLength > 0, let bytes = output.int16ChannelData?[0] else { return }
        onAudio?(Data(bytes: bytes, count: Int(output.frameLength)*2))
    }
}

struct EncodedTile {
    let x: Int; let y: Int; let width: Int; let height: Int; let codec: String; let data: Data
}

final class TileEncoder {
    private var lastPixels: Data?
    private var lastWidth = 0
    private var lastHeight = 0
    private var previousRegion = CGRect.zero
    private let tileSize = 256
    private var lastWasMotion = false
    private var lastChange = Date.distantPast
    func reset() { lastPixels = nil; lastWidth = 0; lastHeight = 0; lastWasMotion=false }
    func encode(_ image: CGImage, region: CGRect, color: String, quality: Double, motion: Bool, auto: Bool = false) -> [EncodedTile] {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 7680, h <= 7680 else { return [] }
        let bytesPerRow = w * 4
        var pixels = Data(count: h * bytesPerRow)
        let drawn = pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = bytes.bindMemory(to: UInt8.self)
            if color != "full" {
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    let r = Int(p[i]), g = Int(p[i+1]), b = Int(p[i+2])
                    if color == "gray16" {
                        let weighted: Int = r*77 + g*150 + b*29 + 128
                        let quantized: Int = (weighted >> 8) / 17 * 17
                        let gray = UInt8(min(255,quantized))
                        p[i]=gray; p[i+1]=gray; p[i+2]=gray
                    } else if color == "color256" {
                        p[i] = UInt8((r >> 5) * 255 / 7); p[i+1] = UInt8((g >> 5)*255/7); p[i+2] = UInt8((b >> 6)*255/3)
                    } else if color == "rgb565" {
                        p[i] = UInt8((r >> 3)*255/31); p[i+1] = UInt8((g >> 2)*255/63); p[i+2] = UInt8((b >> 3)*255/31)
                    }
                }
            }
            return true
        }
        guard drawn else { return [] }
        let visible = CGRect(x: region.minX*CGFloat(w), y: region.minY*CGFloat(h), width: region.width*CGFloat(w), height: region.height*CGFloat(h)).intersection(CGRect(x: 0,y:0,width:w,height:h)).integral
        guard !visible.isEmpty else { return [] }
        let force = lastPixels == nil || lastWidth != w || lastHeight != h || previousRegion != region
        var rects: [CGRect] = []
        if motion {
            if force || lastPixels != pixels { rects = [visible] }
        } else {
            pixels.withUnsafeBytes { now in
                lastPixels?.withUnsafeBytes { old in
                    guard old.count == now.count else { return }
                    for y in stride(from: max(0,Int(visible.minY)/tileSize*tileSize), to: min(h,Int(visible.maxY)), by: tileSize) {
                        for x in stride(from: max(0,Int(visible.minX)/tileSize*tileSize), to: min(w,Int(visible.maxX)), by: tileSize) {
                            let tw = min(tileSize,w-x), th = min(tileSize,h-y)
                            var changed = force
                            if !changed {
                                for row in y..<(y+th) {
                                    if memcmp(now.baseAddress!.advanced(by: row*bytesPerRow+x*4), old.baseAddress!.advanced(by: row*bytesPerRow+x*4), tw*4) != 0 { changed=true; break }
                                }
                            }
                            if changed { rects.append(CGRect(x:x,y:y,width:tw,height:th).intersection(visible)) }
                        }
                    }
                }
            }
            if force && rects.isEmpty { rects = [visible] }
        }
        var useJPEG = motion && color == "full"
        if !rects.isEmpty { lastChange=Date() }
        if auto && color == "full" && !force {
            let changedArea=rects.reduce(CGFloat(0)) { $0 + $1.width*$1.height }
            if changedArea > visible.width*visible.height*0.35 { useJPEG=true;rects=[visible] }
            else if lastWasMotion && rects.isEmpty && Date().timeIntervalSince(lastChange) >= 0.5 { rects=[visible] }
        }
        if !rects.isEmpty { lastWasMotion=useJPEG }
        lastPixels = pixels; lastWidth = w; lastHeight = h; previousRegion = region
        guard let provider = CGDataProvider(data: pixels as CFData),
              let full = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:bytesPerRow,space:CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { return [] }
        return rects.compactMap { rect in
            guard let crop = full.cropping(to: rect) else { return nil }
            let data = NSMutableData()
            let codec = useJPEG ? "jpeg" : "png"
            guard let destination = CGImageDestinationCreateWithData(data, (codec == "jpeg" ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { return nil }
            let properties: [CFString: Any] = codec == "jpeg" ? [kCGImageDestinationLossyCompressionQuality:quality] : [:]
            CGImageDestinationAddImage(destination,crop,properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return EncodedTile(x:Int(rect.minX),y:Int(rect.minY),width:crop.width,height:crop.height,codec:codec,data:data as Data)
        }
    }
}

func fixtureImage(display: DisplayInfo, width: Int, height: Int, frame: Int) -> CGImage? {
    guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let colors: [(CGFloat,CGFloat,CGFloat)] = [(0.09,0.16,0.24),(0.13,0.25,0.16),(0.25,0.13,0.2)]
    let c = colors[(display.index-1)%colors.count]
    context.setFillColor(red:c.0,green:c.1,blue:c.2,alpha:1); context.fill(CGRect(x:0,y:0,width:width,height:height))
    context.setFillColor(red:0.2,green:0.8,blue:0.65,alpha:1)
    context.fill(CGRect(x:width/10,y:height/4,width:width*4/5,height:height/2))
    context.setFillColor(red:1,green:0.8,blue:0.25,alpha:1)
    context.fill(CGRect(x:(frame%30)*max(1,width/40),y:height/10,width:max(8,width/20),height:max(8,height/20)))
    return context.makeImage()
}
