import AppKit
import ScreenCaptureKit
import CoreGraphics

struct DisplayInfo {
    let id: String
    let cgID: CGDirectDisplayID
    let name: String
    let index: Int
    let width: Int
    let height: Int
    let bounds: CGRect
    var json: [String: Any] {
        ["id": id, "name": name, "index": index, "width": width, "height": height,
         "x": Int(bounds.minX), "y": Int(bounds.minY), "scale": Double(width) / max(1, bounds.width)]
    }
}

func displayID(_ id: CGDirectDisplayID) -> String {
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
        return CFUUIDCreateString(nil, uuid) as String
    }
    return "display-\(id)"
}

func availableDisplays(fixture: Bool = false) -> [DisplayInfo] {
    if fixture {
        var result: [DisplayInfo] = []
        for i in 1...3 {
            let width: Int = i == 2 ? 1920 : 3840
            let height: Int = i == 2 ? 1080 : 2160
            let bounds = CGRect(x: CGFloat((i-1)*1920), y: 0, width: 1920, height: 1080)
            result.append(DisplayInfo(id: "fixture-\(i)", cgID: UInt32(i), name: "Test Display \(i)", index: i, width: width, height: height, bounds: bounds))
        }
        return result
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
    let screens = NSScreen.screens
    return ids.prefix(Int(count)).enumerated().map { index, id in
        let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        let mode = CGDisplayCopyDisplayMode(id)
        return DisplayInfo(id: displayID(id), cgID: id, name: screen?.localizedName ?? "Display \(index+1)", index: index+1,
            width: mode?.pixelWidth ?? CGDisplayPixelsWide(id), height: mode?.pixelHeight ?? CGDisplayPixelsHigh(id), bounds: CGDisplayBounds(id))
    }
}

let resolutionSizes: [String: (Int, Int)] = ["hd": (1280,720), "fhd": (1920,1080), "qhd": (2560,1440), "uhd": (3840,2160)]
func scaledSize(_ display: DisplayInfo, preset: String) -> (Int, Int) {
    guard let (w, h) = resolutionSizes[preset] else { return (display.width, display.height) }
    let cap = display.height > display.width ? (h,w) : (w,h)
    let scale = min(1.0, min(Double(cap.0)/Double(display.width), Double(cap.1)/Double(display.height)))
    return (max(1, Int(Double(display.width)*scale)), max(1, Int(Double(display.height)*scale)))
}

func commonResolution(_ requested: String, displays: [DisplayInfo]) -> String {
    let presets = ["native", "hd", "fhd", "qhd", "uhd"]
    let maxIndex = presets.firstIndex(of: requested) ?? 2
    for candidate in presets.prefix(maxIndex+1).reversed() {
        guard let (w,h) = resolutionSizes[candidate] else { return "native" }
        if displays.allSatisfy({ max($0.width,$0.height) >= w && min($0.width,$0.height) >= h }) { return candidate }
    }
    return "native"
}

final class InputController {
    private var heldKeys = Set<CGKeyCode>()
    private var buttons = Set<Int>()
    private var lastPoint = CGPoint.zero
    var enabled: Bool { AXIsProcessTrusted() }
    private func flags(_ modifiers: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in modifiers {
            switch m { case "shift": f.insert(.maskShift); case "ctrl", "control": f.insert(.maskControl)
            case "alt", "option": f.insert(.maskAlternate); case "meta", "cmd", "command": f.insert(.maskCommand); default: break }
        }
        return f
    }
    func mouse(display: DisplayInfo, x: Double, y: Double, action: String, button: Int, modifiers: [String], wheelX: Int = 0, wheelY: Int = 0) {
        guard enabled, x.isFinite, y.isFinite else { return }
        lastPoint = CGPoint(x: display.bounds.minX + min(max(x,0),1)*max(0,display.bounds.width-1),
                            y: display.bounds.minY + min(max(y,0),1)*max(0,display.bounds.height-1))
        let mouseButton: CGMouseButton = button == 1 ? .right : button == 2 ? .center : .left
        let event: CGEvent?
        switch action {
        case "down":
            buttons.insert(button)
            event = CGEvent(mouseEventSource: nil, mouseType: button == 1 ? .rightMouseDown : button == 2 ? .otherMouseDown : .leftMouseDown, mouseCursorPosition: lastPoint, mouseButton: mouseButton)
        case "up":
            buttons.remove(button)
            event = CGEvent(mouseEventSource: nil, mouseType: button == 1 ? .rightMouseUp : button == 2 ? .otherMouseUp : .leftMouseUp, mouseCursorPosition: lastPoint, mouseButton: mouseButton)
        case "wheel":
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(clamping: wheelY), wheel2: Int32(clamping: wheelX), wheel3: 0)
            event?.location = lastPoint
        default:
            let type: CGEventType = buttons.contains(0) ? .leftMouseDragged : buttons.contains(1) ? .rightMouseDragged : buttons.contains(2) ? .otherMouseDragged : .mouseMoved
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: lastPoint, mouseButton: mouseButton)
        }
        event?.flags = flags(modifiers); event?.post(tap: .cghidEventTap)
    }
    func key(code: String, down: Bool, modifiers: [String]) {
        guard enabled, let key = keyCodes[code] else { return }
        if down { heldKeys.insert(key) } else { heldKeys.remove(key) }
        let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
        e?.flags = flags(modifiers); e?.post(tap: .cghidEventTap)
    }
    func text(_ text: String) {
        guard enabled, text.utf16.count <= 4096 else { return }
        let chars = Array(text.utf16)
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        chars.withUnsafeBufferPointer { p in e?.keyboardSetUnicodeString(stringLength: p.count, unicodeString: p.baseAddress) }
        e?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false); up?.post(tap: .cghidEventTap)
    }
    func releaseAll() {
        guard enabled else { heldKeys.removeAll(); buttons.removeAll(); return }
        for key in heldKeys { CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap) }
        for button in buttons {
            CGEvent(mouseEventSource: nil, mouseType: button == 1 ? .rightMouseUp : button == 2 ? .otherMouseUp : .leftMouseUp,
                    mouseCursorPosition: lastPoint, mouseButton: button == 1 ? .right : button == 2 ? .center : .left)?.post(tap: .cghidEventTap)
        }
        heldKeys.removeAll(); buttons.removeAll()
    }
}

let keyCodes: [String: CGKeyCode] = [
 "KeyA":0,"KeyS":1,"KeyD":2,"KeyF":3,"KeyH":4,"KeyG":5,"KeyZ":6,"KeyX":7,"KeyC":8,"KeyV":9,"KeyB":11,
 "KeyQ":12,"KeyW":13,"KeyE":14,"KeyR":15,"KeyY":16,"KeyT":17,"Digit1":18,"Digit2":19,"Digit3":20,"Digit4":21,"Digit6":22,"Digit5":23,
 "Equal":24,"Digit9":25,"Digit7":26,"Minus":27,"Digit8":28,"Digit0":29,"BracketRight":30,"KeyO":31,"KeyU":32,"BracketLeft":33,"KeyI":34,"KeyP":35,
 "Enter":36,"KeyL":37,"KeyJ":38,"Quote":39,"KeyK":40,"Semicolon":41,"Backslash":42,"Comma":43,"Slash":44,"KeyN":45,"KeyM":46,"Period":47,
 "Tab":48,"Space":49,"Backquote":50,"Backspace":51,"Escape":53,"MetaRight":54,"MetaLeft":55,"ShiftLeft":56,"CapsLock":57,"AltLeft":58,"ControlLeft":59,
 "ShiftRight":60,"AltRight":61,"ControlRight":62,"F17":64,"NumpadDecimal":65,"NumpadMultiply":67,"NumpadAdd":69,"NumLock":71,"NumpadDivide":75,"NumpadEnter":76,
 "NumpadSubtract":78,"F18":79,"F19":80,"NumpadEqual":81,"Numpad0":82,"Numpad1":83,"Numpad2":84,"Numpad3":85,"Numpad4":86,"Numpad5":87,"Numpad6":88,"Numpad7":89,"F20":90,"Numpad8":91,"Numpad9":92,
 "F5":96,"F6":97,"F7":98,"F3":99,"F8":100,"F9":101,"F11":103,"F13":105,"F16":106,"F14":107,"F10":109,"F12":111,"F15":113,"Insert":114,"Home":115,"PageUp":116,"Delete":117,"F4":118,"End":119,"F2":120,"PageDown":121,"F1":122,"ArrowLeft":123,"ArrowRight":124,"ArrowDown":125,"ArrowUp":126]
