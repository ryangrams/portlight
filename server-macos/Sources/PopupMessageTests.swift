import AppKit
import Foundation

private struct PopupMessageTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func popupCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PopupMessageTestFailure(message: message) }
}

private func popupObject(_ text: String = "Ready", duration: Any = 20, runs: Any? = nil) -> [String: Any] {
    var object: [String: Any] = ["text": text, "durationSeconds": duration]
    if let runs { object["runs"] = runs }
    return object
}

private func popupRejects(_ object: [String: Any], _ label: String) throws {
    do {
        _ = try PopupMessage(object)
    } catch is PopupMessageFailure {
        return
    }
    throw PopupMessageTestFailure(message: "Popup parser accepted \(label).")
}

private func popupVerifyLayout(_ message: PopupMessage, screen: CGSize, label: String) throws -> PopupMessageLayout {
    let layout = PopupMessageLayout.fit(message, screenSize: screen)
    let innerWidth = layout.size.width - layout.horizontalPadding * 2
    let innerHeight = layout.size.height - layout.verticalPadding * 2
    let text = PopupTextLayout(message: message, fontSize: layout.fontSize, width: innerWidth)
    let glyphs = text.manager.glyphRange(for: text.container)
    try popupCheck(layout.size.width == screen.width, "\(label): banner does not span the screen.")
    try popupCheck(layout.size.height >= screen.height * 0.15 - 0.01, "\(label): banner is below 15% height.")
    try popupCheck(layout.size.height <= screen.height * 0.35 + 0.01, "\(label): banner exceeds 35% height.")
    try popupCheck(layout.fontSize.isFinite && layout.fontSize > 0, "\(label): invalid font size.")
    try popupCheck(text.bounds.width <= innerWidth + 0.02, "\(label): text exceeds the available width.")
    try popupCheck(text.bounds.height <= innerHeight + 0.02, "\(label): text exceeds the available height.")
    try popupCheck(glyphs.location == 0 && glyphs.length == text.manager.numberOfGlyphs,
                   "\(label): some glyphs are outside the text container.")
    let characters = text.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    try popupCheck(characters.location == 0 && characters.length == message.text.utf16.count,
                   "\(label): some characters are absent from the layout.")
    let larger = PopupTextLayout(message: message, fontSize: layout.fontSize + 0.1, width: innerWidth)
    try popupCheck(larger.bounds.height > innerHeight || larger.bounds.width > innerWidth + 0.01,
                   "\(label): text could be larger within the chosen banner.")
    return layout
}

func popupMessageSelfTest() throws {
    for text in ["A", String(repeating: "W", count: 250), String(repeating: "😀", count: 250),
                 "e\u{301}", "👩‍💻", "First\nSecond\tThird", "مرحباً بكم", "准备开始"] {
        let message = try PopupMessage(popupObject(text))
        try popupCheck(message.text == text, "Popup parser changed valid text.")
    }
    for text in ["", " \t\n", String(repeating: "a", count: 251), String(repeating: "😀", count: 251),
                 String(repeating: "e\u{301}", count: 126)] {
        try popupRejects(popupObject(text), "empty or excessive text")
    }
    for scalar in [UInt32(0), 1, 8, 11, 12, 13, 31, 127, 0x061C, 0x200E, 0x200F,
                   0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
        let text = "A" + String(UnicodeScalar(scalar)!) + "B"
        try popupRejects(popupObject(text), "control U+\(String(scalar, radix: 16))")
    }
    try popupRejects(["durationSeconds": 20], "missing text")
    try popupRejects(["text": 123, "durationSeconds": 20], "numeric text")
    try popupRejects(["text": NSNull(), "durationSeconds": 20], "null text")
    try popupRejects(["text": "Ready"], "missing duration")
    for duration in [0, 1, 20, PopupMessage.maxDuration] {
        let message = try PopupMessage(popupObject(duration: duration))
        try popupCheck(message.durationSeconds == duration, "Popup parser changed a valid duration.")
    }
    let invalidDurations: [Any] = [-1, 10_801, 1.5, true, false, "20", NSNull(), Double.nan,
                                  Double.infinity, Double(Int32.max) + 1, [20]]
    for duration in invalidDurations {
        try popupRejects(popupObject(duration: duration), "invalid duration \(String(describing: duration))")
    }
    try popupCheck(PopupMessage.integer(NSNumber(value: 20)) == 20, "Integer parsing rejected NSNumber.")
    try popupCheck(PopupMessage.integer(NSNumber(value: true)) == nil, "Integer parsing accepted a Boolean.")

    let formatted = try PopupMessage(popupObject("A😀B", runs: [
        ["start": 0, "length": 1],
        ["start": 1, "length": 2, "color": "#aAbBcC", "underline": true],
        ["start": 3, "length": 1, "color": "#00FF00", "underline": false]
    ]))
    try popupCheck(formatted.runs.count == 3 && formatted.runs[1].color == "#AABBCC", "Formatting normalization failed.")
    try popupCheck(formatted.runs[0].color == "#FFFFFF" && !formatted.runs[0].underline, "Formatting defaults changed.")
    let invalidCollections: [Any] = [NSNull(), "bold", [1], ["start": 0, "length": 1],
                                     Array(repeating: ["start": 0, "length": 1], count: 251)]
    for runs in invalidCollections {
        try popupRejects(popupObject(runs: runs), "invalid formatting collection")
    }
    let invalidRuns: [[String: Any]] = [
        ["length": 1], ["start": 0], ["start": -1, "length": 1],
        ["start": 0, "length": 0], ["start": 0, "length": -1],
        ["start": 0.5, "length": 1], ["start": 0, "length": 1.5],
        ["start": true, "length": 1], ["start": 0, "length": true],
        ["start": "0", "length": 1], ["start": 0, "length": NSNull()],
        ["start": 5, "length": 1], ["start": 0, "length": 5],
        ["start": Int32.max, "length": Int32.max],
        ["start": 2, "length": 1], ["start": 1, "length": 1],
        ["start": 0, "length": 1, "color": "red"],
        ["start": 0, "length": 1, "color": "#FFFFFG"],
        ["start": 0, "length": 1, "color": "#FFFFFF00"],
        ["start": 0, "length": 1, "color": "#ＦFFFFF"],
        ["start": 0, "length": 1, "color": 123],
        ["start": 0, "length": 1, "underline": 1],
        ["start": 0, "length": 1, "underline": "true"],
        ["start": 0, "length": 1, "underline": NSNull()]
    ]
    for run in invalidRuns { try popupRejects(popupObject("A😀B", runs: [run]), "invalid formatting run") }
    try popupRejects(popupObject("Ready", runs: [["start": 0, "length": 3], ["start": 2, "length": 2]]), "overlapping runs")
    try popupRejects(popupObject("Ready", runs: [["start": 3, "length": 1], ["start": 0, "length": 1]]), "unsorted runs")
    let attributed = formatted.attributedText(fontSize: 48)
    let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    try popupCheck(font?.fontName == "Helvetica-Bold" && font?.pointSize == 48, "The banner font must be Helvetica-Bold.")
    let white = (attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    try popupCheck(white != nil && abs(white!.redComponent - 1) < 0.001 && abs(white!.alphaComponent - 1) < 0.001, "Default text must be opaque white.")
    let color = (attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    try popupCheck(color != nil && abs(color!.redComponent - 170.0 / 255) < 0.001 &&
                   abs(color!.greenComponent - 187.0 / 255) < 0.001 && abs(color!.blueComponent - 204.0 / 255) < 0.001 &&
                   abs(color!.alphaComponent - 1) < 0.001, "Selected text color was not preserved.")
    try popupCheck((attributed.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue,
                   "Selected text lost its underline.")
    try popupCheck((attributed.attribute(.underlineStyle, at: 3, effectiveRange: nil) as? Int) == 0,
                   "Underline escaped its selected text.")

    var now = Date(timeIntervalSince1970: 1_000_000)
    var continuousNow: TimeInterval = 1_000
    let controller = PopupMessageController(fixture: true, defaults: nil, now: { now }, continuousNow: { continuousNow })
    defer { controller.clear() }
    try popupCheck(!controller.active && controller.expiresAt == nil, "Messages must start cleared.")
    try popupCheck(controller.selectedIDs.count == 1, "Exactly one display must be selected by default.")
    let initiallySelected = controller.selectedIDs.first!
    try popupCheck(!controller.toggleDisplay(initiallySelected) && controller.selectedIDs.count == 1,
                   "The last display can be unchecked.")
    let additional = controller.displays.first { $0.id != initiallySelected }!.id
    try popupCheck(controller.toggleDisplay(additional) && controller.selectedIDs.count == 2, "A second display cannot be selected.")
    try popupCheck(controller.toggleDisplay(initiallySelected) && controller.selectedIDs == Set([additional]), "Display selection did not change.")
    try popupCheck(!controller.toggleDisplay("missing-screen"), "An unknown display was accepted.")
    for invalid in [[], ["missing-screen"], [additional, additional]] {
        do {
            _ = try controller.selectDisplays(invalid)
            throw PopupMessageTestFailure(message: "An invalid remote screen selection was accepted.")
        } catch is PopupMessageFailure {}
        try popupCheck(controller.selectedIDs == Set([additional]), "Invalid screen selection changed the target.")
    }
    controller.show(try PopupMessage(popupObject("Move this message", duration: 20)))
    let originalExpiry = controller.expiresAt
    let selectionChanged = try controller.selectDisplays([initiallySelected, additional])
    try popupCheck(selectionChanged && controller.selectedIDs.count == 2, "Remote screen selection did not apply.")
    try popupCheck(controller.active && controller.expiresAt == originalExpiry, "Screen selection restarted the message timer.")
    let selectionUnchanged = try controller.selectDisplays([additional, initiallySelected])
    try popupCheck(!selectionUnchanged, "Reordering the same screen selection changed state.")
    controller.clear()
    let primary = DisplayInfo(id: "primary", cgID: CGMainDisplayID(), name: "Primary", index: 1,
                              width: 1920, height: 1080, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let secondary = DisplayInfo(id: "secondary", cgID: UInt32.max, name: "Secondary", index: 2,
                                width: 1080, height: 1920, bounds: CGRect(x: -1080, y: 0, width: 1080, height: 1920))
    controller.refreshDisplays([secondary, primary])
    try popupCheck(controller.selectedIDs == Set([primary.id]), "Hotplug fallback did not select the main display.")
    _ = controller.toggleDisplay(secondary.id)
    controller.refreshDisplays([secondary])
    try popupCheck(controller.selectedIDs == Set([secondary.id]), "Removing one selected display lost the remaining selection.")
    controller.refreshDisplays([])
    try popupCheck(controller.selectedIDs.isEmpty, "Disconnected displays remained selected.")
    controller.refreshDisplays([primary])
    try popupCheck(controller.selectedIDs == Set([primary.id]), "Selection did not recover after all displays disappeared.")
    controller.show(try PopupMessage(popupObject("Sticky", duration: 0)))
    var repeatedScreenChanges = 0
    controller.onChange = { repeatedScreenChanges += 1 }
    for _ in 0..<100 { controller.refreshDisplays([primary]) }
    try popupCheck(repeatedScreenChanges == 0, "Unchanged screen notifications recreated the message.")
    controller.onChange = nil
    try popupCheck(controller.active && controller.expiresAt == now.addingTimeInterval(10_800), "Sticky message has no three-hour deadline.")
    now.addTimeInterval(10_799)
    controller.expireIfNeeded()
    try popupCheck(controller.active, "Sticky message expired early.")
    now.addTimeInterval(1)
    controller.expireIfNeeded()
    try popupCheck(!controller.active && controller.expiresAt == nil, "Sticky message survived three hours.")
    controller.show(try PopupMessage(popupObject("First", duration: 20)))
    now.addTimeInterval(19)
    controller.expireIfNeeded()
    try popupCheck(controller.active, "Timed message expired early.")
    controller.show(try PopupMessage(popupObject("Replacement", duration: 60)))
    now.addTimeInterval(1)
    controller.expireIfNeeded()
    try popupCheck(controller.message?.text == "Replacement", "The previous expiry cleared its replacement.")
    now.addTimeInterval(59)
    controller.expireIfNeeded()
    try popupCheck(!controller.active, "Timed message survived its deadline.")
    controller.show(try PopupMessage(popupObject("Manual clear", duration: 0)))
    controller.clear()
    try popupCheck(!controller.active && controller.message == nil && controller.expiresAt == nil, "Manual clear left message state behind.")
    try popupCheck(controller.state["active"] as? Bool == false && controller.state["expiresAt"] as? Double == 0,
                   "Cleared message state is inconsistent.")
    controller.show(try PopupMessage(popupObject("Wake after expiry", duration: 20)))
    now.addTimeInterval(300)
    controller.expireIfNeeded()
    try popupCheck(!controller.active, "A message survived a clock advance past its expiry.")
    controller.show(try PopupMessage(popupObject("Clock moved backwards", duration: 0)))
    now.addTimeInterval(-86_400)
    continuousNow += 10_799
    controller.expireIfNeeded()
    try popupCheck(controller.active, "The continuous clock expired a sticky message early.")
    continuousNow += 1
    controller.expireIfNeeded()
    try popupCheck(!controller.active, "Moving the wall clock backwards extended the three-hour lifetime.")

    let samples = ["Ready", String(repeating: "W", count: 250), String(repeating: "Go live now. ", count: 19),
                   "First line\nSecond line\nThird line\n", String(repeating: "准备开始请看镜头", count: 25),
                   String(repeating: "😀👩‍💻 ", count: 40), "مرحباً بكم في البث المباشر"]
    for screen in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920),
                   CGSize(width: 640, height: 480), CGSize(width: 3840, height: 2160)] {
        for (index, text) in samples.enumerated() {
            _ = try popupVerifyLayout(PopupMessage(popupObject(text)), screen: screen, label: "\(Int(screen.width))×\(Int(screen.height)) sample \(index)")
        }
    }
    let screen = CGSize(width: 1920, height: 1080)
    let short = PopupMessageLayout.fit(try PopupMessage(popupObject("Ready")), screenSize: screen)
    let overlay = PopupMessagePanel(rect: CGRect(origin: .zero, size: short.size), message: try PopupMessage(popupObject("Ready")), layout: short)
    try popupCheck(overlay.ignoresMouseEvents, "The message overlay must pass mouse input through.")
    try popupCheck(!overlay.canBecomeKey && !overlay.canBecomeMain, "The message overlay must not take keyboard focus.")
    try popupCheck(overlay.level.rawValue > Int(CGWindowLevelForKey(.screenSaverWindow)), "The message overlay must stay above app and fullscreen windows.")
    try popupCheck(overlay.collectionBehavior.contains(.canJoinAllSpaces) && overlay.collectionBehavior.contains(.fullScreenAuxiliary), "The message overlay must follow Spaces and fullscreen apps.")
    overlay.close()
    let long = PopupMessageLayout.fit(try PopupMessage(popupObject(String(repeating: "W", count: 250))), screenSize: screen)
    try popupCheck(short.size.height < long.size.height, "Short and long messages always use the same banner height.")
    try popupCheck(short.size.height <= screen.height * 0.16, "A short message exceeds the intended minimum banner height.")
    print("PASS: popup parsing, Unicode limits, rich text, expiry, replacement, display selection, hotplug fallback, and text fitting")
}

private func popupBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let bytes = bitmap.bitmapData else {
        throw PopupMessageTestFailure(message: "Could not allocate a popup snapshot.")
    }
    bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    return bitmap
}

private func popupWritePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw PopupMessageTestFailure(message: "Could not encode a popup snapshot.")
    }
    try data.write(to: url, options: .atomic)
}

func popupMessageVisualTest(outputDirectory: String) throws {
    let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let formatted = try PopupMessage(popupObject("Please look at the camera.\nWe are LIVE in 20 seconds.", runs: [
        ["start": 19, "length": 6, "color": "#FFD35A", "underline": true],
        ["start": 34, "length": 4, "color": "#78F0AD", "underline": true]
    ]))
    let samples: [(String, PopupMessage, CGSize)] = [
        ("short-1920x1080", try PopupMessage(popupObject("Ready")), CGSize(width: 1920, height: 1080)),
        ("long-1920x1080", try PopupMessage(popupObject(String(repeating: "Keep your eyes on the camera. ", count: 8))), CGSize(width: 1920, height: 1080)),
        ("unbroken-1920x1080", try PopupMessage(popupObject(String(repeating: "W", count: 250))), CGSize(width: 1920, height: 1080)),
        ("formatted-1920x1080", formatted, CGSize(width: 1920, height: 1080)),
        ("portrait-1080x1920", formatted, CGSize(width: 1080, height: 1920)),
        ("unicode-1920x1080", try PopupMessage(popupObject("准备开始，请看镜头。\nWelcome 👩‍💻 😀\ne\u{301} = é")), CGSize(width: 1920, height: 1080))
    ]
    var measurements: [[String: Any]] = []
    for (name, message, screen) in samples {
        let layout = try popupVerifyLayout(message, screen: screen, label: name)
        let view = PopupMessageView(message: message, layout: layout)
        let banner = try popupBitmap(width: Int(ceil(layout.size.width)), height: Int(ceil(layout.size.height)))
        banner.size = layout.size
        view.cacheDisplay(in: view.bounds, to: banner)
        guard let background = banner.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB) else {
            throw PopupMessageTestFailure(message: "Could not sample the banner background.")
        }
        try popupCheck(abs(background.alphaComponent - 0.8) <= 2.0 / 255, "\(name): background opacity differs from 80%.")
        try popupCheck(background.redComponent < 0.01 && background.greenComponent < 0.01 && background.blueComponent < 0.01,
                       "\(name): banner background is not black.")
        var opaqueWhitePixels = 0
        for y in stride(from: 1, to: banner.pixelsHigh, by: 3) {
            for x in stride(from: 1, to: banner.pixelsWide, by: 3) {
                if let pixel = banner.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   pixel.alphaComponent >= 254.0 / 255, pixel.redComponent >= 0.98,
                   pixel.greenComponent >= 0.98, pixel.blueComponent >= 0.98 { opaqueWhitePixels += 1 }
            }
        }
        try popupCheck(opaqueWhitePixels > 0, "\(name): no fully opaque white text was rendered.")
        let transparentURL = directory.appendingPathComponent(name + "-banner.png")
        try popupWritePNG(banner, to: transparentURL)
        let composite = try popupBitmap(width: Int(screen.width), height: Int(screen.height))
        composite.size = screen
        guard let context = NSGraphicsContext(bitmapImageRep: composite) else {
            throw PopupMessageTestFailure(message: "Could not create a synthetic display drawing context.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: 0.32, green: 0.38, blue: 0.34, alpha: 1).setFill()
        NSRect(origin: .zero, size: screen).fill()
        for index in 0..<8 {
            let fraction = CGFloat(index) / 8
            NSColor(srgbRed: 0.18 + fraction * 0.3, green: 0.2 + fraction * 0.25, blue: 0.18 + fraction * 0.2, alpha: 1).setFill()
            NSRect(x: CGFloat(index) * screen.width / 8, y: 0, width: screen.width / 8, height: screen.height).fill()
        }
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let grid = NSBezierPath()
        for y in stride(from: CGFloat(0), through: screen.height, by: screen.height / 12) {
            grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: screen.width, y: y))
        }
        grid.stroke()
        let bannerImage = NSImage(size: layout.size)
        bannerImage.addRepresentation(banner)
        bannerImage.draw(in: NSRect(x: 0, y: screen.height - layout.size.height, width: screen.width, height: layout.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let blended = composite.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB) else {
            throw PopupMessageTestFailure(message: "Could not sample the composite background.")
        }
        try popupCheck(blended.alphaComponent >= 254.0 / 255 && blended.greenComponent > 0.01,
                       "\(name): the synthetic banner did not blend with the display background.")
        let compositeURL = directory.appendingPathComponent(name + ".png")
        try popupWritePNG(composite, to: compositeURL)
        let measured = PopupTextLayout(message: message, fontSize: layout.fontSize, width: layout.size.width - layout.horizontalPadding * 2)
        measurements.append([
            "name": name, "text": message.text, "unicodeScalars": message.text.unicodeScalars.count,
            "utf16Units": message.text.utf16.count, "screenWidth": screen.width, "screenHeight": screen.height,
            "bannerWidth": layout.size.width, "bannerHeight": layout.size.height,
            "bannerHeightFraction": layout.size.height / screen.height, "fontSize": layout.fontSize,
            "horizontalPadding": layout.horizontalPadding, "verticalPadding": layout.verticalPadding,
            "textWidth": measured.bounds.width, "textHeight": measured.bounds.height,
            "glyphCount": measured.manager.numberOfGlyphs, "backgroundAlpha": background.alphaComponent,
            "sampledOpaqueWhitePixels": opaqueWhitePixels,
            "transparentBanner": transparentURL.lastPathComponent, "syntheticDisplay": compositeURL.lastPathComponent
        ])
    }
    let manifest: [String: Any] = ["synthetic": true, "backgroundOpacity": 0.8, "font": "Helvetica-Bold", "samples": measurements]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    print("PASS: popup synthetic snapshots, background opacity, and opaque white text at \(directory.path)")
}
