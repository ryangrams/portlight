import AppKit
import ImageIO

final class MonitorCanvas: NSView {
    let monitorID: String
    var monitorName: String
    var pixelSize: CGSize
    var onPointer: ((String,Double,Double,String,Int,Double,Double)->Void)?
    var onKey: ((NSEvent,Bool)->Void)?
    var onFlags: ((NSEvent)->Void)?
    var onReleaseInput: (()->Void)?
    var onLocalPan: ((NSEvent)->Void)?
    var onEdge: ((NSPoint)->Void)?
    var viewOnly = false
    var remoteCursor: NSPoint? { didSet { needsDisplay = true } }
    private var surface: CGContext?
    private var tracking: NSTrackingArea?
    private var lastMoveTime: TimeInterval = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(monitor:RemoteMonitor,size:CGSize) {
        monitorID = monitor.id; monitorName = monitor.label; pixelSize = .zero
        super.init(frame:CGRect(origin:.zero,size:size))
        resetSurface(size)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func resetSurface(_ size:CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, size.width <= 3840, size.height <= 3840, validCanvasDimensions(width:Int(size.width),height:Int(size.height)) else { return }
        pixelSize = size
        surface = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:Int(size.width)*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
        surface?.setFillColor(NSColor(calibratedWhite:0.065,alpha:1).cgColor)
        surface?.fill(CGRect(origin:.zero,size:size)); needsDisplay = true
    }
    @discardableResult func applyTile(data:Data,x:Int,y:Int,width:Int,height:Int) -> Bool {
        guard surface != nil, validCanvasDimensions(width:Int(pixelSize.width),height:Int(pixelSize.height)), x >= 0, y >= 0, width > 0, height > 0, x < Int(pixelSize.width), y < Int(pixelSize.height), width <= Int(pixelSize.width), height <= Int(pixelSize.height), x + width <= Int(pixelSize.width), y + height <= Int(pixelSize.height), data.count <= 20_000_000 else { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any], properties[kCGImagePropertyPixelWidth] as? Int == width, properties[kCGImagePropertyPixelHeight] as? Int == height, let cg = CGImageSourceCreateImageAtIndex(source,0,nil) else { return false }
        surface?.saveGState()
        surface?.translateBy(x:0,y:pixelSize.height)
        surface?.scaleBy(x:1,y:-1)
        // NSImage-backed images use a bottom-up CG image. Flip the tile inside the top-left frame coordinates.
        surface?.translateBy(x:CGFloat(x),y:CGFloat(y + height))
        surface?.scaleBy(x:1,y:-1)
        surface?.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        surface?.restoreGState()
        needsDisplay = true
        return true
    }
    func demoImage(_ number:Int) {
        guard let surface else { return }
        let w = pixelSize.width, h = pixelSize.height
        surface.setFillColor(NSColor(calibratedRed:0.06,green:0.08,blue:0.11,alpha:1).cgColor); surface.fill(CGRect(x:0,y:0,width:w,height:h))
        surface.setFillColor(NSColor(calibratedRed:0.12,green:0.18,blue:0.22,alpha:1).cgColor); surface.fill(CGRect(x:20,y:h-90,width:w-40,height:62))
        let ns = NSGraphicsContext(cgContext:surface,flipped:false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        ("Monitor \(number) · Studio preview" as NSString).draw(at:NSPoint(x:40,y:h-74),withAttributes:[.font:NSFont.systemFont(ofSize:24,weight:.semibold),.foregroundColor:NSColor.white])
        ("Only selected screens stream. Switch, zoom, or choose HD to save bandwidth." as NSString).draw(at:NSPoint(x:40,y:h-118),withAttributes:[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.lightGray])
        for row in 0..<5 { for col in 0..<4 {
            let rect = CGRect(x:40+CGFloat(col)*(w-100)/4,y:60+CGFloat(row)*(h-230)/5,width:(w-140)/4,height:(h-270)/5)
            let colors:[NSColor] = [.systemTeal,.systemBlue,.systemOrange,.systemPurple]
            surface.setFillColor(colors[(col+row+number)%4].withAlphaComponent(0.22).cgColor); surface.fill(rect)
            ("\(["CAMERA","AUDIO","PLAYBACK","OUTPUT"][col]) \(row+1)" as NSString).draw(at:NSPoint(x:rect.minX+12,y:rect.minY+16),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.medium),.foregroundColor:NSColor.white])
        } }
        NSGraphicsContext.restoreGraphicsState(); needsDisplay = true
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.06,alpha:1).setFill(); bounds.fill()
        guard let image = surface?.makeImage(), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.interpolationQuality = .high
        context.translateBy(x:0,y:bounds.height); context.scaleBy(x:1,y:-1)
        context.draw(image,in:bounds); context.restoreGState()
        if let cursor = remoteCursor {
            let cursorImage = NSCursor.arrow.image
            cursorImage.draw(in:CGRect(x:cursor.x*bounds.width,y:cursor.y*bounds.height,width:cursorImage.size.width,height:cursorImage.size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        if window?.firstResponder === self { NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke(); NSBezierPath(rect:bounds.insetBy(dx:1,dy:1)).stroke() }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:.zero,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect,.mouseEnteredAndExited],owner:self,userInfo:nil)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    private func pointer(_ event:NSEvent,_ action:String,_ button:Int = 0) {
        let point = convert(event.locationInWindow,from:nil)
        if action == "move" { onEdge?(event.locationInWindow) }
        guard !viewOnly else { return }
        if action == "move" { let now = ProcessInfo.processInfo.systemUptime; if now-lastMoveTime < 1.0/90 { return }; lastMoveTime = now }
        onPointer?(monitorID,clamp(point.x/max(1,bounds.width),0,1),clamp(point.y/max(1,bounds.height),0,1),action,button,0,0)
    }
    override func mouseMoved(with event:NSEvent) { pointer(event,"move") }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self); pointer(event,"down",1) }
    override func mouseUp(with event:NSEvent) { pointer(event,"up",1) }
    override func rightMouseDown(with event:NSEvent) { window?.makeFirstResponder(self); pointer(event,"down",2) }
    override func rightMouseUp(with event:NSEvent) { pointer(event,"up",2) }
    override func otherMouseDown(with event:NSEvent) { window?.makeFirstResponder(self); pointer(event,"down",3) }
    override func otherMouseUp(with event:NSEvent) { pointer(event,"up",3) }
    override func mouseDragged(with event:NSEvent) { pointer(event,"move") }
    override func rightMouseDragged(with event:NSEvent) { pointer(event,"move") }
    override func otherMouseDragged(with event:NSEvent) { pointer(event,"move") }
    override func scrollWheel(with event:NSEvent) {
        if event.modifierFlags.contains(.option) { onLocalPan?(event); return }
        guard !viewOnly else { return }
        let point = convert(event.locationInWindow,from:nil)
        onPointer?(monitorID,clamp(point.x/max(1,bounds.width),0,1),clamp(point.y/max(1,bounds.height),0,1),"scroll",0,Double(event.scrollingDeltaX),Double(event.scrollingDeltaY))
    }
    override func resignFirstResponder() -> Bool { onReleaseInput?(); needsDisplay = true; return super.resignFirstResponder() }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if window?.firstResponder === self && event.modifierFlags.contains(.command) && !viewOnly { onKey?(event,true); return true }; return super.performKeyEquivalent(with:event)
    }
    override func keyDown(with event:NSEvent) { if !viewOnly { onKey?(event,true) } }
    override func keyUp(with event:NSEvent) { if !viewOnly { onKey?(event,false) } }
    override func flagsChanged(with event:NSEvent) { if !viewOnly { onFlags?(event) } }
}

final class DesktopView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect:NSRect) { NSColor(calibratedWhite:0.045,alpha:1).setFill(); dirtyRect.fill() }
}
