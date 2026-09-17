// iOS app icon from the original Portlight mark (geometry from branding/render-icon.swift,
// Studio Upgrade, MIT). iOS applies its own mask, so the body gradient fills the whole square
// and the PNG is written without an alpha channel.
//   xcrun swift scripts/render-ios-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
}

let size = 1024
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
context.translateBy(x: 0, y: CGFloat(size)); context.scaleBy(x: 1, y: -1)
// The macOS artwork's 896-point body (inset 64) becomes the full-bleed iOS square.
let scale = CGFloat(size) / 896
context.scaleBy(x: scale, y: scale); context.translateBy(x: -64, y: -64)
NSGradient(colors: [color(0xFFC310), color(0xFF9D32), color(0xFF6238)])!.draw(in: NSRect(x: 64, y: 64, width: 896, height: 896), angle: 70)
color(0xFFFBEF, 0.5).setFill(); box(322, 266, 450, 330, 56).fill()
color(0xFFC310, 0.5).setFill(); box(348, 292, 398, 278, 34).fill()
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = color(0x930A3E, 0.23); shadow.shadowBlurRadius = 22 * scale
shadow.shadowOffset = NSSize(width: 0, height: -22 * scale); shadow.set()
NSGradient(colors: [color(0xFFFBEF), color(0xF7F1E8)])!.draw(in: box(218, 368, 494, 352, 56), angle: 60)
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [color(0xB9184B), color(0x6E133A)])!.draw(in: box(250, 400, 430, 232, 28), angle: 40)
NSGraphicsContext.saveGraphicsState(); box(250, 400, 430, 232, 28).addClip()
let light = NSBezierPath(); light.move(to: NSPoint(x: 250, y: 400)); light.line(to: NSPoint(x: 474, y: 400)); light.line(to: NSPoint(x: 250, y: 598)); light.close()
color(0xFFFFFF, 0.1).setFill(); light.fill(); NSGraphicsContext.restoreGraphicsState()
color(0x930A3E, 0.33).setFill(); box(421, 663, 88, 14, 7).fill()
let pointer = NSBezierPath(); pointer.move(to: NSPoint(x: 603, y: 562)); pointer.line(to: NSPoint(x: 789, y: 642)); pointer.line(to: NSPoint(x: 719, y: 672)); pointer.line(to: NSPoint(x: 675, y: 756)); pointer.close()
pointer.lineJoinStyle = .round; pointer.lineWidth = 18; color(0xFF8C32).setStroke(); pointer.stroke(); color(0xFFFBEF).setFill(); pointer.fill()
NSGraphicsContext.restoreGraphicsState()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("image") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("write") }
print("Wrote \(output.path)")
