import AppKit
import ServiceManagement
import Security
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var server: RemoteServer!
    var security: ServerSecurity!
    var status="Stopped"
    var port: UInt16 = 5920
    var fixture=false
    var identifyWindows: [NSWindow]=[]
    var mainWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args=CommandLine.arguments
        fixture=args.contains("--fixture")
        if let i=args.firstIndex(of:"--port"),i+1<args.count,let p=UInt16(args[i+1]),p>0 { port=p }
        else { let stored=UserDefaults.standard.integer(forKey:"serverPort");if stored > 0 && stored <= 65535 { port=UInt16(stored) } }
        var directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SU Remote/Server",isDirectory:true)
        if let i=args.firstIndex(of:"--data-dir"),i+1<args.count { directory=URL(fileURLWithPath:args[i+1],isDirectory:true) }
        do {
            security=try ServerSecurity(directory:directory)
            if fixture, args.contains("--password-stdin"), let password=readLine() { try security.setPassword(password) }
            else if fixture,let password=ProcessInfo.processInfo.environment["SU_REMOTE_TEST_PASSWORD"] { try security.setPassword(password) }
            server=RemoteServer(security:security,fixture:fixture)
            server.onStatus={ [weak self] message in self?.status=message;self?.refreshMenu();if self?.fixture == true { print(message);fflush(stdout) } }
            server.onConnection={ [weak self] in self?.refreshMenu() }
            statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            statusItem.button?.image=NSImage(systemSymbolName:"display.2",accessibilityDescription:"SU Remote Server")
            statusItem.button?.toolTip="SU Remote Server"
            refreshMenu()
            if fixture || args.contains("--start") || UserDefaults.standard.bool(forKey:"startServerOnLaunch") { start() }
            else if !security.hasPassword { showSetup() }
        } catch { alert("SU Remote could not start",error.localizedDescription); NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) { server?.stop() }
    func refreshMenu() {
        guard statusItem != nil else { return }
        let menu=NSMenu()
        menu.addItem(withTitle:"SU Remote · Studio Upgrade",action:nil,keyEquivalent:"")
        menu.addItem(withTitle:status,action:nil,keyEquivalent:"")
        menu.addItem(withTitle:server?.activeSession != nil ? "1 viewer connected" : "No viewer connected",action:nil,keyEquivalent:"")
        menu.addItem(.separator())
        add(menu,server?.listener == nil ? "Start Server" : "Stop Server",server?.listener == nil ? #selector(start) : #selector(stop))
        add(menu,"Connection Details…",#selector(details))
        add(menu,"Set Password…",#selector(changePassword))
        add(menu,"Change Port…",#selector(changePort))
        menu.addItem(.separator())
        add(menu,"Screen Recording Permission…",#selector(screenPermission))
        add(menu,"Remote Control Permission…",#selector(controlPermission))
        add(menu,"Identify Monitors",#selector(identify))
        let login=NSMenuItem(title:"Launch at Login",action:#selector(toggleLogin),keyEquivalent:""); login.target=self;login.state=SMAppService.mainApp.status == .enabled ? .on:.off;menu.addItem(login)
        let auto=NSMenuItem(title:"Start Server When App Opens",action:#selector(toggleStart),keyEquivalent:"");auto.target=self;auto.state=UserDefaults.standard.bool(forKey:"startServerOnLaunch") ? .on:.off;menu.addItem(auto)
        menu.addItem(.separator())
        add(menu,"About SU Remote",#selector(about))
        add(menu,"Quit SU Remote Server",#selector(quit),"q")
        statusItem.menu=menu
    }
    private func add(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String="") { let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=self;menu.addItem(item) }
    @objc func start() {
        if !security.hasPassword { changePassword(); if !security.hasPassword { return } }
        do { try server.start(port:port)
            if fixture { print("TLS SHA256 \(security.fingerprint)");fflush(stdout) }
        } catch { status="Stopped";refreshMenu();alert("Could not start server",error.localizedDescription) }
    }
    @objc func stop() { server.stop() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func changePassword() {
        let alert=NSAlert();alert.messageText="Set remote connection password";alert.informativeText="Use at least 8 characters. This password is separate from your Mac login password. Changing it disconnects the current viewer."
        let field=NSSecureTextField(frame:NSRect(x:0,y:0,width:340,height:28));field.placeholderString="New password"
        alert.accessoryView=field;alert.addButton(withTitle:"Save Password");alert.addButton(withTitle:"Cancel")
        NSApp.activate(ignoringOtherApps:true);alert.window.initialFirstResponder=field
        if alert.runModal() == .alertFirstButtonReturn {
            do { try security.setPassword(field.stringValue);server.activeSession?.close() } catch { self.alert("Password not saved",error.localizedDescription) }
        }
    }
    @objc func changePort() {
        let dialog=NSAlert();dialog.messageText="Connection port";dialog.informativeText="Changing the port stops the server. Start it again when ready."
        let field=NSTextField(frame:NSRect(x:0,y:0,width:260,height:28));field.stringValue=String(port);dialog.accessoryView=field
        dialog.addButton(withTitle:"Save");dialog.addButton(withTitle:"Cancel");NSApp.activate(ignoringOtherApps:true)
        if dialog.runModal() == .alertFirstButtonReturn {
            guard let value=UInt16(field.stringValue),value>1023 else { alert("Invalid port","Choose a port from 1024 through 65535.");return }
            server.stop();port=value;UserDefaults.standard.set(Int(value),forKey:"serverPort");refreshMenu()
        }
    }
    @objc func details() {
        do { if security.fingerprint.isEmpty { try security.loadIdentity() } }
        catch { alert("Certificate unavailable",error.localizedDescription);return }
        let names=Host.current().addresses.filter{!$0.contains(":") && $0 != "127.0.0.1"}.joined(separator:", ")
        let details="Server: \(Host.current().localizedName ?? "Mac")\nAddresses: \(names)\nPort: \(port)\n\nTLS certificate SHA-256 fingerprint:\n\(security.fingerprint)\n\nVerify this fingerprint in the viewer before trusting this Mac."
        let dialog=NSAlert();dialog.messageText="Connect to SU Remote";dialog.informativeText=details
        dialog.addButton(withTitle:"Done");dialog.addButton(withTitle:"Copy Details");NSApp.activate(ignoringOtherApps:true)
        if dialog.runModal() == .alertSecondButtonReturn { NSPasteboard.general.clearContents();NSPasteboard.general.setString(details,forType:.string) }
    }
    @objc func screenPermission() {
        if !CGPreflightScreenCaptureAccess() { _=CGRequestScreenCaptureAccess() }
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func controlPermission() {
        let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _=AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() };refreshMenu() }
        catch { alert("Login setting unavailable",error.localizedDescription) }
    }
    @objc func toggleStart() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey:"startServerOnLaunch"),forKey:"startServerOnLaunch");refreshMenu() }
    @objc func identify() {
        identifyWindows.forEach{$0.close()};identifyWindows=[]
        for (index,screen) in NSScreen.screens.enumerated() {
            let window=NSWindow(contentRect:NSRect(x:screen.frame.midX-160,y:screen.frame.midY-100,width:320,height:200),styleMask:[.borderless],backing:.buffered,defer:false)
            window.level = .floating;window.isOpaque=false;window.backgroundColor=NSColor.black.withAlphaComponent(0.85);window.isReleasedWhenClosed=false
            let text=NSTextField(labelWithString:"\(index+1)\n\(screen.localizedName)");text.frame=NSRect(x:10,y:30,width:300,height:150);text.alignment = .center;text.font = .systemFont(ofSize:44,weight:.bold);text.textColor = .white
            window.contentView?.addSubview(text);window.orderFrontRegardless();identifyWindows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in self?.identifyWindows.forEach{$0.close()};self?.identifyWindows=[] }
    }
    @objc func about() { alert("SU Remote · Studio Upgrade","Private LAN/VPN remote desktop.\n\nVersion 0.1.0 preview\nOne viewer per server. Mac login-window access is not enabled in this preview.\n\nOpen source under the MIT license.") }
    func showSetup() { alert("Welcome to SU Remote Server","Use the display icon in the menu bar to set a password, grant Screen Recording and Accessibility permissions, then start the server. Your Mac's screen resolution stays unchanged.") }
    func alert(_ title:String,_ message:String) { if fixture { fputs("\(title): \(message)\n",stderr);fflush(stderr);return }; let alert=NSAlert();alert.messageText=title;alert.informativeText=message;NSApp.activate(ignoringOtherApps:true);alert.runModal() }
}

func selfTest() throws {
    let displays=availableDisplays(fixture:true)
    precondition(scaledSize(displays[0],preset:"hd").0 == 1280)
    precondition(commonResolution("uhd",displays:displays) == "fhd")
    precondition(scaledSize(displays[1],preset:"uhd").0 == 1920)
    let portrait=DisplayInfo(id:"p",cgID:1,name:"Portrait",index:1,width:2160,height:3840,bounds:.zero)
    precondition(scaledSize(portrait,preset:"hd").0 == 720 && scaledSize(portrait,preset:"hd").1 == 1280)
    let image=fixtureImage(display:displays[0],width:1280,height:720,frame:1)!
    for color in ["full","gray16","color256","rgb565"] {
        let encoder=TileEncoder()
        let first=encoder.encode(image,region:CGRect(x:0,y:0,width:1,height:1),color:color,quality:0.7,motion:false)
        precondition(!first.isEmpty && first[0].codec == "png")
        precondition(encoder.encode(image,region:CGRect(x:0,y:0,width:1,height:1),color:color,quality:0.7,motion:false).isEmpty)
        let moved=encoder.encode(image,region:CGRect(x:0.2,y:0.2,width:0.2,height:0.2),color:color,quality:0.7,motion:false)
        precondition(!moved.isEmpty && moved.allSatisfy{$0.width <= 256 && $0.height <= 144})
    }
    precondition(muLaw(0) == 0xff)
    let temp=FileManager.default.temporaryDirectory.appendingPathComponent("su-remote-security-test-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:temp) }
    let security=try ServerSecurity(directory:temp);try security.setPassword("test-password")
    precondition(security.verify("test-password") && !security.verify("wrong-password"))
    let persisted=try ServerSecurity(directory:temp);precondition(persisted.verify("test-password"))
    try security.loadIdentity();precondition(!security.fingerprint.isEmpty && security.identity != nil)
    let packet=binaryMessage(["type":"test"],payload:Data([1,2,3]));precondition(packet.suffix(3) == Data([1,2,3]))
    print("PASS: scaling, common limits, portrait, all color modes, unchanged-frame suppression, viewport cropping, μ-law, salted password verifier, TLS identity, binary framing")
}
if CommandLine.arguments.contains("--self-test") {
    do { try selfTest();exit(0) } catch { fputs("FAIL: \(error)\n",stderr);exit(1) }
}
let app=NSApplication.shared
let delegate=AppDelegate();app.delegate=delegate;app.run()
