// Original Portlight mark, Studio Upgrade. The editable SVG is the design master.
// Re-render the simple vector geometry at each icon size; no source bitmap needed.
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "branding", isDirectory:true)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
func color(_ hex:UInt32,_ alpha:CGFloat = 1) -> NSColor {
    NSColor(srgbRed:CGFloat((hex >> 16) & 255)/255,green:CGFloat((hex >> 8) & 255)/255,blue:CGFloat(hex & 255)/255,alpha:alpha)
}
func box(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ radius:CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect:NSRect(x:x,y:y,width:w,height:h),xRadius:radius,yRadius:radius)
}
func draw(_ size:Int) -> Data {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32)!
    let context=NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    context.cgContext.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    context.cgContext.translateBy(x:0,y:1024);context.cgContext.scaleBy(x:1,y:-1)
    context.shouldAntialias=true
    let body=box(64,64,896,896,202)
    NSGradient(colors:[color(0xFFC310),color(0xFF9D32),color(0xFF6238)])!.draw(in:body,angle:70)
    color(0xFFF8DF,0.5).setStroke();let highlight=box(66,66,892,892,200);highlight.lineWidth=4;highlight.stroke()
    color(0xFFFBEF,0.5).setFill();box(322,266,450,330,56).fill()
    color(0xFFC310,0.5).setFill();box(348,292,398,278,34).fill()
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow();shadow.shadowColor=color(0x930A3E,0.23);shadow.shadowBlurRadius=22;shadow.shadowOffset=NSSize(width:0,height:-22);shadow.set()
    NSGradient(colors:[color(0xFFFBEF),color(0xF7F1E8)])!.draw(in:box(218,368,494,352,56),angle:60)
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors:[color(0xB9184B),color(0x6E133A)])!.draw(in:box(250,400,430,232,28),angle:40)
    NSGraphicsContext.saveGraphicsState();box(250,400,430,232,28).addClip()
    let light=NSBezierPath();light.move(to:NSPoint(x:250,y:400));light.line(to:NSPoint(x:474,y:400));light.line(to:NSPoint(x:250,y:598));light.close();color(0xFFFFFF,0.1).setFill();light.fill();NSGraphicsContext.restoreGraphicsState()
    color(0x930A3E,0.33).setFill();box(421,663,88,14,7).fill()
    let pointer=NSBezierPath();pointer.move(to:NSPoint(x:603,y:562));pointer.line(to:NSPoint(x:789,y:642));pointer.line(to:NSPoint(x:719,y:672));pointer.line(to:NSPoint(x:675,y:756));pointer.close();pointer.lineJoinStyle = .round;pointer.lineWidth=18;color(0xFF8C32).setStroke();pointer.stroke();color(0xFFFBEF).setFill();pointer.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
let iconset=directory.appendingPathComponent("Portlight.iconset",isDirectory:true)
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
var sizes:[Int:Data]=[:]
for size in [16,24,32,48,64,128,256,512,1024] {sizes[size]=draw(size)}
try sizes[1024]!.write(to:directory.appendingPathComponent("Portlight.png"))
for size in [16,32,128,256,512] {
    try sizes[size]!.write(to:iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try sizes[size*2]!.write(to:iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
func le16(_ n:Int) -> Data {Data([UInt8(n & 255),UInt8((n >> 8) & 255)])}
func le32(_ n:Int) -> Data {Data([UInt8(n & 255),UInt8((n >> 8) & 255),UInt8((n >> 16) & 255),UInt8((n >> 24) & 255)])}
let icoSizes=[16,24,32,48,64,128,256]
var ico=le16(0)+le16(1)+le16(icoSizes.count),offset=6+16*icoSizes.count
for size in icoSizes {
    let png=sizes[size]!
    ico.append(Data([UInt8(size & 255),UInt8(size & 255),0,0]));ico.append(le16(1));ico.append(le16(32));ico.append(le32(png.count));ico.append(le32(offset));offset+=png.count
}
for size in icoSizes {ico.append(sizes[size]!)}
try ico.write(to:directory.appendingPathComponent("Portlight.ico"))
print("Rendered Portlight PNG, iconset, and multi-resolution Windows icon.")
