import AppKit
import Network
import Security

final class ViewerController: NSWindowController, NSWindowDelegate {
    private let transport = RemoteTransport()
    private let audio = RemoteAudio()
    private let osc = OSCReceiver()
    private let presets = PresetStore()
    private let hostField = NSTextField(string:UserDefaults.standard.string(forKey:"SU.Remote.LastHost") ?? "")
    private let portField = NSTextField(string:UserDefaults.standard.string(forKey:"SU.Remote.LastPort") ?? "5920")
    private let passwordField = NSSecureTextField(string:"")
    private let connectButton = NSButton(title:"Connect",target:nil,action:nil)
    private let resolutionPopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let qualityPopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let bandwidthField = NSTextField(string:"4000")
    private let presetPopup = NSPopUpButton()
    private let pauseButton = NSButton(checkboxWithTitle:"Pause",target:nil,action:nil)
    private let audioButton = NSButton(checkboxWithTitle:"Audio",target:nil,action:nil)
    private let viewOnlyButton = NSButton(checkboxWithTitle:"View only",target:nil,action:nil)
    private let followButton = NSButton(checkboxWithTitle:"Follow pointer",target:nil,action:nil)
    private let zoomLabel = NSTextField(labelWithString:"Fit")
    private let statusLabel = NSTextField(labelWithString:"Connect to a Mac to choose its monitors.")
    private let metricsLabel = NSTextField(labelWithString:"OSC · 127.0.0.1:19790")
    private let monitorStack = NSStackView()
    private let desktop = DesktopView()
    private let scroll = NSScrollView()
    private var monitorButtons: [NSButton] = []
    private var monitors: [RemoteMonitor] = []
    private var selected: Set<String> = []
    private var canvases: [String:MonitorCanvas] = [:]
    private var revision = 0
    private var acceptedRevision = -1
    private var ready = false
    private var demo = false
    private var testing = false
    private var autoFit = true
    private var zoom: Double = 1
    private var pendingSubscription: DispatchWorkItem?
    private var pointerButtons = 0
    private var pressedKeys = Set<UInt32>()
    private var physicalKeys: [UInt16:UInt32] = [:]
    private var lastPointer: (String,Double,Double)?
    private var totalFrames = 0
    private var rejectedFrames = 0
    private var modifiers: NSEvent.ModifierFlags = []
    private var bytesReceived = 0
    private var lastBytes = 0
    private var frameCount = 0
    private var statsTimer: Timer?
    private var latency: Double = 0
    private var sessionID = UUID().uuidString
    private var presetID: String?
    private var pendingMonitorIDs: Set<String>?
    private var zeroTierTransaction: String?
    private var zeroTierNetwork: String?
    private var zeroTierManaged: [String] = []
    private let zeroTierQueue = DispatchQueue(label:"studio.upgrade.remote.zerotier",qos:.userInitiated)
    private var zeroTierStatus: [String:Any]?
    private var inLayout = false
    private let helpText = "Click a screen to control it. Option-scroll pans locally. Control-Option-Escape releases remote keys. Audio is off by default."

    init() {
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1220,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = "Studio Upgrade Remote"; w.appearance = NSAppearance(named:.aqua); w.minSize = NSSize(width:840,height:540); w.center()
        super.init(window:w); w.delegate = self; w.acceptsMouseMovedEvents = true
        buildUI(); bindTransport(); reloadPresets()
        osc.onMessage = { [weak self] message,peer in self?.handleOSC(message,peer:peer) }
        osc.onStatus = { [weak self] in self?.metricsLabel.stringValue = $0 }; osc.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.updateStats() }
        NotificationCenter.default.addObserver(self,selector:#selector(viewportChanged),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        NotificationCenter.default.addObserver(self,selector:#selector(appDeactivated),name:NSApplication.didResignActiveNotification,object:nil)
        scroll.contentView.postsBoundsChangedNotifications = true
        NSEvent.addLocalMonitorForEvents(matching:[.keyDown]) { [weak self] event in
            if event.keyCode == 53 && event.modifierFlags.contains([.control,.option]) { self?.releaseInput(); self?.window?.makeFirstResponder(nil); return nil }; return event
        }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func label(_ text:String) -> NSTextField { let l = NSTextField(labelWithString:text); l.font = .systemFont(ofSize:11,weight:.medium); l.textColor = .secondaryLabelColor; return l }
    private func button(_ title:String,_ action:Selector) -> NSButton { NSButton(title:title,target:self,action:action) }
    private func row(_ items:[NSView],spacing:CGFloat = 8) -> NSStackView { let r = NSStackView(views:items); r.orientation = .horizontal; r.spacing = spacing; r.alignment = .centerY; return r }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:content.topAnchor,constant:14),root.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12)])
        let brand = NSTextField(labelWithString:"STUDIO UPGRADE  /  REMOTE"); brand.font = .systemFont(ofSize:12,weight:.bold); brand.textColor = .secondaryLabelColor
        root.addArrangedSubview(brand)
        hostField.placeholderString = "Mac host name or IP"; hostField.widthAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
        portField.widthAnchor.constraint(equalToConstant:64).isActive = true
        passwordField.placeholderString = "Server password"; passwordField.widthAnchor.constraint(equalToConstant:180).isActive = true
        connectButton.target = self; connectButton.action = #selector(connectAction); connectButton.bezelStyle = .rounded
        let connection = row([label("SERVER"),hostField,label("PORT"),portField,passwordField,connectButton,button("ZeroTier…",#selector(zeroTierAction))])
        root.addArrangedSubview(connection)
        presetPopup.addItem(withTitle:"Saved connections"); presetPopup.widthAnchor.constraint(equalToConstant:220).isActive = true; presetPopup.target = self; presetPopup.action = #selector(recallPresetAction)
        let presetRow = row([presetPopup,button("Save preset…",#selector(savePresetAction)),button("Fullscreen",#selector(fullscreenAction)),label(helpText)])
        root.addArrangedSubview(presetRow)
        monitorStack.orientation = .horizontal; monitorStack.spacing = 14
        monitorStack.addArrangedSubview(label("MONITORS · Available after connecting"))
        root.addArrangedSubview(monitorStack)
        resolutionPopup.addItems(withTitles:Resolution.allCases.map(\.label)); resolutionPopup.selectItem(at:2)
        colorPopup.addItems(withTitles:["Full color","256 colors","16-bit color","16 shades of gray"])
        qualityPopup.addItems(withTitles:["Adaptive","Desktop · sharp text","Motion · smaller JPEG"])
        fpsPopup.addItems(withTitles:["5 fps","10 fps","15 fps","30 fps","60 fps"]); fpsPopup.selectItem(at:2)
        for popup in [resolutionPopup,colorPopup,qualityPopup,fpsPopup] { popup.target = self; popup.action = #selector(settingsAction) }
        bandwidthField.widthAnchor.constraint(equalToConstant:72).isActive = true; bandwidthField.target = self; bandwidthField.action = #selector(settingsAction); bandwidthField.toolTip = "Total target in kilobits per second. 0 is automatic; otherwise 100–100000."
        let settings = row([label("SIZE"),resolutionPopup,label("COLOR"),colorPopup,qualityPopup,fpsPopup,label("CAP kbps"),bandwidthField])
        root.addArrangedSubview(settings)
        for b in [pauseButton,audioButton,viewOnlyButton,followButton] { b.target = self; b.action = #selector(settingsAction) }
        audioButton.toolTip = "Optional low-bandwidth system audio (24 kHz mono μ-law, about 192 kbps). No microphone."
        followButton.toolTip = "Pan near the viewport edges. Turn off to use scroll bars. Option-scroll always pans locally."
        zoomLabel.widthAnchor.constraint(equalToConstant:55).isActive = true
        root.addArrangedSubview(row([button("Fit all",#selector(fitAction)),button("Fit monitor",#selector(fitMonitorAction)),button("−",#selector(zoomOutAction)),zoomLabel,button("+",#selector(zoomInAction)),button("100%",#selector(actualSizeAction)),followButton,pauseButton,viewOnlyButton,audioButton]))
        scroll.documentView = desktop; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = false; scroll.borderType = .bezelBorder; scroll.drawsBackground = true; scroll.backgroundColor = NSColor(calibratedWhite:0.045,alpha:1)
        root.addArrangedSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        let status = row([statusLabel,NSView(),metricsLabel]); root.addArrangedSubview(status); status.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize:11); statusLabel.lineBreakMode = .byTruncatingTail; metricsLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); metricsLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(label("Preview build · LAN / VPN · encrypted connection · native macOS viewer"))
    }
    private var resolution:Resolution { Resolution.allCases[max(0,resolutionPopup.indexOfSelectedItem)] }
    private var color:String { ["full","color256","rgb565","gray16"][max(0,colorPopup.indexOfSelectedItem)] }
    private var quality:String { ["auto","desktop","motion"][max(0,qualityPopup.indexOfSelectedItem)] }
    private var fps:Int { [5,10,15,30,60][max(0,fpsPopup.indexOfSelectedItem)] }
    private var cap:Int { let v = Int(bandwidthField.stringValue) ?? 4000; return v == 0 ? 0 : min(100000,max(100,v)) }
    private var selectedMonitors:[RemoteMonitor] { monitors.filter { selected.contains($0.id) } }
    private var paused:Bool { pauseButton.state == .on || window?.isMiniaturized == true }
    private func bindTransport() {
        transport.onStatus = { [weak self] text in self?.statusLabel.stringValue = text }
        transport.onMessage = { [weak self] object,data in self?.receive(object,data:data) }
        transport.onDisconnect = { [weak self] in self?.didDisconnect() }
    }
    @objc private func connectAction() {
        if ready { disconnect(); return }
        guard let port = validPort(portField.stringValue), !hostField.stringValue.trimmingCharacters(in:.whitespaces).isEmpty else { statusLabel.stringValue = "Enter a server and a port from 1 to 65535."; return }
        demo = false
        if !testing { UserDefaults.standard.set(hostField.stringValue,forKey:"SU.Remote.LastHost"); UserDefaults.standard.set(portField.stringValue,forKey:"SU.Remote.LastPort") }
        if let network = zeroTierNetwork, zeroTierTransaction == nil {
            statusLabel.stringValue = "Activating the saved ZeroTier network…"
            runZeroTier(["action":"activate","networkId":network,"managedNetworkIds":zeroTierManaged,"sessionId":sessionID]) { [weak self] result in
                guard let self else { return }; guard result["ok"] as? Bool == true else { self.statusLabel.stringValue = result["message"] as? String ?? result["error"] as? String ?? "ZeroTier activation failed."; return }
                self.zeroTierTransaction = result["transactionId"] as? String
                self.transport.connect(host:self.hostField.stringValue,port:port,password:self.passwordField.stringValue)
            }
        } else { transport.connect(host:hostField.stringValue,port:port,password:passwordField.stringValue) }
    }
    private func disconnect() { releaseInput(); transport.disconnect(); didDisconnect(); statusLabel.stringValue = "Disconnected." }
    private func didDisconnect() {
        ready = false; acceptedRevision = -1; connectButton.title = "Connect"; audio.stop(); pointerButtons = 0; pressedKeys.removeAll(); modifiers = []
        if let transaction = zeroTierTransaction { zeroTierTransaction = nil; runZeroTier(["action":"restore","transactionId":transaction]) { [weak self] result in if result["ok"] as? Bool != true { self?.statusLabel.stringValue = "Disconnected; ZeroTier restore needs attention." } } }
    }
    private func receive(_ object:[String:Any],data:Data?) {
        guard let type = object["type"] as? String else { return }
        switch type {
        case "welcome","displays":
            guard let rows = object["displays"] as? [[String:Any]], rows.count <= 32 else { statusLabel.stringValue = "Server sent an invalid monitor list."; return }
            var parsed: [RemoteMonitor] = []
            for (index,row) in rows.enumerated() {
                guard let id = row["id"] as? String, let width = row["width"] as? Int, let height = row["height"] as? Int, width > 0, height > 0, width <= 32768, height <= 32768, !parsed.contains(where:{$0.id == id}) else { continue }
                parsed.append(RemoteMonitor(id:id,name:row["name"] as? String ?? "Monitor \(index+1)",width:width,height:height,number:index+1))
            }
            releaseInput(); let firstWelcome = !ready; monitors = parsed; ready = true; connectButton.title = "Disconnect"
            let available = Set(parsed.map(\.id))
            if let pending = pendingMonitorIDs { selected = pending.intersection(available); pendingMonitorIDs = nil }
            else if firstWelcome { selected = parsed.first.map { [$0.id] } ?? [] }
            else { selected = selected.intersection(available) }
            if let capabilities = object["capabilities"] as? [String:Any], let audioCodecs = capabilities["audio"] as? [String] { audioButton.isEnabled = audioCodecs.contains("mulaw"); if !audioButton.isEnabled { audioButton.state = .off } }
            refreshMonitorButtons(); validateResolution(); rebuildCanvases(); scheduleSubscription(immediate:true)
            statusLabel.stringValue = "Connected to \(object["serverName"] as? String ?? hostField.stringValue). Choose the monitors to stream."
        case "subscribed":
            guard let ack = object["revision"] as? Int, ack == revision, let displays = object["displays"] as? [[String:Any]] else { return }
            let sizes = displays.compactMap { row -> (Int,Int)? in
                guard let w = row["width"] as? Int, let h = row["height"] as? Int else { return nil }; return (w,h)
            }
            guard sizes.count == displays.count, sizes.allSatisfy({validCanvasDimensions(width:$0.0,height:$0.1)}), sizes.reduce(0.0,{$0+Double($1.0)*Double($1.1)}) <= maxViewerCanvasPixels else {
                disconnect(); statusLabel.stringValue = "Server requested an unsupported canvas size. Maximum UHD per monitor and 4 UHD canvases total."; return
            }
            acceptedRevision = ack
            for display in displays {
                guard let id = display["id"] as? String, let w = display["width"] as? Int, let h = display["height"] as? Int, let canvas = canvases[id], w > 0, h > 0 else { continue }
                if canvas.pixelSize != CGSize(width:w,height:h) { canvas.resetSurface(CGSize(width:w,height:h)) }
            }
            layoutCanvases()
        case "frame":
            guard let data, let sequence = object["sequence"] as? Int else { return }
            defer { transport.send(["type":"frameAck","sequence":sequence]) }
            guard object["revision"] as? Int == acceptedRevision, acceptedRevision == revision, let id = object["display"] as? String, selected.contains(id), let canvas = canvases[id], let x = object["x"] as? Int, let y = object["y"] as? Int, let w = object["width"] as? Int, let h = object["height"] as? Int, let cw = object["canvasWidth"] as? Int, let ch = object["canvasHeight"] as? Int, cw == Int(canvas.pixelSize.width), ch == Int(canvas.pixelSize.height), ["png","jpeg"].contains(object["codec"] as? String ?? "") else { return }
            if canvas.applyTile(data:data,x:x,y:y,width:w,height:h) { bytesReceived += data.count; frameCount += 1; totalFrames += 1 } else { rejectedFrames += 1 }
        case "audio":
            guard let data, !paused, audioButton.state == .on, object["revision"] as? Int == acceptedRevision, object["codec"] as? String == "mulaw", let rate = object["sampleRate"] as? Int, let channels = object["channels"] as? Int, object["samples"] as? Int == data.count else { return }
            audio.play(data,sampleRate:rate,channels:channels); bytesReceived += data.count
        case "cursor":
            guard let id = object["display"] as? String, selected.contains(id), let x = object["x"] as? Double, let y = object["y"] as? Double, x.isFinite, y.isFinite, (0..<1).contains(x), (0..<1).contains(y) else { return }
            for (monitorID,c) in canvases { c.remoteCursor = monitorID == id ? NSPoint(x:x,y:y) : nil }
        case "pong": if let timestamp = object["time"] as? Double { latency = (Date().timeIntervalSince1970-timestamp)*1000 }
        case "error": statusLabel.stringValue = object["message"] as? String ?? "Server reported an error."; if object["code"] as? String == "authentication" { ready = false }
        case "stats": break
        default: break
        }
    }
    private func refreshMonitorButtons() {
        for v in monitorStack.arrangedSubviews { monitorStack.removeArrangedSubview(v); v.removeFromSuperview() }
        monitorButtons = []
        monitorStack.addArrangedSubview(label("MONITORS"))
        for (i,m) in monitors.enumerated() {
            let b = NSButton(checkboxWithTitle:m.label,target:self,action:#selector(monitorAction(_:))); b.tag = i; b.state = selected.contains(m.id) ? .on : .off; b.toolTip = "\(m.width) × \(m.height) native pixels · \(m.id)"; monitorStack.addArrangedSubview(b); monitorButtons.append(b)
        }
        monitorStack.addArrangedSubview(button("All",#selector(allMonitorsAction)))
    }
    @objc private func monitorAction(_ sender:NSButton) {
        guard monitors.indices.contains(sender.tag) else { return }; releaseInput()
        let id = monitors[sender.tag].id; if sender.state == .on { selected.insert(id) } else { selected.remove(id) }
        validateResolution(); rebuildCanvases(); scheduleSubscription()
    }
    @objc private func allMonitorsAction() { releaseInput(); selected = Set(monitors.map(\.id)); refreshMonitorButtons(); validateResolution(); rebuildCanvases(); scheduleSubscription() }
    private func resolutionFitsBudget(_ value:Resolution) -> Bool {
        selectedMonitors.reduce(0.0) { total,monitor in let size = value.outputSize(monitor); return total + size.width*size.height } <= maxViewerCanvasPixels
    }
    private func validateResolution() {
        for (index,preset) in Resolution.allCases.enumerated() {
            let limiter = selectedMonitors.first { !preset.supports($0) }
            resolutionPopup.item(at:index)?.isEnabled = limiter == nil && resolutionFitsBudget(preset) && (preset != .native || selectedMonitors.contains { !Resolution.hd.supports($0) })
            resolutionPopup.item(at:index)?.toolTip = limiter.map { "\($0.label) is \($0.width) × \($0.height); this setting would upscale it." }
        }
        resolutionPopup.autoenablesItems = false
        if !selectedMonitors.allSatisfy({resolution.supports($0)}) || !resolutionFitsBudget(resolution) {
            let desired = resolutionPopup.indexOfSelectedItem
            let supported = Resolution.allCases.enumerated().filter { $0.offset <= desired && selectedMonitors.allSatisfy($0.element.supports) && resolutionFitsBudget($0.element) }.last?.offset ?? 0
            resolutionPopup.selectItem(at:supported)
        }
    }
    private func rebuildCanvases() {
        guard resolutionFitsBudget(resolution) else { for canvas in canvases.values { canvas.removeFromSuperview() }; canvases.removeAll(); statusLabel.stringValue = "Choose fewer monitors to stay within the viewer memory limit."; return }
        let ids = Set(selectedMonitors.map(\.id))
        for (id,canvas) in canvases where !ids.contains(id) { canvas.removeFromSuperview(); canvases.removeValue(forKey:id) }
        for monitor in selectedMonitors {
            let size = resolution.outputSize(monitor)
            if let canvas = canvases[monitor.id] { if canvas.pixelSize != size { canvas.resetSurface(size) }; continue }
            let canvas = MonitorCanvas(monitor:monitor,size:size)
            canvas.onPointer = { [weak self] id,x,y,action,button,dx,dy in self?.pointer(id:id,x:x,y:y,action:action,button:button,dx:dx,dy:dy) }
            canvas.onReleaseInput = { [weak self] in self?.releaseInput() }
            canvas.onKey = { [weak self] event,down in self?.key(event,down:down) }; canvas.onFlags = { [weak self] event in self?.flags(event) }
            canvas.onLocalPan = { [weak self] event in guard let self else { return }; self.pan(dx:-event.scrollingDeltaX,dy:-event.scrollingDeltaY) }
            canvas.onEdge = { [weak self] point in self?.followPointer(point) }
            canvases[monitor.id] = canvas; desktop.addSubview(canvas)
        }
        for c in canvases.values { c.viewOnly = viewOnlyButton.state == .on || paused }
        layoutCanvases()
    }
    private func layoutCanvases() {
        guard !inLayout else { return }; inLayout = true; defer { inLayout = false }
        let selectedList = selectedMonitors
        let box = resolution == .native ? CGSize(width:selectedList.map { Double($0.width) }.max() ?? 1280,height:selectedList.map { Double($0.height) }.max() ?? 720) : resolution.dimensions
        // Each monitor has an equal preset area; aspect-preserving image is centered within it.
        let maxHeight = max(box.height,selectedList.map { canvases[$0.id]?.pixelSize.height ?? 0 }.max() ?? 0)
        let totalWidth = max(1,Double(selectedList.count)*box.width + Double(max(0,selectedList.count-1))*12)
        if autoFit { zoom = min(2,min(Double(scroll.contentSize.width)/totalWidth,Double(scroll.contentSize.height)/max(1,maxHeight))); zoom = max(0.03,zoom) }
        var x:Double = 0
        for monitor in selectedList {
            guard let canvas = canvases[monitor.id] else { continue }
            let slotWidth = max(box.width,canvas.pixelSize.width)
            canvas.frame = CGRect(x:(x+(slotWidth-canvas.pixelSize.width)/2)*zoom,y:(maxHeight-canvas.pixelSize.height)/2*zoom,width:canvas.pixelSize.width*zoom,height:canvas.pixelSize.height*zoom)
            x += slotWidth+12
        }
        desktop.frame = CGRect(x:0,y:0,width:max(scroll.contentSize.width,(x > 0 ? x-12 : 0)*zoom),height:max(scroll.contentSize.height,maxHeight*zoom))
        zoomLabel.stringValue = autoFit ? "Fit \(Int(zoom*100))%" : "\(Int(zoom*100))%"
    }
    @objc private func settingsAction() {
        releaseInput(); bandwidthField.stringValue = String(cap); validateResolution(); rebuildCanvases()
        if audioButton.state != .on || paused { audio.stop() }
        if demo { for (index,m) in selectedMonitors.enumerated() { canvases[m.id]?.demoImage(index+1) } }
        scheduleSubscription()
    }
    @objc private func fitAction() { autoFit = true; layoutCanvases(); scheduleSubscription() }
    @objc private func fitMonitorAction() {
        guard let canvas = (window?.firstResponder as? MonitorCanvas) ?? selectedMonitors.first.flatMap({canvases[$0.id]}) else { return }
        autoFit = false; zoom = min(Double(scroll.contentSize.width)/canvas.pixelSize.width,Double(scroll.contentSize.height)/canvas.pixelSize.height); layoutCanvases(); scroll.contentView.scroll(to:canvas.frame.origin); scheduleSubscription()
    }
    @objc private func zoomInAction() { setZoom(zoom*1.25) }
    @objc private func zoomOutAction() { setZoom(zoom/1.25) }
    @objc private func actualSizeAction() { setZoom(1) }
    private func setZoom(_ value:Double) { guard value.isFinite else { return }; autoFit = false; zoom = clamp(value,0.05,4); layoutCanvases(); scheduleSubscription() }
    @objc private func fullscreenAction() { window?.toggleFullScreen(nil) }
    @objc private func viewportChanged() { if !inLayout { scheduleSubscription() } }
    private func pan(dx:CGFloat,dy:CGFloat) {
        let origin = scroll.contentView.bounds.origin, size = scroll.contentSize
        scroll.contentView.scroll(to:NSPoint(x:clamp(origin.x+dx,0,max(0,desktop.bounds.width-size.width)),y:clamp(origin.y+dy,0,max(0,desktop.bounds.height-size.height)))); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func followPointer(_ windowPoint:NSPoint) {
        guard followButton.state == .on, !autoFit else { return }
        let p = scroll.convert(windowPoint,from:nil); let edge:CGFloat = 40
        func speed(_ p:CGFloat,_ maxValue:CGFloat) -> CGFloat { p < edge ? -(edge-p)*0.35 : (p > maxValue-edge ? (p-(maxValue-edge))*0.35 : 0) }
        pan(dx:speed(p.x,scroll.bounds.width),dy:-speed(p.y,scroll.bounds.height))
    }
    private func scheduleSubscription(immediate:Bool = false) {
        pendingSubscription?.cancel()
        guard ready, !demo else { return }
        let item = DispatchWorkItem { [weak self] in self?.sendSubscription() }; pendingSubscription = item
        DispatchQueue.main.asyncAfter(deadline:.now()+(immediate ? 0 : 0.12),execute:item)
    }
    private func sendSubscription() {
        guard ready else { return }; revision += 1; acceptedRevision = -1
        var regions: [String:Any] = [:]
        for m in selectedMonitors {
            guard let c = canvases[m.id] else { continue }
            let visible = c.frame.intersection(scroll.contentView.bounds)
            if visible.isNull || visible.isEmpty { regions[m.id] = ["x":0,"y":0,"width":0,"height":0] }
            else { regions[m.id] = ["x":clamp((visible.minX-c.frame.minX)/c.frame.width,0,1),"y":clamp((visible.minY-c.frame.minY)/c.frame.height,0,1),"width":clamp(visible.width/c.frame.width,0,1),"height":clamp(visible.height/c.frame.height,0,1)] }
        }
        let box = resolution == .native ? Resolution.hd.dimensions : resolution.dimensions
        transport.send(["type":"subscribe","revision":revision,"displays":selectedMonitors.map(\.id),"maxWidth":Int(box.width),"maxHeight":Int(box.height),"color":color,"quality":quality,"fps":fps,"bandwidthKbps":cap,"paused":paused,"audio":audioButton.state == .on && !paused,"viewOnly":viewOnlyButton.state == .on,"regions":regions])
    }
    private func pointer(id:String,x:Double,y:Double,action:String,button:Int,dx:Double,dy:Double) {
        guard ready, !paused, viewOnlyButton.state != .on, !demo, selected.contains(id) else { return }
        if action == "scroll" { transport.send(["type":"wheel","display":id,"x":min(x,0.999999),"y":min(y,0.999999),"dx":dx/10,"dy":dy/10]); return }
        lastPointer = (id,x,y)
        let mask = button > 0 ? (1 << (button-1)) : 0
        if action == "down" { pointerButtons |= mask } else if action == "up" { pointerButtons &= ~mask }
        transport.send(["type":"pointer","display":id,"x":min(x,0.999999),"y":min(y,0.999999),"buttons":pointerButtons])
    }
    private static let specialKeys:[UInt16:UInt32] = [36:0xff0d,48:0xff09,51:0xff08,53:0xff1b,123:0xff51,126:0xff52,124:0xff53,125:0xff54,117:0xffff,115:0xff50,119:0xff57,116:0xff55,121:0xff56,122:0xffbe,120:0xffbf,99:0xffc0,118:0xffc1,96:0xffc2,97:0xffc3,98:0xffc4,100:0xffc5,101:0xffc6,109:0xffc7,103:0xffc8,111:0xffc9,76:0xff0d]
    private func key(_ event:NSEvent,down:Bool) {
        guard ready, !paused, !demo, viewOnlyButton.state != .on else { return }
        let keysym: UInt32?
        if !down, let held = physicalKeys[event.keyCode] { keysym = held }
        else if let special = Self.specialKeys[event.keyCode] { keysym = special }
        else if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first { keysym = scalar.value <= 255 ? scalar.value : 0x01000000 | scalar.value }
        else { keysym = nil }
        guard let key = keysym else { return }
        if down { pressedKeys.insert(key); physicalKeys[event.keyCode] = key } else { pressedKeys.remove(key); physicalKeys.removeValue(forKey:event.keyCode) }
        transport.send(["type":"key","key":key,"down":down])
    }
    private func flags(_ event:NSEvent) {
        guard ready, !paused, !demo else { return }
        let pairs: [(NSEvent.ModifierFlags,UInt32)] = [(.shift,0xffe1),(.control,0xffe3),(.option,0xffe9),(.command,0xffeb)]
        for (flag,key) in pairs where modifiers.contains(flag) != event.modifierFlags.contains(flag) {
            let down = event.modifierFlags.contains(flag); if down { pressedKeys.insert(key) } else { pressedKeys.remove(key) }; transport.send(["type":"key","key":key,"down":down])
        }; modifiers = event.modifierFlags
    }
    private func releaseInput() {
        if ready && !demo { for key in pressedKeys { transport.send(["type":"key","key":key,"down":false]) }; if pointerButtons != 0, let point = lastPointer { transport.send(["type":"pointer","display":point.0,"x":point.1,"y":point.2,"buttons":0]) } }
        pressedKeys.removeAll(); physicalKeys.removeAll(); pointerButtons = 0; modifiers = []; lastPointer = nil
    }
    @objc private func appDeactivated() { releaseInput() }
    private func updateStats() {
        if ready && !demo { let rate = Double(bytesReceived-lastBytes)*8/1000; metricsLabel.stringValue = String(format:"%.0f kbps · %d tiles/s · %.0f ms",rate,frameCount,latency); lastBytes = bytesReceived; frameCount = 0; transport.send(["type":"ping","time":Date().timeIntervalSince1970]) }
    }
    func windowDidResize(_ notification:Notification) { layoutCanvases(); scheduleSubscription() }
    func windowDidMiniaturize(_ notification:Notification) { releaseInput(); audio.stop(); scheduleSubscription(immediate:true) }
    func windowDidDeminiaturize(_ notification:Notification) { scheduleSubscription(immediate:true) }
    func windowDidResignKey(_ notification:Notification) { releaseInput() }
    func windowShouldClose(_ sender:NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func prepareToQuit(_ completion:@escaping()->Void) {
        releaseInput(); transport.disconnect(); audio.stop(); osc.stop(); statsTimer?.invalidate()
        if let transaction = zeroTierTransaction {
            zeroTierTransaction = nil
            runZeroTier(["action":"restore","transactionId":transaction]) { [weak self] result in
                if result["ok"] as? Bool != true { self?.statusLabel.stringValue = "ZeroTier restore needs attention; recovery transaction is saved." }; completion()
            }
        } else { RunLoop.main.perform(inModes:[.default,.modalPanel,.eventTracking],block:completion) }
    }
    private func reloadPresets() {
        presetPopup.removeAllItems(); presetPopup.addItem(withTitle:"Saved connections")
        for p in presets.presets { presetPopup.addItem(withTitle:p.name); presetPopup.lastItem?.representedObject = p.id }
    }
    @objc private func savePresetAction() {
        let alert = NSAlert(); alert.messageText = "Save connection and view"; alert.informativeText = "Stores the server, selected screens, picture settings, view controls, and any ZeroTier policy. Passwords can be stored separately in your macOS Keychain."
        let name = NSTextField(string:hostField.stringValue.isEmpty ? "Studio connection" : hostField.stringValue); name.frame = NSRect(x:0,y:36,width:350,height:24)
        let remember = NSButton(checkboxWithTitle:"Save password in macOS Keychain",target:nil,action:nil); remember.frame = NSRect(x:0,y:0,width:350,height:24)
        let container = NSView(frame:NSRect(x:0,y:0,width:350,height:65)); container.addSubview(name); container.addSubview(remember); alert.accessoryView = container
        alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = presetID ?? UUID().uuidString
        let p = ViewPreset(id:id,name:String(name.stringValue.prefix(100)),host:hostField.stringValue,port:validPort(portField.stringValue) ?? 5920,monitors:selectedMonitors.map(\.id),resolution:resolution.rawValue,color:color,quality:quality,bandwidthKbps:cap,fps:fps,zoom:autoFit ? 0 : zoom,follow:followButton.state == .on,viewOnly:viewOnlyButton.state == .on,fullScreen:window?.styleMask.contains(.fullScreen) ?? false,zeroTierNetwork:zeroTierNetwork,zeroTierManaged:zeroTierManaged)
        presets.save(p); presetID = id
        if remember.state == .on && !passwordField.stringValue.isEmpty { savePassword(passwordField.stringValue,preset:id) }
        reloadPresets(); presetPopup.selectItem(withTitle:p.name); statusLabel.stringValue = "Saved \(p.name)."
    }
    @objc private func recallPresetAction() { if let id = presetPopup.selectedItem?.representedObject as? String { recallPreset(id,connect:false) } }
    @discardableResult private func recallPreset(_ id:String,connect:Bool) -> Bool {
        guard let p = presets.presets.first(where:{$0.id == id || $0.name == id}) else { return false }
        disconnect(); presetID = p.id; hostField.stringValue = p.host; portField.stringValue = String(p.port); passwordField.stringValue = loadPassword(preset:p.id) ?? ""
        pendingMonitorIDs = Set(p.monitors)
        resolutionPopup.selectItem(at:Resolution.allCases.firstIndex(where:{$0.rawValue == p.resolution}) ?? 2)
        colorPopup.selectItem(at:["full","color256","rgb565","gray16"].firstIndex(of:p.color) ?? 0)
        qualityPopup.selectItem(at:["auto","desktop","motion"].firstIndex(of:p.quality) ?? 0)
        fpsPopup.selectItem(at:[5,10,15,30,60].firstIndex(of:p.fps) ?? 2); bandwidthField.stringValue = String(p.bandwidthKbps)
        autoFit = p.zoom == 0; zoom = p.zoom > 0 ? clamp(p.zoom,0.05,4) : 1; followButton.state = p.follow ? .on : .off; viewOnlyButton.state = p.viewOnly ? .on : .off
        audioButton.state = .off; pauseButton.state = .off; zeroTierNetwork = p.zeroTierNetwork; zeroTierManaged = p.zeroTierManaged ?? []
        if p.fullScreen != (window?.styleMask.contains(.fullScreen) ?? false) { window?.toggleFullScreen(nil) }
        statusLabel.stringValue = "Loaded \(p.name)."; if connect { connectAction() }; return true
    }
    private func savePassword(_ password:String,preset:String) {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"studio.upgrade.remote.viewer",kSecAttrAccount as String:preset]
        SecItemDelete(query as CFDictionary); var item = query; item[kSecValueData as String] = Data(password.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary,nil) != errSecSuccess { statusLabel.stringValue = "Preset saved; Keychain password could not be stored." }
    }
    private func loadPassword(preset:String) -> String? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"studio.upgrade.remote.viewer",kSecAttrAccount as String:preset,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }; return String(data:data,encoding:.utf8)
    }
    private func handleOSC(_ m:OSCMessage,peer:NWConnection) {
        func error(_ text:String) { osc.reply(peer,address:"/su/remote/error",value:text) }
        func firstString() -> String? { m.arguments.first as? String }
        func toggle(_ button:NSButton) -> Bool { guard let n = m.arguments.first as? Int, n == 0 || n == 1 else { error("Expected 0 or 1"); return false }; button.state = n == 1 ? .on : .off; settingsAction(); return true }
        switch m.address {
        case "/su/remote/state/get":
            osc.reply(peer,value:jsonString(["version":1,"sessionId":sessionID,"connected":ready,"host":hostField.stringValue,"displays":selectedMonitors.map(\.id),"resolution":resolution.rawValue,"color":color,"zoom":zoom,"panMode":followButton.state == .on ? "follow" : "manual","paused":paused,"audio":audioButton.state == .on,"viewOnly":viewOnlyButton.state == .on,"fullscreen":window?.styleMask.contains(.fullScreen) ?? false]) ?? "{}")
        case "/su/remote/connect":
            guard let value = firstString(), !value.isEmpty else { error("Expected saved preset name/id or host"); return }
            if !recallPreset(value,connect:true) { if ready { disconnect() }; hostField.stringValue = value; connectAction() }
        case "/su/remote/disconnect": disconnect()
        case "/su/remote/preset/recall": if let id = firstString(), recallPreset(id,connect:false) {} else { error("Unknown preset") }
        case "/su/remote/monitors/select":
            let ids = m.arguments.compactMap { $0 as? String }; guard ids.count == m.arguments.count, Set(ids).isSubset(of:Set(monitors.map(\.id))) else { error("Unknown monitor or invalid arguments"); return }
            releaseInput(); selected = Set(ids); refreshMonitorButtons(); validateResolution(); rebuildCanvases(); scheduleSubscription()
        case "/su/remote/resolution":
            guard let value = firstString(), let r = Resolution(rawValue:value), let index = Resolution.allCases.firstIndex(of:r), selectedMonitors.allSatisfy(r.supports), resolutionFitsBudget(r), r != .native else { error("Unsupported resolution for the selected monitors"); return }
            resolutionPopup.selectItem(at:index); settingsAction()
        case "/su/remote/color":
            guard let value = firstString(), let i = ["full","color256","rgb565","gray16"].firstIndex(of:value) else { error("Unsupported color mode"); return }; colorPopup.selectItem(at:i); settingsAction()
        case "/su/remote/zoom": guard let value = m.arguments.first as? Double, value >= 0.05, value <= 4 else { error("Zoom must be a float from 0.05 to 4"); return }; setZoom(value)
        case "/su/remote/zoom/fit": fitAction()
        case "/su/remote/pan/mode": guard let mode = firstString(), ["follow","manual"].contains(mode) else { error("Expected follow or manual"); return }; followButton.state = mode == "follow" ? .on : .off
        case "/su/remote/paused": _ = toggle(pauseButton)
        case "/su/remote/viewonly": _ = toggle(viewOnlyButton)
        case "/su/remote/audio": if audioButton.isEnabled { _ = toggle(audioButton) } else { error("Server audio is unavailable") }
        case "/su/remote/fullscreen": guard let n = m.arguments.first as? Int, n == 0 || n == 1 else { error("Expected 0 or 1"); return }; if (n == 1) != (window?.styleMask.contains(.fullScreen) ?? false) { fullscreenAction() }
        default: error("Unknown OSC action")
        }
    }
    private func runZeroTier(_ request:[String:Any],completion:@escaping([String:Any])->Void) {
        guard let json = jsonString(request), let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("su-zerotier"), FileManager.default.isExecutableFile(atPath:executable.path) else { completion(["ok":false,"error":"ZeroTier helper is not included in this build."]); return }
        zeroTierQueue.async {
            let process = Process(); process.executableURL = executable; let input = Pipe(), output = Pipe(), errors = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = errors
            do {
                try process.run(); input.fileHandleForWriting.write(Data((json+"\n").utf8)); try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                let result = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? ["ok":false,"error":"ZeroTier helper returned no readable status."]
                RunLoop.main.perform(inModes:[.default,.modalPanel,.eventTracking]) { completion(result) }
            } catch { RunLoop.main.perform(inModes:[.default,.modalPanel,.eventTracking]) { completion(["ok":false,"error":"Unable to launch the ZeroTier helper."]) } }
        }
    }
    @objc private func zeroTierAction() {
        statusLabel.stringValue = "Checking local ZeroTier service…"
        runZeroTier(["action":"status"]) { [weak self] result in self?.showZeroTier(result) }
    }
    private func showZeroTier(_ result:[String:Any]) {
        zeroTierStatus = result
        let networks = result["networks"] as? [[String:Any]] ?? []
        let alert = NSAlert(); alert.messageText = "ZeroTier connection policy"
        let available = result["ok"] as? Bool == true
        let status = available ? ((result["online"] as? Bool == true) ? "ZeroTier is online." : "ZeroTier is installed but offline.") : (result["message"] as? String ?? result["error"] as? String ?? "The local ZeroTier service is unavailable or its token cannot be read.")
        alert.informativeText = status + "\nChoose a network for this preset. Only checked networks below may be temporarily left; their original settings will be restored when you disconnect. Other networks are untouched."
        let container = NSView(frame:NSRect(x:0,y:0,width:540,height:220+min(8,networks.count)*28))
        let desiredLabel = label("REQUIRED NETWORK ID (blank disables automatic switching)"); desiredLabel.frame = NSRect(x:0,y:container.frame.height-24,width:530,height:22); container.addSubview(desiredLabel)
        let desired = NSTextField(string:zeroTierNetwork ?? ""); desired.placeholderString = "16 hexadecimal characters"; desired.frame = NSRect(x:0,y:container.frame.height-56,width:530,height:24); container.addSubview(desired)
        var checkboxes:[NSButton] = []
        for (index,n) in networks.prefix(8).enumerated() {
            let id = n["id"] as? String ?? "", name = n["name"] as? String ?? "", state = n["status"] as? String ?? "Unknown", addresses = (n["assignedAddresses"] as? [String] ?? []).joined(separator:", ")
            let b = NSButton(checkboxWithTitle:"\(id)  \(name) · \(state)",target:nil,action:nil); b.frame = NSRect(x:0,y:container.frame.height-92-CGFloat(index)*28,width:530,height:24); b.identifier = NSUserInterfaceItemIdentifier(id); b.toolTip = addresses; b.state = zeroTierManaged.contains(id) ? .on : .off; container.addSubview(b); checkboxes.append(b)
        }
        let text = NSTextField(wrappingLabelWithString:"Exclusivity applies when you click Connect or recall this saved connection. Check only networks this app should manage. A checked network with the required ID stays joined. Hover over a network to see its addresses.\n\nPending recovery transactions: \((result["pendingTransactions"] as? [Any])?.count ?? 0)")
        text.frame = NSRect(x:0,y:5,width:530,height:135); text.font = .systemFont(ofSize:12); container.addSubview(text); alert.accessoryView = container
        alert.addButton(withTitle:"Use for this preset"); alert.addButton(withTitle:"Cancel")
        let pending = result["pendingTransactions"] as? [[String:Any]] ?? []
        if !pending.isEmpty { alert.addButton(withTitle:"Recover previous changes…") }
        let response = alert.runModal()
        if response == .alertThirdButtonReturn { showZeroTierRecovery(pending); return }
        guard response == .alertFirstButtonReturn else { return }
        let id = desired.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard id.isEmpty || id.range(of:"^[0-9a-f]{16}$",options:.regularExpression) != nil else { statusLabel.stringValue = "ZeroTier network IDs must contain 16 hexadecimal characters."; return }
        zeroTierNetwork = id.isEmpty ? nil : id
        zeroTierManaged = checkboxes.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }
        statusLabel.stringValue = "ZeroTier policy selected. Save the preset to keep it."
    }
    private func showZeroTierRecovery(_ pending:[[String:Any]]) {
        let alert = NSAlert(); alert.messageText = "Recover ZeroTier changes"
        alert.informativeText = "Restore a previous connection's network settings, or keep the current network state and clear its recovery record. Restoring checks for outside changes before modifying anything."
        let popup = NSPopUpButton(frame:NSRect(x:0,y:0,width:500,height:28))
        for transaction in pending {
            let id = transaction["transactionId"] as? String ?? "", network = transaction["networkId"] as? String ?? "", phase = transaction["phase"] as? String ?? ""
            popup.addItem(withTitle:"\(network) · \(phase) · \(id.prefix(8))"); popup.lastItem?.representedObject = id
        }
        alert.accessoryView = popup; alert.addButton(withTitle:"Restore selected"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Keep current networks…")
        let response = alert.runModal(); guard response != .alertSecondButtonReturn, let id = popup.selectedItem?.representedObject as? String else { return }
        var action = "restore"
        if response == .alertThirdButtonReturn {
            let confirm = NSAlert(); confirm.messageText = "Keep the current networks?"; confirm.informativeText = "This clears the selected recovery record without changing any ZeroTier networks. The saved earlier settings will no longer be available for automatic restoration."; confirm.addButton(withTitle:"Keep networks and clear record"); confirm.addButton(withTitle:"Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }; action = "forget"
        }
        runZeroTier(["action":action,"transactionId":id]) { [weak self] result in
            if result["ok"] as? Bool == true { self?.zeroTierAction() }
            else { let error = NSAlert(); error.messageText = "ZeroTier recovery needs attention"; error.informativeText = result["message"] as? String ?? "The helper could not complete recovery."; error.runModal() }
        }
    }
    func runIntegration(port:Int,password:String,fingerprint:String,report:String,snapshot:String) {
        testing = true; transport.testFingerprint = fingerprint
        hostField.stringValue = "127.0.0.1"; portField.stringValue = String(port); passwordField.stringValue = password; connectAction()
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            self.allMonitorsAction()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+5) {
            self.exportSnapshot(path:snapshot)
            let result:[String:Any] = ["connected":self.ready,"revision":self.revision,"framesDecoded":self.totalFrames,"framesRejected":self.rejectedFrames,"selected":self.selectedMonitors.map(\.id),"bytesReceived":self.bytesReceived,"status":self.statusLabel.stringValue]
            if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:report)) }
            self.disconnect(); NSApp.terminate(nil)
        }
    }
    func showDemo() {
        demo = true; ready = true; monitors = [RemoteMonitor(id:"demo-1",name:"Studio controls",width:3840,height:2160,number:1),RemoteMonitor(id:"demo-2",name:"Video edit",width:2560,height:1440,number:2),RemoteMonitor(id:"demo-3",name:"Playback",width:1920,height:1080,number:3)]
        selected = ["demo-1","demo-3"]; resolutionPopup.selectItem(at:1); colorPopup.selectItem(at:0); refreshMonitorButtons(); validateResolution(); rebuildCanvases()
        for monitor in selectedMonitors { canvases[monitor.id]?.demoImage(monitor.number) }
        hostField.stringValue = "Demo · no server connection"; statusLabel.stringValue = "Demo only · no capture, input, audio, or network connection to a server."; metricsLabel.stringValue = "2 selected · HD · one session"; connectButton.title = "Connect"
    }
    func exportSnapshot(path:String) {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded(); layoutCanvases()
        content.window?.appearance?.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            if let context = NSGraphicsContext(bitmapImageRep:bitmap) { NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context; NSColor.windowBackgroundColor.setFill(); content.bounds.fill(); NSGraphicsContext.restoreGraphicsState() }
            content.cacheDisplay(in:content.bounds,to:bitmap)
            if let png = bitmap.representation(using:.png,properties:[:]) { try? png.write(to:URL(fileURLWithPath:path)) }
        }
        }
    }
}
