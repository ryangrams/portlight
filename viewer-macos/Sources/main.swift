import AppKit

if CommandLine.arguments.contains("--self-test") {
    var failures = 0
    func check(_ truth:Bool,_ name:String) { print("\(truth ? "PASS" : "FAIL") \(name)"); if !truth { failures += 1 } }
    let fullHD = RemoteMonitor(id:"1",name:"FHD",width:1920,height:1080)
    let portrait = RemoteMonitor(id:"2",name:"Portrait",width:2160,height:3840)
    let small = RemoteMonitor(id:"3",name:"Small",width:800,height:600)
    check(Resolution.fhd.supports(fullHD) && !Resolution.qhd.supports(fullHD),"Disable unsupported resolution")
    check(!Resolution.qhd.supports(RemoteMonitor(id:"wide",name:"Ultrawide",width:2560,height:1080)),"Disable presets exceeding either native axis")
    check(Resolution.native.outputSize(RemoteMonitor(id:"huge",name:"Huge",width:32768,height:32768)).width <= 4096,"Bound native canvas allocation")
    check(Resolution.hd.outputSize(fullHD) == CGSize(width:1280,height:720),"Server size uses HD before transmission")
    check(Resolution.uhd.outputSize(portrait) == CGSize(width:2160,height:3840),"Preserve portrait orientation")
    check(!Resolution.hd.supports(small) && Resolution.native.supports(small),"Native fallback below HD")
    check(validCanvasDimensions(width:3840,height:2160) && validCanvasDimensions(width:2160,height:3840) && !validCanvasDimensions(width:Int.max,height:2),"Reject excessive canvas sizes without overflow")
    check(validPort("5920") == 5920 && validPort("0") == nil && validPort("65536") == nil,"Validate port range")
    let encoded = OSCMessage.encodeString("/su/remote/color","gray16")
    check(OSCMessage.parse(encoded)?.arguments.first as? String == "gray16","OSC string roundtrip")
    check(OSCMessage.parse(Data(encoded.dropLast())) == nil,"Reject truncated OSC")
    check(OSCMessage.parse(OSCMessage.encodeString("/arbitrary/execute","no")) == nil,"Restrict OSC namespace")
    check(RemoteAudio.decode(0xff) == 0 && RemoteAudio.decode(0x7f) == 0,"Decode mu-law silence")
    check(RemoteAudio.decode(0x00) == -32124 && RemoteAudio.decode(0x80) == 32124,"Decode mu-law endpoints")
    exit(failures == 0 ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var viewer: ViewerController?
    var terminating = false
    func applicationDidFinishLaunching(_ notification:Notification) {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem); let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"About Portlight",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Quit Portlight",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem = NSMenuItem(); main.addItem(editItem); let edit = NSMenu(title:"Edit"); editItem.submenu = edit
        for (title,action,key) in [("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] { edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key) }
        let viewItem = NSMenuItem(); main.addItem(viewItem); let viewMenu = NSMenu(title:"View"); viewItem.submenu = viewMenu
        for (title,action,key) in [("Fit Displays","fitAction","0"),("Actual Size","actualSizeAction","1"),("Zoom In","zoomInAction","+"),("Zoom Out","zoomOutAction","-")] { viewMenu.addItem(withTitle:title,action:Selector(action),keyEquivalent:key) }
        viewMenu.addItem(.separator())
        let fullscreen = viewMenu.addItem(withTitle:"Enter Full Screen",action:#selector(NSWindow.toggleFullScreen(_:)),keyEquivalent:"f"); fullscreen.keyEquivalentModifierMask = [.command,.control]
        NSApp.mainMenu = main
        let viewer = ViewerController(); self.viewer = viewer; for item in viewMenu.items where item.action != #selector(NSWindow.toggleFullScreen(_:)) { item.target = viewer }; viewer.showWindow(nil); NSApp.activate(ignoringOtherApps:true)
        if let i = CommandLine.arguments.firstIndex(of:"--ui-check"), CommandLine.arguments.count > i+1 {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { viewer.runUIRegression(report:CommandLine.arguments[i+1]) }
        }
        if let i = CommandLine.arguments.firstIndex(of:"--integration-test"), CommandLine.arguments.count > i+4 {
            let password = readLine() ?? ""
            viewer.runIntegration(port:Int(CommandLine.arguments[i+1]) ?? 15922,password:password,fingerprint:CommandLine.arguments[i+2],report:CommandLine.arguments[i+3],snapshot:CommandLine.arguments[i+4])
        }
        if CommandLine.arguments.contains("--demo") { viewer.showDemo() }
        if let i = CommandLine.arguments.firstIndex(of:"--ui-snapshot"), CommandLine.arguments.count > i+1 {
            func option(_ name:String,_ fallback:String) -> String { if let j = CommandLine.arguments.firstIndex(of:name), CommandLine.arguments.count > j+1 { return CommandLine.arguments[j+1] }; return fallback }
            viewer.configureScreenshot(stage:CommandLine.arguments[i+1],appearance:option("--appearance","light"),minimum:option("--size","normal") == "minimum",popover:CommandLine.arguments.contains("--popover") ? option("--popover","") : nil)
        }
        if let i = CommandLine.arguments.firstIndex(of:"--snapshot"), CommandLine.arguments.count > i+1 {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { viewer.exportSnapshot(path:CommandLine.arguments[i+1]); NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }; terminating = true
        if let viewer { viewer.prepareToQuit { sender.reply(toApplicationShouldTerminate:true) }; return .terminateLater }; return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
