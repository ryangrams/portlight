import AppKit

// Layout uses the host's logical points. Pixel resolution only controls image detail.
func displayLayout(_ monitors:[RemoteMonitor],compact:Bool) -> [String:CGRect] {
    guard !monitors.isEmpty else { return [:] }
    var frames = monitors.map(\.logicalFrame)
    if compact {
        func gaps(_ intervals:[(CGFloat,CGFloat)]) -> [(CGFloat,CGFloat)] {
            let sorted = intervals.sorted { $0.0 < $1.0 }; var result:[(CGFloat,CGFloat)] = []
            var end = sorted[0].1
            for interval in sorted.dropFirst() { if interval.0 > end { result.append((end,interval.0)) }; end = max(end,interval.1) }
            return result
        }
        let horizontal = gaps(frames.map { ($0.minX,$0.maxX) }), vertical = gaps(frames.map { ($0.minY,$0.maxY) })
        frames = frames.map { rect in
            var r = rect
            r.origin.x -= horizontal.filter { $0.1 <= rect.minX }.reduce(0) { $0+$1.1-$1.0 }
            r.origin.y -= vertical.filter { $0.1 <= rect.minY }.reduce(0) { $0+$1.1-$1.0 }
            return r
        }
    }
    let union = frames.reduce(CGRect.null) { $0.union($1) }
    return Dictionary(uniqueKeysWithValues:zip(monitors,frames).map { ($0.0.id,$0.1.offsetBy(dx:-union.minX,dy:-union.minY)) })
}

final class DisplayMap: NSView {
    var monitors:[RemoteMonitor] = [] { didSet { rebuild() } }
    var selected:Set<String> = [] { didSet { rebuild() } }
    var expanded = false
    var onToggle:((String)->Void)?
    var onExpand:(()->Void)?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    private var buttons:[NSButton] = []
    var needsExpansion:Bool {
        let frames = displayLayout(monitors,compact:false)
        let union = frames.values.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return false }
        let scale = min(max(1,bounds.width-8)/max(1,union.width),max(1,bounds.height-8)/max(1,union.height))
        return frames.values.contains { $0.width*scale < 28 || $0.height*scale < 20 }
    }
    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }; buttons = []
        for monitor in monitors {
            let b = NSButton(title:String(monitor.number),target:self,action:#selector(toggle(_:)))
            b.identifier = .init(monitor.id); b.setButtonType(.toggle); b.bezelStyle = .regularSquare
            b.state = selected.contains(monitor.id) ? .on : .off
            b.bezelColor = selected.contains(monitor.id) ? .controlAccentColor : .black
            b.contentTintColor = selected.contains(monitor.id) ? .white : .secondaryLabelColor
            b.font = .systemFont(ofSize:11,weight:.semibold)
            b.toolTip = "\(monitor.label) · \(Int(monitor.logicalFrame.width)) × \(Int(monitor.logicalFrame.height)) points · \(selected.contains(monitor.id) ? "Active" : "Inactive")"
            b.setAccessibilityLabel(monitor.label); b.setAccessibilityValue(selected.contains(monitor.id) ? "Active" : "Inactive")
            addSubview(b); buttons.append(b)
        }
        needsLayout = true
    }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        guard !expanded && needsExpansion else { return }
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:5,yRadius:5).fill()
        NSImage(systemSymbolName:"display.2",accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[NSColor.labelColor]))?.draw(in:NSRect(x:8,y:(bounds.height-18)/2,width:24,height:18))
        let text = "Displays (\(selected.count)) ▾"
        text.draw(at:NSPoint(x:38,y:(bounds.height-14)/2),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.labelColor])
    }
    override func layout() {
        super.layout()
        let frames = displayLayout(monitors,compact:false), union = displayLayout(monitors,compact:false).values.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return }
        let scale = min(max(1,bounds.width-8)/max(1,union.width),max(1,bounds.height-8)/max(1,union.height))
        let origin = CGPoint(x:(bounds.width-union.width*scale)/2,y:(bounds.height-union.height*scale)/2)
        for b in buttons {
            guard let id = b.identifier?.rawValue, let rect = frames[id] else { continue }
            b.frame = CGRect(x:origin.x+rect.minX*scale+1,y:origin.y+rect.minY*scale+1,width:max(1,rect.width*scale-2),height:max(1,rect.height*scale-2))
            b.isEnabled = expanded || !needsExpansion; b.isHidden = !expanded && needsExpansion
        }
        needsDisplay = true
        setAccessibilityElement(!expanded && needsExpansion); setAccessibilityLabel("Expand display map"); setAccessibilityRole(.button)
        toolTip = needsExpansion && !expanded ? "Click to expand the display map" : "Activate the displays you want to view"
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        if !expanded && needsExpansion { return frame.contains(point) ? self : nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event:NSEvent) { onExpand?() }
    override func keyDown(with event:NSEvent) { if [36,49].contains(event.keyCode) { onExpand?() } else { super.keyDown(with:event) } }
    @objc private func toggle(_ sender:NSButton) { if let id = sender.identifier?.rawValue { onToggle?(id) } }
}

func resolutionGridIcon(_ side:Int) -> NSImage {
    NSImage(size:NSSize(width:22,height:22),flipped:false) { rect in
        NSColor.labelColor.setFill()
        let cell = CGFloat(20)/CGFloat(side), inset:CGFloat = 0.7
        for y in 0..<side { for x in 0..<side {
            NSBezierPath(roundedRect:CGRect(x:1+CGFloat(x)*cell+inset,y:1+CGFloat(y)*cell+inset,width:cell-inset*2,height:cell-inset*2),xRadius:0.5,yRadius:0.5).fill()
        } }
        return true
    }
}

func colorModeIcon(_ mode:Int) -> NSImage {
    NSImage(size:NSSize(width:22,height:22),flipped:false) { rect in
        if mode == 0 {
            let colors = (0...6).map { NSColor(calibratedHue:CGFloat($0)/6,saturation:0.9,brightness:0.95,alpha:1) }
            NSGradient(colors:colors)?.draw(in:rect,angle:0)
        } else if mode == 1 {
            for y in 0..<4 { for x in 0..<4 {
                NSColor(calibratedHue:CGFloat(x)/4,saturation:CGFloat(y+1)/4,brightness:y == 0 ? 0.65 : 0.95,alpha:1).setFill()
                NSRect(x:CGFloat(x)*5.5,y:CGFloat(y)*5.5,width:5,height:5).fill()
            } }
        } else {
            for x in 0..<4 { NSColor(calibratedWhite:CGFloat(x)/3,alpha:1).setFill(); NSRect(x:CGFloat(x)*5.5,y:0,width:4.5,height:22).fill() }
        }
        return true
    }
}

final class SessionWindow: NSWindow {
    override func sendEvent(_ event:NSEvent) {
        if event.type == .rightMouseDown, let toolbar, event.locationInWindow.y >= contentLayoutRect.maxY, let view = contentView {
            let menu = NSMenu()
            for (title,mode) in [("Icons",NSToolbar.DisplayMode.iconOnly),("Icons and Text",NSToolbar.DisplayMode.iconAndLabel)] {
                let item = NSMenuItem(title:title,action:#selector(toolbarAppearance(_:)),keyEquivalent:""); item.target = self; item.tag = Int(mode.rawValue); item.state = toolbar.displayMode == mode ? .on : .off; menu.addItem(item)
            }
            menu.addItem(.separator())
            let customize = NSMenuItem(title:"Customize Toolbar…",action:#selector(customizeToolbar),keyEquivalent:""); customize.target = self; menu.addItem(customize)
            NSMenu.popUpContextMenu(menu,with:event,for:view); return
        }
        super.sendEvent(event)
    }
    @objc private func toolbarAppearance(_ sender:NSMenuItem) {
        toolbar?.displayMode = NSToolbar.DisplayMode(rawValue:UInt(sender.tag)) ?? .iconOnly
        toolbarStyle = toolbar?.displayMode == .iconAndLabel ? .expanded : .unifiedCompact
        UserDefaults.standard.set(sender.tag,forKey:"Portlight.Toolbar.DisplayMode")
    }
    @objc private func customizeToolbar() { toolbar?.runCustomizationPalette(nil) }
}

// Preserve native segment tracking and accessibility, with an explicit selection outline.
final class ActiveSegmentedControl: NSSegmentedControl {
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        guard selectedSegment >= 0, selectedSegment < segmentCount else { return }
        let total = (0..<segmentCount).reduce(CGFloat(0)) { $0 + width(forSegment:$1) }
        guard total > 0 else { return }
        let leading = (0..<selectedSegment).reduce(CGFloat(0)) { $0 + width(forSegment:$1) }
        let rect = NSRect(x:bounds.minX+bounds.width*leading/total,y:bounds.minY,width:bounds.width*width(forSegment:selectedSegment)/total,height:bounds.height).insetBy(dx:1.5,dy:1.5)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect:rect,xRadius:5,yRadius:5); outline.lineWidth = 2; outline.stroke()
    }
}
