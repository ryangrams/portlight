import AppKit
import ImageIO
import Foundation

func renderedRGB(_ data:Data)->Data {
    let source=CGImageSourceCreateWithData(data as CFData,nil)!
    let image=CGImageSourceCreateImageAtIndex(source,0,nil)!
    var result=Data(count:image.width*image.height*4)
    result.withUnsafeMutableBytes { bytes in
        let context=CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    }
    return result
}
func testImage(_ width:Int,_ height:Int,_ offset:Int)->CGImage {
    let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    let bytes=context.data!.assumingMemoryBound(to:UInt8.self)
    for y in 0..<height { for x in 0..<width {
        let i=(y*width+x)*4
        bytes[i]=UInt8((x*13+y+offset)%256);bytes[i+1]=UInt8((x+y*17+offset)%256);bytes[i+2]=UInt8((x*7+y*3+offset)%256);bytes[i+3]=255
    } }
    return context.makeImage()!
}
@main struct EncoderValidation {
    static func main() throws {
        let whole=CGRect(x:0,y:0,width:1,height:1)
        let image=testImage(513,259,0)
        let old=BaselineTileEncoder().encode(image,region:whole,color:"gray16",quality:0.7,motion:false)
        let encoder=TileEncoder()
        let compact=encoder.encode(image,region:whole,color:"gray16",quality:0.7,motion:false)
        precondition(compact.count == 1 && compact[0].data[24] == 4 && compact[0].data[25] == 0,"PNG must use genuine 4-bit grayscale")
        let before=renderedRGB(old[0].data),after=renderedRGB(compact[0].data)
        var unequal=0
        for i in stride(from:0,to:before.count,by:4) { if before[i] != after[i] || before[i+1] != after[i+1] || before[i+2] != after[i+2] { unequal+=1 } }
        precondition(unequal == 0,"Grayscale rendered pixels changed: \(unequal)")
        precondition(encoder.encode(image,region:whole,color:"gray16",quality:0.7,motion:false).isEmpty,"Static grayscale emits frames")
        for region in [CGRect(x:1.0/513,y:1.0/259,width:257.0/513,height:127.0/259),CGRect(x:0.4,y:0.3,width:0.25,height:0.25)] {
            let oldROI=BaselineTileEncoder().encode(image,region:region,color:"gray16",quality:0.7,motion:false)
            let newROI=TileEncoder().encode(image,region:region,color:"gray16",quality:0.7,motion:false)
            precondition(oldROI.count == newROI.count)
            for (a,b) in zip(oldROI,newROI) {
                let ar=renderedRGB(a.data),br=renderedRGB(b.data)
                var delta=0
                for i in stride(from:0,to:min(ar.count,br.count),by:4) { if ar[i] != br[i] || ar[i+1] != br[i+1] || ar[i+2] != br[i+2] { delta+=1 } }
                precondition(a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height && delta == 0,"Odd-offset packed grayscale crop changed pixels")
            }
        }
        for mode in ["color256","rgb565","full"] {
            let old=BaselineTileEncoder(),new=TileEncoder()
            for offset in [0,0,1,17] {
                let frame=testImage(513,259,offset)
                let a=old.encode(frame,region:whole,color:mode,quality:0.7,motion:false),b=new.encode(frame,region:whole,color:mode,quality:0.7,motion:false)
                precondition(a.count == b.count && zip(a,b).allSatisfy{$0.data == $1.data},"Non-gray mode changed output")
            }
        }
        let jpeg=TileEncoder().encode(image,region:whole,color:"full",quality:0.7,motion:true)
        precondition(jpeg.first?.codec == "jpeg" && jpeg.first?.data.prefix(2) == Data([0xff,0xd8]))
        precondition(jpeg.first?.data == BaselineTileEncoder().encode(image,region:whole,color:"full",quality:0.7,motion:true).first?.data,"JPEG output changed")
        let auto=TileEncoder()
        _=auto.encode(image,region:whole,color:"full",quality:0.7,motion:false,auto:true)
        let moved=testImage(513,259,37)
        precondition(auto.encode(moved,region:whole,color:"full",quality:0.7,motion:false,auto:true).first?.codec == "jpeg")
        Thread.sleep(forTimeInterval:0.55)
        precondition(auto.encode(moved,region:whole,color:"full",quality:0.7,motion:false,auto:true).first?.codec == "png","Auto must restore sharp PNG after motion")
        let settling=TileEncoder(),largeA=testImage(1024,768,0),largeB=testImage(1024,768,37)
        _=settling.encode(largeA,region:whole,color:"full",quality:0.7,motion:false,auto:true)
        precondition(settling.encode(largeB,region:whole,color:"full",quality:0.7,motion:false,auto:true).first?.codec == "jpeg")
        let originalPixels=largeB.dataProvider!.data!
        // CGImage providers can expose read-only memory; make an owning copy.
        var partialPixels=Data(bytes:CFDataGetBytePtr(originalPixels)!,count:CFDataGetLength(originalPixels))
        partialPixels.withUnsafeMutableBytes { (bytes:UnsafeMutableRawBufferPointer) in
            for y in 10..<18 { for x in 10..<18 { let i=y*largeB.bytesPerRow+x*4;bytes[i]=0;bytes[i+1]=0;bytes[i+2]=0 } }
        }
        let partial=CGImage(width:1024,height:768,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:largeB.bytesPerRow,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:largeB.bitmapInfo,provider:CGDataProvider(data:partialPixels as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let partialTiles=settling.encode(partial,region:whole,color:"full",quality:0.7,motion:false,auto:true)
        precondition(!partialTiles.isEmpty && partialTiles.allSatisfy{$0.codec == "png" && $0.width <= 256},"Small change must remain lossless tiles")
        Thread.sleep(forTimeInterval:0.55)
        let sharp=settling.encode(partial,region:whole,color:"full",quality:0.7,motion:false,auto:true)
        precondition(sharp.count == 1 && sharp[0].codec == "png" && sharp[0].width == 1024 && sharp[0].height == 768,"Partial PNG updates must not cancel the pending full lossless refresh")
        let folder=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/portlight-encoder-validation",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try old[0].data.write(to:folder.appendingPathComponent("gray16-rgb-baseline.png"))
        try compact[0].data.write(to:folder.appendingPathComponent("gray16-packed4.png"))
        print("PASS: standard PNG4 grayscale, exact ImageIO-rendered gray pixels, odd dimensions/ROI offsets, unchanged suppression, byte-identical other modes, JPEG, Auto lossless settle")
    }
}
