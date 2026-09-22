import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
do {
    try popupComposerSelfTest()
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
        let composer = PopupComposerController(defaults: nil)
        composer.configure(connected: true, capability: ["maxCharacters": 250, "maxDurationSeconds": 10800, "richText": true, "targetDisplays": true])
        composer.setDisplays([ViewerPopupDisplay(id: "one", name: "Main display", index: 1), ViewerPopupDisplay(id: "two", name: "Studio display", index: 2)], selected: ["one"])
        let sample = NSMutableAttributedString(string: "Please look at the camera.\nWe are live in 20 seconds.", attributes: ViewerPopupText.attributes)
        sample.addAttributes([.foregroundColor: NSColor.systemYellow, .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 19, length: 6))
        composer.setDraft(sample)
        composer.window?.appearance = NSAppearance(named: .aqua)
        composer.showWindow(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let content = composer.window?.contentView?.superview {
            content.layoutSubtreeIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            }
        }
        composer.close()
    }
} catch {
    fputs("FAIL \(error.localizedDescription)\n", stderr)
    exit(1)
}
