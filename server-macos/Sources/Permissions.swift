import AppKit
import ScreenCaptureKit

func capturePermissionDenied(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
}

func captureFailureMessage(_ error: Error) -> String {
    if capturePermissionDenied(error) {
        return "macOS denied screen capture. On the host Mac, open Portlight Host → Permissions, enable Screen & System Audio Recording for this copy of the app, then choose Restart Host. If it still fails after restarting, turn this app’s permission off and on to renew the grant for the updated copy."
    }
    let detail = error as NSError
    return "Screen capture failed: \(detail.localizedDescription) (\(detail.domain), \(detail.code)). Open Permissions on the host Mac and choose Check Again to test capture."
}

final class HostPermissions: NSWindowController {
    private let screenStatus = NSTextField(wrappingLabelWithString:"Not checked")
    private let controlStatus = NSTextField(wrappingLabelWithString:"Not checked")
    private let help = NSTextField(wrappingLabelWithString:"")
    private var checking = false
    private var screenVerified = false
    var onCaptureReady: (() -> Void)?
    var onRestart: (() -> Void)?
    var onStart: (() -> Void)?

    init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:490),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Portlight Host Permissions"
        window.isReleasedWhenClosed = false
        super.init(window:window)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-28),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:28),stack.bottomAnchor.constraint(lessThanOrEqualTo:window.contentView!.bottomAnchor,constant:-24)])
        let title = NSTextField(labelWithString:"Let Portlight share this Mac")
        title.font = .systemFont(ofSize:23,weight:.bold)
        if let url = Bundle.main.url(forResource:"Portlight",withExtension:"icns"), let image = NSImage(contentsOf:url) {
            let icon = NSImageView(image:image); icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:48),icon.heightAnchor.constraint(equalToConstant:48)])
            let header = NSStackView(views:[icon,title]); header.spacing = 14; stack.addArrangedSubview(header)
        } else { stack.addArrangedSubview(title) }
        let intro = NSTextField(wrappingLabelWithString:"Allow screen capture to see your displays, and Accessibility to control the keyboard and pointer. Only an authenticated viewer can connect.")
        intro.textColor = .secondaryLabelColor; stack.addArrangedSubview(intro)
        func row(_ title:String,_ status:NSTextField,_ action:Selector) {
            let heading = NSTextField(labelWithString:title); heading.font = .systemFont(ofSize:14,weight:.semibold)
            status.font = .systemFont(ofSize:12); status.textColor = .secondaryLabelColor
            let labels = NSStackView(views:[heading,status]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
            let button = NSButton(title:"Open Settings…",target:self,action:action); button.bezelStyle = .rounded
            let row = NSStackView(views:[labels,button]); row.spacing = 16; row.alignment = .centerY
            button.setContentHuggingPriority(.required,for:.horizontal)
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        }
        row("Screen & System Audio Recording",screenStatus,#selector(requestScreen))
        row("Accessibility",controlStatus,#selector(requestControl))
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        help.stringValue = "If access is already enabled, restart the host to apply it. Keep one copy of Portlight Host in Applications; an older copy can have a different permission grant."
        stack.addArrangedSubview(help)
        let buttons = NSStackView(); buttons.spacing = 10
        for (title,action) in [("Check Again",#selector(checkAgain)),("Restart Host",#selector(restart)),("Start Sharing",#selector(startSharing))] {
            let button = NSButton(title:title,target:self,action:action); button.bezelStyle = .rounded; buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)
        let path = NSTextField(wrappingLabelWithString:"This copy: \(Bundle.main.bundlePath)")
        path.font = .systemFont(ofSize:10); path.textColor = .tertiaryLabelColor; path.isSelectable = true
        stack.addArrangedSubview(path)
        for view in [intro,help,path] { view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        window.center()
        NotificationCenter.default.addObserver(self,selector:#selector(returnedToApp),name:NSApplication.didBecomeActiveNotification,object:nil)
        updateControl()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func present(request:Bool = false) {
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        updateControl()
        if request {
            // Use macOS consent dialogs, once at first launch. Never repeatedly prompt on activation.
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
        if CGPreflightScreenCaptureAccess() { checkAgain() }
        else { screenStatus.stringValue = "Not available to this running copy. Enable access, then restart the host." }
    }
    private func updateControl() {
        controlStatus.stringValue = AXIsProcessTrusted() ? "Allowed — keyboard and pointer control available" : "Not allowed — viewing still works without remote control"
    }
    @objc private func returnedToApp() {
        guard window?.isVisible == true else { return }
        updateControl()
        if CGPreflightScreenCaptureAccess() && !screenVerified { checkAgain() }
    }
    @objc func requestScreen() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func requestControl() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func checkAgain() {
        guard !checking else { return }; checking = true; updateControl()
        screenStatus.stringValue = "Testing screen capture…"
        // Exercise ScreenCaptureKit itself; a Settings switch or CGPreflight result alone is not proof.
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.checking = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                guard let display = content.displays.first else { throw ServerFailure(message:"No active display is available. Unlock the Mac and connect a display, then check again.") }
                let config = SCStreamConfiguration(); config.width = 16; config.height = 16; config.showsCursor = false
                _ = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(display:display,excludingWindows:[]),configuration:config)
                self.screenVerified = true
                self.screenStatus.stringValue = "Verified — this host successfully captured the screen"
                self.help.stringValue = "Screen capture works. System audio uses the same recording permission and remains off until enabled in the viewer. No microphone or Full Disk Access is needed."
                self.onCaptureReady?()
            } catch { self.recordFailure(error) }
        }
    }
    func recordFailure(_ error:Error) {
        screenVerified = false
        screenStatus.stringValue = capturePermissionDenied(error) ? "macOS denied access to this copy" : "Capture check failed"
        help.stringValue = captureFailureMessage(error)
    }
    @objc private func restart() { onRestart?() }
    @objc private func startSharing() { onStart?() }
}
