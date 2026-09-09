import AppKit
import Foundation
import CoreText
import Darwin

struct Sample {
    let metrics: EncodingMetrics
    let bytes: Int
    let tiles: Int
}
func cpuTime() -> Double {
    var value=rusage();getrusage(RUSAGE_SELF,&value)
    return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1_000_000
}
func median(_ values: [Double]) -> Double { let sorted=values.sorted();return sorted.isEmpty ? 0 : sorted[sorted.count/2] }
func percentile(_ values: [Double],_ p:Double) -> Double { let sorted=values.sorted();return sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count-1)*p))] }
func workload(_ name:String,_ index:Int,_ width:Int,_ height:Int) -> CGImage {
    let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    if name == "text_ui" || name == "static_ui" {
        ctx.setFillColor(CGColor(red:0.055,green:0.07,blue:0.09,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:height))
        ctx.setFillColor(CGColor(red:0.12,green:0.15,blue:0.19,alpha:1));ctx.fill(CGRect(x:0,y:height-72,width:width,height:72))
        let font=CTFontCreateWithName("Menlo" as CFString,CGFloat(width)/100,nil)
        let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.9,alpha:1)]
        for row in 0..<12 {
            for col in 0..<4 {
                let x=30+col*(width/4),y=height-120-row*(height/15)
                ctx.setFillColor(CGColor(red:CGFloat(col+1)*0.05,green:0.18,blue:CGFloat(row%3)*0.05+0.12,alpha:1));ctx.fill(CGRect(x:x-5,y:y-7,width:width/4-40,height:height/20))
                ctx.textPosition=CGPoint(x:x,y:y)
                let value=row == 4 && col == 1 ? index : row*17+col
                let string=NSAttributedString(string:String(format:"CH %02d  %03d  %.1f",row+col*12,value,Double(value)/10),attributes:attributes)
                CTLineDraw(CTLineCreateWithAttributedString(string),ctx)
            }
        }
        ctx.setFillColor(CGColor(red:0.2,green:0.85,blue:0.65,alpha:1));ctx.fill(CGRect(x:30+index*11,y:20,width:width/7,height:18))
    } else {
        let bytes=ctx.data!.assumingMemoryBound(to:UInt8.self)
        var rng:UInt32=0x12345678 ^ UInt32(index*7919)
        for y in 0..<height { for x in 0..<width {
            let offset=(y*width+x)*4
            if name == "noise" {
                rng ^= rng<<13;rng ^= rng>>17;rng ^= rng<<5
                bytes[offset]=UInt8(truncatingIfNeeded:rng);bytes[offset+1]=UInt8(truncatingIfNeeded:rng>>8);bytes[offset+2]=UInt8(truncatingIfNeeded:rng>>16)
            } else if name == "gradients" {
                bytes[offset]=UInt8((x*255/width+index*3)%256)
                bytes[offset+1]=UInt8((y*255/height+index*2)%256)
                bytes[offset+2]=UInt8(((x+y)*255/(width+height)+index)%256)
            } else {
                let sx=(x+index*17)%width,sy=(y+index*7)%height
                bytes[offset]=UInt8((sx/23+sy/31)%2 == 0 ? 220 : 32)
                bytes[offset+1]=UInt8((sx*255/width+sy*127/height)%256)
                bytes[offset+2]=UInt8((sx/41+sy/17+index)%3 == 0 ? 170 : 58)
            }
            bytes[offset+3]=255
        } }
    }
    return ctx.makeImage()!
}
