// Frozen pre-optimization encoder for reproducible before/after comparison.
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

final class BaselineTileEncoder {
    private(set) var metrics=EncodingMetrics()
    private var lastPixels: Data?
    private var lastWidth = 0
    private var lastHeight = 0
    private var previousRegion = CGRect.zero
    private let tileSize = 256
    private var lastWasMotion = false
    private var lastChange = Date.distantPast
    func reset() { lastPixels = nil; lastWidth = 0; lastHeight = 0; lastWasMotion=false }
    func encode(_ image: CGImage, region: CGRect, color: String, quality: Double, motion: Bool, auto: Bool = false) -> [EncodedTile] {
        let started=DispatchTime.now().uptimeNanoseconds
        var stage=started
        metrics=EncodingMetrics()
        defer { metrics.totalMilliseconds=Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000 }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 7680, h <= 7680 else { return [] }
        let bytesPerRow = w * 4
        var pixels = Data(count: h * bytesPerRow)
        let drawn = pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let afterRaster=DispatchTime.now().uptimeNanoseconds
            metrics.rasterMilliseconds=Double(afterRaster-stage)/1_000_000
            stage=afterRaster
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
        let afterQuantize=DispatchTime.now().uptimeNanoseconds
        metrics.quantizeMilliseconds=Double(afterQuantize-stage)/1_000_000
        stage=afterQuantize
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
        let afterDiff=DispatchTime.now().uptimeNanoseconds
        metrics.diffMilliseconds=Double(afterDiff-stage)/1_000_000
        stage=afterDiff
        defer { metrics.codecMilliseconds=Double(DispatchTime.now().uptimeNanoseconds-stage)/1_000_000 }
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
