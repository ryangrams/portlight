import AppKit
import Network
import Security

final class ViewerController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let productName = "Portlight"
    private let connectionsWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:520),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    private let advancedButton = NSButton()
    private let allowControlButton = NSButton(checkboxWithTitle:"Allow control",target:nil,action:nil)
    private let panningPopup = NSPopUpButton()
    private let bandwidthLimitField = NSComboBox()
    private var connecting = false
    private struct ConnectionRequest { let host:String, port:Int, password:String, network:String?, managed:[String] }
    private var connectionAttempt = UUID()
    private var pendingConnection: (attempt:UUID, request:ConnectionRequest)?
    private var activationInFlight = false
    private var restorationInFlight = false
    private var pendingQuit: (()->Void)?
    private var testTransportConnect: ((String,Int,String)->Void)?
    private var testZeroTier: (([String:Any],@escaping([String:Any])->Void)->Void)?
    private let advancedStack = NSStackView()
    private let savedConnectionsStack = NSStackView()
    private let savedTable = NSTableView()
    private let emptySavedLabel = NSTextField(wrappingLabelWithString:"Save a connection to find it here next time.")
    private var savedRows: [(id:String,name:String,host:String)] = []
    private var updatingSavedTable = false
    private let sessionNameLabel = NSTextField(labelWithString:"")
    private let sessionStatusLabel = NSTextField(labelWithString:"")
    private var serverName = ""
    private var pendingFullScreen: Bool?
    private var toolbarDisplays: NSButton?
    private var toolbarZoom: NSButton?
    private var toolbarAudio: NSButton?
    private var toolbarSettings: NSButton?
    private var activePopover: NSPopover?
    private var sessionErrorAlert: NSAlert?
    private var screenshotFixture = false
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
    private let statusLabel = NSTextField(labelWithString:"Choose a computer to connect.")
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
        w.title = productName; w.minSize = NSSize(width:660,height:420); w.center()
        super.init(window:w); w.delegate = self; w.acceptsMouseMovedEvents = true
        connectionsWindow.title = "Connections"; connectionsWindow.minSize = NSSize(width:680,height:500); connectionsWindow.center(); connectionsWindow.delegate = self
        connectionsWindow.isReleasedWhenClosed = false; w.isReleasedWhenClosed = false
        w.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .default
        connectionsWindow.animationBehavior = w.animationBehavior
        buildUI(); bindTransport(); reloadPresets()
        osc.onMessage = { [weak self] message,peer in self?.handleOSC(message,peer:peer) }
        osc.onStatus = { [weak self] in self?.metricsLabel.stringValue = $0 }; if !CommandLine.arguments.contains("--ui-snapshot") && !CommandLine.arguments.contains("--ui-check") { osc.start() }
        statsTimer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.updateStats() }
        NotificationCenter.default.addObserver(self,selector:#selector(viewportChanged),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        NotificationCenter.default.addObserver(self,selector:#selector(appDeactivated),name:NSApplication.didResignActiveNotification,object:nil)
        scroll.contentView.postsBoundsChangedNotifications = true
        NSEvent.addLocalMonitorForEvents(matching:[.keyDown]) { [weak self] event in
            if event.keyCode == 3 && event.modifierFlags.contains([.control,.command]), let self { (self.ready ? self.window : self.connectionsWindow)?.toggleFullScreen(nil); return nil }
            if event.keyCode == 53 && event.modifierFlags.contains([.control,.option]) { self?.releaseInput(); self?.window?.makeFirstResponder(nil); return nil }; return event
        }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func label(_ text:String) -> NSTextField { let l = NSTextField(labelWithString:text); l.font = .systemFont(ofSize:11,weight:.medium); l.textColor = .secondaryLabelColor; return l }
    private func button(_ title:String,_ action:Selector) -> NSButton { NSButton(title:title,target:self,action:action) }
    private func row(_ items:[NSView],spacing:CGFloat = 8) -> NSStackView { let r = NSStackView(views:items); r.orientation = .horizontal; r.spacing = spacing; r.alignment = .centerY; return r }
    private func buildUI() {
        configureControls()
        buildConnectionsWindow()
        buildViewingWindow()
    }
    private func configureControls() {
        hostField.placeholderString = "Computer name or IP address"
        hostField.font = .systemFont(ofSize:14); hostField.controlSize = .large
        hostField.setAccessibilityLabel("Computer address")
        passwordField.placeholderString = "Password"; passwordField.font = .systemFont(ofSize:14); passwordField.controlSize = .large
        passwordField.setAccessibilityLabel("Connection password")
        passwordField.target = self; passwordField.action = #selector(connectAction)
        portField.setAccessibilityLabel("Connection port")
        connectButton.target = self; connectButton.action = #selector(connectAction); connectButton.bezelStyle = .rounded; connectButton.controlSize = .large; connectButton.keyEquivalent = "\r"
        connectButton.contentTintColor = .white; connectButton.bezelColor = .controlAccentColor
        connectButton.setAccessibilityLabel("Connect to computer")
        resolutionPopup.addItems(withTitles:Resolution.allCases.map(\.label)); resolutionPopup.selectItem(at:2)
        colorPopup.addItems(withTitles:["Full color","256 colors","16-bit color","Grayscale · 16 shades"])
        qualityPopup.addItems(withTitles:["Automatic","Text & controls","Video"])
        fpsPopup.addItems(withTitles:["5 fps","10 fps","15 fps","30 fps","60 fps"]); fpsPopup.selectItem(at:2)
        for popup in [resolutionPopup,colorPopup,qualityPopup,fpsPopup] { popup.target = self; popup.action = #selector(settingsAction) }
        resolutionPopup.setAccessibilityLabel("Display resolution"); colorPopup.setAccessibilityLabel("Color depth"); qualityPopup.setAccessibilityLabel("Picture priority"); fpsPopup.setAccessibilityLabel("Frame rate")
        bandwidthField.target = self; bandwidthField.action = #selector(settingsAction); bandwidthField.setAccessibilityLabel("Bandwidth limit in kilobits per second")
        for b in [pauseButton,audioButton,viewOnlyButton,followButton] { b.target = self; b.action = #selector(settingsAction) }
        followButton.title = "Pan as the pointer reaches an edge"
        viewOnlyButton.title = "View only"; pauseButton.title = "Pause streaming"
        allowControlButton.state = .on; allowControlButton.target = self; allowControlButton.action = #selector(allowControlAction)
        panningPopup.addItems(withTitles:["Scroll","Follow pointer"]); panningPopup.target = self; panningPopup.action = #selector(panningAction)
        bandwidthLimitField.addItems(withObjectValues:["Automatic","1","2","4","8","16"]); bandwidthLimitField.stringValue = "4"; bandwidthLimitField.target = self; bandwidthLimitField.action = #selector(bandwidthAction)
        bandwidthLimitField.setAccessibilityLabel("Bandwidth limit in megabits per second")
        allowControlButton.setAccessibilityLabel("Allow remote control"); panningPopup.setAccessibilityLabel("Panning mode")
        audioButton.toolTip = "Play this computer’s system audio"; audioButton.setAccessibilityLabel("System audio")
        statusLabel.stringValue = ""; statusLabel.font = .systemFont(ofSize:12); statusLabel.textColor = .secondaryLabelColor; statusLabel.maximumNumberOfLines = 2; statusLabel.lineBreakMode = .byWordWrapping
        metricsLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); metricsLabel.textColor = .secondaryLabelColor
    }
    private func buildConnectionsWindow() {
        guard let content = connectionsWindow.contentView else { return }
        let sidebar = material(.sidebar); sidebar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(sidebar)
        let main = material(.underWindowBackground); main.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(main)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo:content.leadingAnchor),sidebar.topAnchor.constraint(equalTo:content.topAnchor),sidebar.bottomAnchor.constraint(equalTo:content.bottomAnchor),sidebar.widthAnchor.constraint(equalToConstant:216),main.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor),main.trailingAnchor.constraint(equalTo:content.trailingAnchor),main.topAnchor.constraint(equalTo:content.topAnchor),main.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
        let sidebarTitle = NSTextField(labelWithString:"Saved connections"); sidebarTitle.font = .systemFont(ofSize:12,weight:.semibold); sidebarTitle.textColor = .secondaryLabelColor; sidebarTitle.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(sidebarTitle)
        let listScroll = NSScrollView(); listScroll.drawsBackground = false; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true; listScroll.borderType = .noBorder; listScroll.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(listScroll)
        let column = NSTableColumn(identifier:.init("connection")); column.width = 208; savedTable.addTableColumn(column); savedTable.headerView = nil; savedTable.rowHeight = 56; savedTable.intercellSpacing = NSSize(width:0,height:4); savedTable.backgroundColor = .clear; savedTable.style = .sourceList; savedTable.allowsEmptySelection = true
        savedTable.dataSource = self; savedTable.delegate = self; savedTable.target = self; savedTable.doubleAction = #selector(savedTableConnect); savedTable.setAccessibilityLabel("Saved connections")
        listScroll.documentView = savedTable
        let newConnection = toolbarButton("New connection",symbol:"plus",action:#selector(newConnectionAction)); newConnection.bezelStyle = .recessed; newConnection.isBordered = false; newConnection.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(newConnection)
        emptySavedLabel.font = .systemFont(ofSize:12); emptySavedLabel.textColor = .secondaryLabelColor; emptySavedLabel.maximumNumberOfLines = 0; emptySavedLabel.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(emptySavedLabel)
        NSLayoutConstraint.activate([sidebarTitle.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:16),sidebarTitle.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:24),listScroll.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:8),listScroll.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-8),listScroll.topAnchor.constraint(equalTo:sidebarTitle.bottomAnchor,constant:12),listScroll.bottomAnchor.constraint(equalTo:newConnection.topAnchor,constant:-16),newConnection.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:16),newConnection.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-20),emptySavedLabel.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:20),emptySavedLabel.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-20),emptySavedLabel.topAnchor.constraint(equalTo:listScroll.topAnchor,constant:12)])
        let root = vertical(spacing:24); root.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(root)
        NSLayoutConstraint.activate([root.centerXAnchor.constraint(equalTo:main.centerXAnchor),root.topAnchor.constraint(equalTo:main.topAnchor,constant:32),root.widthAnchor.constraint(equalToConstant:372),root.bottomAnchor.constraint(lessThanOrEqualTo:main.bottomAnchor,constant:-24)])
        let brandImage = Bundle.main.url(forResource:"Portlight",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
        let mark = NSImageView(image:brandImage ?? NSImage(systemSymbolName:"rectangle.on.rectangle",accessibilityDescription:productName) ?? NSImage()); mark.widthAnchor.constraint(equalToConstant:64).isActive = true; mark.heightAnchor.constraint(equalToConstant:64).isActive = true
        let title = NSTextField(labelWithString:productName); title.font = .systemFont(ofSize:28,weight:.bold)
        let subtitle = NSTextField(labelWithString:"Your screens, closer."); subtitle.font = .systemFont(ofSize:13); subtitle.textColor = .secondaryLabelColor
        let heroText = vertical(spacing:4); heroText.addArrangedSubview(title); heroText.addArrangedSubview(subtitle)
        let hero = row([mark,heroText],spacing:16); root.addArrangedSubview(hero)
        let form = vertical(spacing:16)
        let computerGroup = fieldGroup("Computer",hostField); form.addArrangedSubview(computerGroup); computerGroup.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true
        let passwordGroup = fieldGroup("Password",passwordField); form.addArrangedSubview(passwordGroup); passwordGroup.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true

        form.addArrangedSubview(connectButton); connectButton.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true; connectButton.heightAnchor.constraint(equalToConstant:34).isActive = true
        advancedButton.title = "Advanced"; advancedButton.image = NSImage(systemSymbolName:"chevron.right",accessibilityDescription:nil); advancedButton.imagePosition = .imageLeading; advancedButton.bezelStyle = .recessed; advancedButton.isBordered = false; advancedButton.setButtonType(.onOff); advancedButton.target = self; advancedButton.action = #selector(advancedAction)
        form.addArrangedSubview(advancedButton)
        root.addArrangedSubview(card(form)); root.arrangedSubviews.last?.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        // Advanced choices are an anchored popover, so the compact connection window never grows.
        advancedStack.orientation = .vertical; advancedStack.alignment = .leading; advancedStack.spacing = 16
        portField.widthAnchor.constraint(equalToConstant:84).isActive = true
        advancedStack.addArrangedSubview(row([label("Port"),portField,NSView(),button("ZeroTier…",#selector(zeroTierAction))]))
        advancedStack.addArrangedSubview(button("Save connection…",#selector(savePresetAction)))
        root.addArrangedSubview(statusLabel); statusLabel.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        let publisher = NSTextField(labelWithString:"by Studio Upgrade"); publisher.font = .systemFont(ofSize:11); publisher.textColor = .secondaryLabelColor; root.addArrangedSubview(publisher)
        connectionsWindow.initialFirstResponder = hostField
        savedTable.nextKeyView = hostField; hostField.nextKeyView = passwordField; passwordField.nextKeyView = connectButton; connectButton.nextKeyView = advancedButton; advancedButton.nextKeyView = savedTable
    }
    func numberOfRows(in tableView:NSTableView) -> Int { savedRows.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard savedRows.indices.contains(row) else { return nil }; let saved = savedRows[row]
        let cell = NSTableCellView(); let icon = NSImageView(image:NSImage(systemSymbolName:"desktopcomputer",accessibilityDescription:nil) ?? NSImage()); icon.contentTintColor = .secondaryLabelColor; icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon)
        let name = NSTextField(labelWithString:saved.name); name.font = .systemFont(ofSize:12,weight:.medium); name.lineBreakMode = .byTruncatingTail
        let address = NSTextField(labelWithString:saved.host); address.font = .systemFont(ofSize:10); address.textColor = .secondaryLabelColor; address.lineBreakMode = .byTruncatingTail
        let labels = vertical(spacing:3); labels.addArrangedSubview(name); labels.addArrangedSubview(address); labels.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(labels)
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:24),icon.heightAnchor.constraint(equalToConstant:24),labels.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:10),labels.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-8),labels.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        cell.setAccessibilityLabel(saved.name + ", " + saved.host); return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !updatingSavedTable, savedRows.indices.contains(savedTable.selectedRow) else { return }
        let saved = savedRows[savedTable.selectedRow]
        if screenshotFixture { hostField.stringValue = saved.host; return }
        if recallPreset(saved.id,connect:false) { statusLabel.stringValue = "" }; connectionsWindow.makeFirstResponder(savedTable)
    }
    @objc private func savedTableConnect() { if savedRows.indices.contains(savedTable.selectedRow) { connectAction() } }
    @objc private func newConnectionAction() {
        if ready || connecting { disconnect() }
        presetID = nil; hostField.stringValue = ""; passwordField.stringValue = ""; portField.stringValue = "5920"; zeroTierNetwork = nil; zeroTierManaged = []; savedTable.deselectAll(nil); statusLabel.stringValue = ""; connectionsWindow.makeFirstResponder(hostField)
    }
    private func buildViewingWindow() {
        guard let window, let content = window.contentView else { return }
        window.title = productName; window.toolbarStyle = .unifiedCompact; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        let toolbar = NSToolbar(identifier:"SU.Remote.SessionToolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false; toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        scroll.documentView = desktop; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .underPageBackgroundColor
        pin(scroll,to:content)
        updateToolbar()
    }
    private func vertical(spacing:CGFloat = 8) -> NSStackView { let v = NSStackView(); v.orientation = .vertical; v.alignment = .leading; v.spacing = spacing; return v }
    private func fieldGroup(_ title:String,_ field:NSView) -> NSStackView {
        let titleLabel = NSTextField(labelWithString:title); titleLabel.font = .systemFont(ofSize:12,weight:.medium)
        let stack = vertical(spacing:6); stack.addArrangedSubview(titleLabel)
        let input:NSView = (field as? NSTextField).map { ConnectionInputView(field:$0) } ?? field
        stack.addArrangedSubview(input); input.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true; return stack
    }
    private func pin(_ child:NSView,to parent:NSView,inset:CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:inset),child.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-inset),child.topAnchor.constraint(equalTo:parent.topAnchor,constant:inset),child.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-inset)])
    }
    private func material(_ kind:NSVisualEffectView.Material) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = kind; view.blendingMode = .withinWindow; view.state = .followsWindowActiveState; return view
    }
    private func card(_ body:NSView) -> NSView {
        let card = ConnectionCard(); pin(body,to:card,inset:20); return card
    }
    private func toolbarButton(_ title:String,symbol:String,action:Selector) -> NSButton {
        let b = NSButton(title:title,image:NSImage(systemSymbolName:symbol,accessibilityDescription:title) ?? NSImage(),target:self,action:action)
        b.bezelStyle = .texturedRounded; b.contentTintColor = .labelColor; b.imagePosition = .imageLeading; b.font = .systemFont(ofSize:12); b.toolTip = title; b.setAccessibilityLabel(title); return b
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] { [.init("connection"),.flexibleSpace,.init("displays"),.init("zoom"),.init("audio"),.init("settings")] }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier:id); item.autovalidates = false; item.isEnabled = true; item.target = self; item.action = #selector(toolbarItemAction(_:))
        switch id.rawValue {
        case "connection":
            sessionNameLabel.font = .systemFont(ofSize:12,weight:.semibold); sessionNameLabel.lineBreakMode = .byTruncatingTail
            sessionNameLabel.widthAnchor.constraint(equalToConstant:210).isActive = true; sessionNameLabel.heightAnchor.constraint(equalToConstant:18).isActive = true
            item.view = sessionNameLabel; item.label = "Connection"
        case "displays": let b = toolbarButton("Displays",symbol:"display.2",action:#selector(displaysAction(_:))); toolbarDisplays = b; item.view = b; item.label = "Displays"
        case "zoom": let b = toolbarButton("Fit",symbol:"arrow.up.left.and.arrow.down.right",action:#selector(zoomMenuAction(_:))); toolbarZoom = b; item.view = b; item.label = "Zoom"
        case "audio": let b = toolbarButton("Audio",symbol:"speaker.slash",action:#selector(audioAction(_:))); toolbarAudio = b; item.view = b; item.label = "Audio"
        case "settings": let b = toolbarButton("",symbol:"slider.horizontal.3",action:#selector(settingsPopoverAction(_:))); b.toolTip = "View settings"; b.setAccessibilityLabel("View settings"); toolbarSettings = b; item.view = b; item.label = "View settings"
        default: return nil
        }
        return item
    }
    @objc private func toolbarItemAction(_ item:NSToolbarItem) {
        switch item.itemIdentifier.rawValue {
        case "displays": if let b = toolbarDisplays { displaysAction(b) }
        case "zoom": if let b = toolbarZoom { zoomMenuAction(b) }
        case "audio": if let b = toolbarAudio { audioAction(b) }
        case "settings": if let b = toolbarSettings { settingsPopoverAction(b) }
        default: break
        }
    }
    private func updateToolbar() {
        let name = serverName.isEmpty ? productName : serverName
        let state = demo ? "Preview" : (paused ? "Paused" : "Connected")
        let title = NSMutableAttributedString(string:name,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:NSColor.labelColor])
        title.append(NSAttributedString(string:"  ·  " + state,attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor]))
        sessionNameLabel.attributedStringValue = title; sessionNameLabel.toolTip = name + " · " + state; sessionNameLabel.setAccessibilityLabel(name + ", " + state)
        toolbarDisplays?.title = "Displays"; toolbarDisplays?.toolTip = "Choose displays · \(selected.count) selected"
        toolbarZoom?.title = autoFit ? "Fit" : "\(Int(zoom*100))%"
        toolbarAudio?.image = NSImage(systemSymbolName:audioButton.state == .on ? "speaker.wave.2" : "speaker.slash",accessibilityDescription:"Audio")
        toolbarAudio?.state = audioButton.state; toolbarAudio?.isEnabled = audioButton.isEnabled
        toolbarAudio?.toolTip = audioButton.state == .on ? "Turn system audio off" : "Turn system audio on"
    }
    private func showPopover(_ body:NSView,anchor:NSView,width:CGFloat) {
        activePopover?.close()
        let controller = NSViewController(); let background = material(.popover); controller.view = background; pin(body,to:background,inset:20)
        if !body.constraints.contains(where: { $0.firstAttribute == .width && $0.secondItem == nil && $0.constant == width }) { body.widthAnchor.constraint(equalToConstant:width).isActive = true }
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion; popover.contentViewController = controller
        let height = body.fittingSize.height+40; popover.contentSize = CGSize(width:width+40,height:height)
        activePopover = popover; popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
    }
    @objc private func displaysAction(_ sender:NSButton) {
        releaseInput(); refreshMonitorButtons()
        let content = vertical(spacing:16); let heading = NSTextField(labelWithString:"Displays"); heading.font = .systemFont(ofSize:17,weight:.semibold); content.addArrangedSubview(heading)
        content.addArrangedSubview(monitorStack)
        let note = NSTextField(wrappingLabelWithString:"Only the displays you choose are streamed."); note.font = .systemFont(ofSize:12); note.textColor = .secondaryLabelColor; note.widthAnchor.constraint(equalToConstant:276).isActive = true; content.addArrangedSubview(note)
        showPopover(content,anchor:sender,width:276)
    }
    @objc private func zoomMenuAction(_ sender:NSButton) {
        releaseInput(); let menu = NSMenu()
        for (title,action) in [("Fit displays",#selector(fitAction)),("Fit this display",#selector(fitMonitorAction)),("Actual size",#selector(actualSizeAction)),("Zoom in",#selector(zoomInAction)),("Zoom out",#selector(zoomOutAction))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY-4),in:sender)
    }
    private func preferenceRow(_ title:String,_ control:NSView) -> NSStackView {
        let name = NSTextField(labelWithString:title); name.font = .systemFont(ofSize:12); name.widthAnchor.constraint(equalToConstant:108).isActive = true
        let r = row([name,control]); r.widthAnchor.constraint(equalToConstant:324).isActive = true; control.setContentHuggingPriority(.defaultLow,for:.horizontal); return r
    }
    private func divider() -> NSBox { let box = NSBox(); box.boxType = .separator; box.widthAnchor.constraint(equalToConstant:324).isActive = true; return box }
    @objc private func settingsPopoverAction(_ sender:NSButton) {
        releaseInput(); syncSettings()
        let content = vertical(spacing:16)
        let heading = NSTextField(labelWithString:"View settings"); heading.font = .systemFont(ofSize:17,weight:.semibold); content.addArrangedSubview(heading)
        let picture = vertical(spacing:12); picture.addArrangedSubview(preferenceRow("Resolution",resolutionPopup)); picture.addArrangedSubview(preferenceRow("Color mode",colorPopup)); picture.addArrangedSubview(preferenceRow("Optimize for",qualityPopup)); picture.addArrangedSubview(preferenceRow("Frame rate",fpsPopup))
        picture.addArrangedSubview(preferenceRow("Bandwidth limit",row([bandwidthLimitField,label("Mbps")],spacing:6))); content.addArrangedSubview(picture)
        content.addArrangedSubview(divider())
        let control = vertical(spacing:12); control.addArrangedSubview(preferenceRow("Panning",panningPopup)); control.addArrangedSubview(allowControlButton); control.addArrangedSubview(pauseButton); content.addArrangedSubview(control)
        content.addArrangedSubview(divider())
        content.addArrangedSubview(row([button("Save connection…",#selector(savePresetAction)),NSView(),button("Disconnect",#selector(disconnectAction))]))
        showPopover(content,anchor:sender,width:324)
    }
    @objc private func allowControlAction() { viewOnlyButton.state = allowControlButton.state == .on ? .off : .on; settingsAction() }
    @objc private func panningAction() { followButton.state = panningPopup.indexOfSelectedItem == 1 ? .on : .off; settingsAction() }
    @objc private func bandwidthAction() {
        let value = bandwidthLimitField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.lowercased() == "automatic" { bandwidthField.stringValue = "0" }
        else if let mbps = Double(value), mbps.isFinite, mbps >= 0 { bandwidthField.stringValue = String(Int(clamp(mbps*1000,0,100000))) }
        settingsAction()
    }
    private func syncSettings() {
        allowControlButton.state = viewOnlyButton.state == .on ? .off : .on
        panningPopup.selectItem(at:followButton.state == .on ? 1 : 0)
        bandwidthLimitField.stringValue = cap == 0 ? "Automatic" : String(format:"%g",Double(cap)/1000)
    }
    @objc private func audioAction(_ sender:NSButton) { audioButton.state = audioButton.state == .on ? .off : .on; settingsAction(); updateToolbar() }
    @objc private func disconnectAction() { activePopover?.close(); disconnect() }
    @objc private func advancedAction() { releaseInput(); showPopover(advancedStack,anchor:advancedButton,width:292); advancedButton.state = .off }
    override func showWindow(_ sender:Any?) { if ready { window?.makeKeyAndOrderFront(sender) } else { connectionsWindow.makeKeyAndOrderFront(sender) } }
    private func presentSession(name:String) {
        serverName = name; activePopover?.close(); connectionsWindow.orderOut(nil); window?.title = name; window?.makeKeyAndOrderFront(nil); updateToolbar(); layoutCanvases()
        if let desired = pendingFullScreen { pendingFullScreen = nil; if desired != (window?.styleMask.contains(.fullScreen) ?? false) { window?.toggleFullScreen(nil) } }
    }
    private func presentConnections() {
        if let alert = sessionErrorAlert { window?.endSheet(alert.window); alert.window.orderOut(nil); sessionErrorAlert = nil }
        activePopover?.close(); window?.orderOut(nil); connectionsWindow.makeKeyAndOrderFront(nil); connectionsWindow.makeFirstResponder(hostField)
    }
    private func showSessionError(_ message:String) {
        guard let window, ready else { return }
        releaseInput(); activePopover?.close()
        if let alert = sessionErrorAlert { alert.informativeText = message; return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "The computer needs attention"; alert.informativeText = message
        alert.addButton(withTitle:"OK"); alert.addButton(withTitle:"Disconnect")
        sessionErrorAlert = alert; let attempt = connectionAttempt
        alert.beginSheetModal(for:window) { [weak self,weak alert] response in
            guard let self else { return }
            if self.sessionErrorAlert === alert { self.sessionErrorAlert = nil }
            if response == .alertSecondButtonReturn && self.connectionAttempt == attempt && self.ready { self.disconnect() }
        }
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
        if ready || connecting { disconnect(); return }
        guard let port = validPort(portField.stringValue), !hostField.stringValue.trimmingCharacters(in:.whitespaces).isEmpty else { statusLabel.stringValue = "Enter a computer address and a port from 1 to 65535."; return }
        connectionAttempt = UUID(); let attempt = connectionAttempt
        let request = ConnectionRequest(host:hostField.stringValue,port:port,password:passwordField.stringValue,network:zeroTierNetwork,managed:zeroTierManaged)
        demo = false; connecting = true; connectButton.title = "Cancel"; connectButton.isEnabled = true; hostField.isEnabled = false; passwordField.isEnabled = false; advancedButton.isEnabled = false
        if activationInFlight || restorationInFlight {
            pendingConnection = (attempt,request); statusLabel.stringValue = "Finishing the previous network change…"; return
        }
        beginConnection(request,attempt:attempt)
    }
    private func beginConnection(_ request:ConnectionRequest,attempt:UUID) {
        guard connectionAttempt == attempt, connecting else { return }
        advancedButton.isEnabled = false
        if !testing { UserDefaults.standard.set(request.host,forKey:"SU.Remote.LastHost"); UserDefaults.standard.set(String(request.port),forKey:"SU.Remote.LastPort") }
        if let network = request.network, zeroTierTransaction == nil {
            activationInFlight = true; statusLabel.stringValue = "Activating the saved ZeroTier network…"
            runZeroTier(["action":"activate","networkId":network,"managedNetworkIds":request.managed,"sessionId":sessionID]) { [weak self] result in
                guard let self else { return }
                guard self.connectionAttempt == attempt, self.connecting else {
                    if let transaction = result["transactionId"] as? String {
                        self.runZeroTier(["action":"restore","transactionId":transaction]) { [weak self] restored in
                            guard let self else { return }
                            let succeeded = restored["ok"] as? Bool == true
                            self.statusLabel.stringValue = succeeded ? "Connection canceled." : "Connection canceled. ZeroTier restoration needs attention."
                            self.finishNetworkChange(succeeded:succeeded)
                        }
                    } else { self.finishNetworkChange() }
                    return
                }
                self.activationInFlight = false
                guard result["ok"] as? Bool == true else {
                    self.connecting = false; self.connectButton.title = "Connect"; self.hostField.isEnabled = true; self.passwordField.isEnabled = true; self.advancedButton.isEnabled = true
                    self.statusLabel.stringValue = result["message"] as? String ?? result["error"] as? String ?? "ZeroTier activation failed."; return
                }
                self.zeroTierTransaction = result["transactionId"] as? String
                self.startTransport(host:request.host,port:request.port,password:request.password)
            }
        } else { startTransport(host:request.host,port:request.port,password:request.password) }
    }
    private func startTransport(host:String,port:Int,password:String) {
        if let testTransportConnect { testTransportConnect(host,port,password); return }
        transport.connect(host:host,port:port,password:password)
    }
    private func finishNetworkChange(succeeded:Bool = true) {
        activationInFlight = false; restorationInFlight = false; connectButton.isEnabled = true; advancedButton.isEnabled = true
        if let completion = pendingQuit { pendingQuit = nil; pendingConnection = nil; completion(); return }
        if let pending = pendingConnection {
            pendingConnection = nil
            if succeeded { beginConnection(pending.request,attempt:pending.attempt) }
            else { connecting = false; connectButton.title = "Connect"; hostField.isEnabled = true; passwordField.isEnabled = true }
        }
    }
    private func disconnect() { connectionAttempt = UUID(); pendingConnection = nil; releaseInput(); transport.disconnect(); didDisconnect(); statusLabel.stringValue = "Disconnected." }
    private func didDisconnect() {
        ready = false; connecting = false; acceptedRevision = -1; connectButton.title = "Connect"; connectButton.isEnabled = !activationInFlight && !restorationInFlight; advancedButton.isEnabled = connectButton.isEnabled; hostField.isEnabled = true; passwordField.isEnabled = true; presentConnections(); audio.stop(); pointerButtons = 0; pressedKeys.removeAll(); modifiers = []
        if let transaction = zeroTierTransaction {
            zeroTierTransaction = nil; restorationInFlight = true; connectButton.isEnabled = false; advancedButton.isEnabled = false
            runZeroTier(["action":"restore","transactionId":transaction]) { [weak self] result in
                guard let self else { return }
                if result["ok"] as? Bool != true { self.statusLabel.stringValue = "Disconnected; ZeroTier restore needs attention." }
                self.finishNetworkChange(succeeded:result["ok"] as? Bool == true)
            }
        }
    }
    private func receive(_ object:[String:Any],data:Data?) {
        guard let type = object["type"] as? String else { return }
        switch type {
        case "welcome","displays":
            guard let rows = object["displays"] as? [[String:Any]], rows.count <= 32 else { statusLabel.stringValue = "The computer sent an invalid display list."; return }
            var parsed: [RemoteMonitor] = []
            for (index,row) in rows.enumerated() {
                guard let id = row["id"] as? String, let width = row["width"] as? Int, let height = row["height"] as? Int, width > 0, height > 0, width <= 32768, height <= 32768, !parsed.contains(where:{$0.id == id}) else { continue }
                parsed.append(RemoteMonitor(id:id,name:row["name"] as? String ?? "Display \(index+1)",width:width,height:height,number:index+1))
            }
            releaseInput(); let firstWelcome = !ready; monitors = parsed; ready = true; connecting = false; hostField.isEnabled = true; passwordField.isEnabled = true; advancedButton.isEnabled = true; connectButton.title = "Connect"
            let available = Set(parsed.map(\.id))
            if let pending = pendingMonitorIDs { selected = pending.intersection(available); pendingMonitorIDs = nil }
            else if firstWelcome { selected = parsed.first.map { [$0.id] } ?? [] }
            else { selected = selected.intersection(available) }
            if let capabilities = object["capabilities"] as? [String:Any], let audioCodecs = capabilities["audio"] as? [String] { audioButton.isEnabled = audioCodecs.contains("mulaw"); if !audioButton.isEnabled { audioButton.state = .off } }
            presentSession(name:object["serverName"] as? String ?? hostField.stringValue)
            refreshMonitorButtons(); validateResolution(); rebuildCanvases(); scheduleSubscription(immediate:true)
            statusLabel.stringValue = "Connected to \(object["serverName"] as? String ?? hostField.stringValue). Choose the displays to view."
        case "subscribed":
            guard let ack = object["revision"] as? Int, ack == revision, let displays = object["displays"] as? [[String:Any]] else { return }
            let sizes = displays.compactMap { row -> (Int,Int)? in
                guard let w = row["width"] as? Int, let h = row["height"] as? Int else { return nil }; return (w,h)
            }
            guard sizes.count == displays.count, sizes.allSatisfy({validCanvasDimensions(width:$0.0,height:$0.1)}), sizes.reduce(0.0,{$0+Double($1.0)*Double($1.1)}) <= maxViewerCanvasPixels else {
                disconnect(); statusLabel.stringValue = "The computer requested an unsupported display size. Maximum UHD per display and four UHD displays total."; return
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
        case "error":
            let message = object["message"] as? String ?? "The computer reported an error."
            if object["code"] as? String == "authentication" { disconnect(); statusLabel.stringValue = message }
            else { statusLabel.stringValue = message; if ready { showSessionError(message) } }
        case "stats": break
        default: break
        }
    }
    private func refreshMonitorButtons() {
        monitorStack.orientation = .vertical; monitorStack.alignment = .leading; monitorStack.spacing = 14
        for v in monitorStack.arrangedSubviews { monitorStack.removeArrangedSubview(v); v.removeFromSuperview() }
        monitorButtons = []
        for (i,m) in monitors.enumerated() {
            let b = NSButton(checkboxWithTitle:m.label,target:self,action:#selector(monitorAction(_:))); b.tag = i; b.state = selected.contains(m.id) ? .on : .off; b.toolTip = "\(m.width) × \(m.height) native pixels"; monitorStack.addArrangedSubview(b); monitorButtons.append(b)
        }
        monitorStack.addArrangedSubview(button("Select all displays",#selector(allMonitorsAction)))
        updateToolbar()
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
        guard resolutionFitsBudget(resolution) else { for canvas in canvases.values { canvas.removeFromSuperview() }; canvases.removeAll(); statusLabel.stringValue = "Choose fewer displays to stay within the viewer memory limit."; return }
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
        let renderedWidth = (x > 0 ? x-12 : 0)*zoom, renderedHeight = maxHeight*zoom
        let offsetX = max(0,(scroll.contentSize.width-renderedWidth)/2), offsetY = max(0,(scroll.contentSize.height-renderedHeight)/2)
        for canvas in canvases.values { canvas.frame.origin.x += offsetX; canvas.frame.origin.y += offsetY }
        desktop.frame = CGRect(x:0,y:0,width:max(scroll.contentSize.width,renderedWidth),height:max(scroll.contentSize.height,renderedHeight))
        updateToolbar()
        zoomLabel.stringValue = autoFit ? "Fit \(Int(zoom*100))%" : "\(Int(zoom*100))%"
    }
    @objc private func settingsAction() {
        releaseInput(); bandwidthField.stringValue = String(cap); syncSettings(); validateResolution(); rebuildCanvases()
        if audioButton.state != .on || paused { audio.stop() }
        if demo { for (index,m) in selectedMonitors.enumerated() { canvases[m.id]?.demoImage(index+1) } }
        updateToolbar(); scheduleSubscription()
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
    func windowShouldClose(_ sender:NSWindow) -> Bool { if sender === window { disconnect(); return false }; NSApp.terminate(nil); return false }
    func prepareToQuit(_ completion:@escaping()->Void) {
        connectionAttempt = UUID(); pendingConnection = nil; connecting = false
        if activationInFlight || restorationInFlight { pendingQuit = completion; releaseInput(); transport.disconnect(); audio.stop(); osc.stop(); statsTimer?.invalidate(); return }
        releaseInput(); transport.disconnect(); audio.stop(); osc.stop(); statsTimer?.invalidate()
        if let transaction = zeroTierTransaction {
            zeroTierTransaction = nil; restorationInFlight = true; pendingQuit = completion
            runZeroTier(["action":"restore","transactionId":transaction]) { [weak self] result in
                if result["ok"] as? Bool != true { self?.statusLabel.stringValue = "ZeroTier restore needs attention; recovery transaction is saved." }
                self?.finishNetworkChange(succeeded:result["ok"] as? Bool == true)
            }
        } else { RunLoop.main.perform(inModes:[.default,.modalPanel,.eventTracking],block:completion) }
    }
    private func reloadPresets() {
        updatingSavedTable = true
        savedRows = presets.presets.map { ($0.id,$0.name,$0.host) }
        if screenshotFixture { savedRows = [("preview-editing","Editing Mac","editing-mac.local"),("preview-studio","Studio Mac","studio-mac.local")] }
        savedTable.reloadData(); emptySavedLabel.isHidden = !savedRows.isEmpty
        if screenshotFixture { savedTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
        updatingSavedTable = false
        presetPopup.removeAllItems(); presetPopup.addItem(withTitle:"Saved connections")
        for p in presets.presets { presetPopup.addItem(withTitle:p.name); presetPopup.lastItem?.representedObject = p.id }
    }
    @objc private func savedConnectionAction(_ sender:NSButton) { if let id = sender.identifier?.rawValue { _ = recallPreset(id,connect:false) } }
    @objc private func savePresetAction() {
        activePopover?.close()
        let alert = NSAlert(); alert.messageText = "Save connection and view"; alert.informativeText = "Stores the computer, selected displays, picture settings, view controls, and any ZeroTier settings. Passwords can be stored separately in your macOS Keychain."
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
        pendingFullScreen = p.fullScreen
        statusLabel.stringValue = "Loaded \(p.name)."; if connect { connectAction() }; return true
    }
    private func savePassword(_ password:String,preset:String) {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"studio.upgrade.remote.viewer",kSecAttrAccount as String:preset]
        SecItemDelete(query as CFDictionary); var item = query; item[kSecValueData as String] = Data(password.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary,nil) != errSecSuccess { statusLabel.stringValue = "Connection saved; its password could not be stored in Keychain." }
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
            guard let value = firstString(), !value.isEmpty else { error("Expected a saved connection name or computer address"); return }
            if !recallPreset(value,connect:true) { if ready || connecting { disconnect() }; hostField.stringValue = value; connectAction() }
        case "/su/remote/disconnect": disconnect()
        case "/su/remote/preset/recall": if let id = firstString(), recallPreset(id,connect:false) {} else { error("Unknown saved connection") }
        case "/su/remote/monitors/select":
            let ids = m.arguments.compactMap { $0 as? String }; guard ids.count == m.arguments.count, Set(ids).isSubset(of:Set(monitors.map(\.id))) else { error("Unknown display or invalid arguments"); return }
            releaseInput(); selected = Set(ids); refreshMonitorButtons(); validateResolution(); rebuildCanvases(); scheduleSubscription()
        case "/su/remote/resolution":
            guard let value = firstString(), let r = Resolution(rawValue:value), let index = Resolution.allCases.firstIndex(of:r), selectedMonitors.allSatisfy(r.supports), resolutionFitsBudget(r), r != .native else { error("Unsupported resolution for the selected displays"); return }
            resolutionPopup.selectItem(at:index); settingsAction()
        case "/su/remote/color":
            guard let value = firstString(), let i = ["full","color256","rgb565","gray16"].firstIndex(of:value) else { error("Unsupported color mode"); return }; colorPopup.selectItem(at:i); settingsAction()
        case "/su/remote/zoom": guard let value = m.arguments.first as? Double, value >= 0.05, value <= 4 else { error("Zoom must be a float from 0.05 to 4"); return }; setZoom(value)
        case "/su/remote/zoom/fit": fitAction()
        case "/su/remote/pan/mode": guard let mode = firstString(), ["follow","manual"].contains(mode) else { error("Expected follow or manual"); return }; followButton.state = mode == "follow" ? .on : .off
        case "/su/remote/paused": _ = toggle(pauseButton)
        case "/su/remote/viewonly": _ = toggle(viewOnlyButton)
        case "/su/remote/audio": if audioButton.isEnabled { _ = toggle(audioButton) } else { error("Computer audio is unavailable") }
        case "/su/remote/fullscreen": guard let n = m.arguments.first as? Int, n == 0 || n == 1 else { error("Expected 0 or 1"); return }; if (n == 1) != (window?.styleMask.contains(.fullScreen) ?? false) { fullscreenAction() }
        default: error("Unknown OSC action")
        }
    }
    private func runZeroTier(_ request:[String:Any],completion:@escaping([String:Any])->Void) {
        if let testZeroTier { testZeroTier(request,completion); return }
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
        let alert = NSAlert(); alert.messageText = "ZeroTier connection settings"
        let available = result["ok"] as? Bool == true
        let status = available ? ((result["online"] as? Bool == true) ? "ZeroTier is online." : "ZeroTier is installed but offline.") : (result["message"] as? String ?? result["error"] as? String ?? "The local ZeroTier service is unavailable or its token cannot be read.")
        alert.informativeText = status + "\nChoose a network for this saved connection. Only checked networks below may be temporarily left; their original settings will be restored when you disconnect. Other networks are untouched."
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
        alert.addButton(withTitle:"Use for this connection"); alert.addButton(withTitle:"Cancel")
        let pending = result["pendingTransactions"] as? [[String:Any]] ?? []
        if !pending.isEmpty { alert.addButton(withTitle:"Recover previous changes…") }
        let response = alert.runModal()
        if response == .alertThirdButtonReturn { showZeroTierRecovery(pending); return }
        guard response == .alertFirstButtonReturn else { return }
        let id = desired.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard id.isEmpty || id.range(of:"^[0-9a-f]{16}$",options:.regularExpression) != nil else { statusLabel.stringValue = "ZeroTier network IDs must contain 16 hexadecimal characters."; return }
        zeroTierNetwork = id.isEmpty ? nil : id
        zeroTierManaged = checkboxes.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }
        statusLabel.stringValue = "ZeroTier settings selected. Save the connection to keep them."
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
    func runUIRegression(report:String) {
        testing = true
        var checks:[String:Bool] = [:]
        configureScreenshot(stage:"session",appearance:"light",minimum:true,popover:nil)
        checks["separate_session_window"] = window?.isVisible == true && !connectionsWindow.isVisible
        if let canvas = canvases.values.first {
            window?.makeFirstResponder(canvas); pressedKeys.insert(65); physicalKeys[0] = 65; pointerButtons = 1
            window?.makeFirstResponder(nil)
            checks["focus_releases_input"] = pressedKeys.isEmpty && physicalKeys.isEmpty && pointerButtons == 0
        }
        allowControlButton.state = .off; allowControlAction(); checks["allow_control_inverts_view_only"] = viewOnlyButton.state == .on && canvases.values.allSatisfy { $0.viewOnly }
        allowControlButton.state = .on; allowControlAction()
        bandwidthLimitField.stringValue = "2.5"; bandwidthAction(); checks["mbps_maps_to_kbps"] = cap == 2500
        bandwidthLimitField.stringValue = "Automatic"; bandwidthAction(); checks["automatic_bandwidth"] = cap == 0
        panningPopup.selectItem(at:1); panningAction(); checks["panning_action"] = followButton.state == .on
        allMonitorsAction(); resolutionPopup.selectItem(at:4); settingsAction(); checks["common_resolution_limit"] = resolution == .fhd && resolutionPopup.item(at:4)?.isEnabled == false
        setZoom(0.5); checks["zoom_action"] = !autoFit && zoom == 0.5; fitAction(); checks["fit_action"] = autoFit
        window?.appearance = NSAppearance(named:.darkAqua); checks["dark_theme_switch"] = window?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        window?.appearance = nil; checks["automatic_theme_restored"] = window?.appearance == nil
        receive(["type":"error","code":"capture","message":"Allow Screen Recording on the computer."],data:nil)
        checks["session_error_visible_in_viewing_window"] = sessionErrorAlert?.informativeText == "Allow Screen Recording on the computer." && window?.attachedSheet != nil && window?.isVisible == true
        disconnect(); checks["disconnect_returns_to_connections"] = connectionsWindow.isVisible && window?.isVisible == false && sessionErrorAlert == nil
        hostField.stringValue = "synthetic.local"; portField.stringValue = "0"; connectAction(); checks["invalid_port_keeps_setup"] = !connecting && connectionsWindow.isVisible
        portField.stringValue = "5920"; hostField.stringValue = "invalid/computer"; connectAction()
        checks["invalid_address_keeps_setup_editable"] = !connecting && connectionsWindow.isVisible && hostField.isEnabled && passwordField.isEnabled && statusLabel.stringValue == "Enter a host name or IP address and a valid port."
        hostField.stringValue = "synthetic.local"; passwordField.stringValue = "synthetic-password"; zeroTierNetwork = "0123456789abcdef"
        var activationCompletion: (([String:Any])->Void)?
        var restoreCalls = 0, transportCalls = 0
        var connectedHost = "", connectedPort = 0
        testTransportConnect = { host,port,_ in transportCalls += 1; connectedHost = host; connectedPort = port }
        testZeroTier = { request,completion in
            if request["action"] as? String == "activate" { activationCompletion = completion }
            else if request["action"] as? String == "restore" { restoreCalls += 1; completion(["ok":true]) }
            else { completion(["ok":true]) }
        }
        connectAction(); checks["activation_pending"] = connecting && activationInFlight
        connectAction(); activationCompletion?(["ok":true,"transactionId":"synthetic-canceled"])
        checks["cancel_restores_without_connecting"] = transportCalls == 0 && restoreCalls == 1 && !connecting && !activationInFlight && connectButton.isEnabled
        hostField.stringValue = "before-change.local"; connectAction(); hostField.stringValue = "after-change.local"; portField.stringValue = "5999"
        activationCompletion?(["ok":true,"transactionId":"synthetic-completed"])
        checks["connection_uses_attempt_snapshot"] = transportCalls == 1 && connectedHost == "before-change.local" && connectedPort == 5920
        receive(["type":"error","code":"authentication","message":"Incorrect password"],data:nil)
        checks["authentication_error_keeps_setup"] = !ready && !connecting && connectionsWindow.isVisible && hostField.isEnabled && passwordField.isEnabled && statusLabel.stringValue == "Incorrect password"
        var restoreCompletion: (([String:Any])->Void)?, quitCompleted = false
        testZeroTier = { request,completion in if request["action"] as? String == "restore" { restoreCompletion = completion } }
        zeroTierNetwork = nil; zeroTierTransaction = "synthetic-switch-restore"; didDisconnect()
        hostField.stringValue = "queued-computer.local"; portField.stringValue = "5921"; connectAction(); hostField.stringValue = "later-edit.local"
        let callsBeforeRestore = transportCalls
        let switchWaited = pendingConnection != nil && connecting && transportCalls == callsBeforeRestore
        restoreCompletion?(["ok":true])
        checks["connection_switch_resumes_after_restore"] = switchWaited && transportCalls == callsBeforeRestore+1 && connectedHost == "queued-computer.local" && connectedPort == 5921
        disconnect(); zeroTierTransaction = "synthetic-cancel-restore"; didDisconnect(); connectAction(); connectAction()
        let callsBeforeCancel = transportCalls; restoreCompletion?(["ok":true])
        checks["cancel_clears_queued_connection"] = pendingConnection == nil && !connecting && transportCalls == callsBeforeCancel
        zeroTierTransaction = "synthetic-failed-restore"; didDisconnect(); connectAction()
        let callsBeforeFailure = transportCalls; restoreCompletion?(["ok":false])
        checks["failed_restore_blocks_queued_connection"] = pendingConnection == nil && !connecting && transportCalls == callsBeforeFailure
        zeroTierTransaction = "synthetic-pending-restore"; didDisconnect(); connectAction()
        let callsBeforeQuit = transportCalls
        prepareToQuit { quitCompleted = true }
        checks["quit_waits_for_pending_network_restore"] = restorationInFlight && !quitCompleted && pendingConnection == nil
        restoreCompletion?(["ok":true]); checks["quit_completes_after_network_restore"] = quitCompleted && !restorationInFlight && transportCalls == callsBeforeQuit
        testZeroTier = nil; testTransportConnect = nil; zeroTierNetwork = nil
        RemoteTransport.runCallbackRegression { transportChecks in
            checks.merge(transportChecks,uniquingKeysWith:{ _,new in new })
            let result:[String:Any] = ["passed":checks.values.allSatisfy { $0 },"checks":checks]
            if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:report)) }
            NSApp.terminate(nil)
        }
    }
    func runIntegration(port:Int,password:String,fingerprint:String,report:String,snapshot:String) {
        testing = true; transport.testFingerprint = fingerprint
        let startedInConnections = connectionsWindow.isVisible && !(window?.isVisible ?? false)
        hostField.stringValue = "127.0.0.1"; portField.stringValue = String(port); passwordField.stringValue = password; connectAction()
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            self.allMonitorsAction()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+5) {
            self.exportSnapshot(path:snapshot)
            var result:[String:Any] = ["startedInConnections":startedInConnections,"sessionWindowVisible":self.window?.isVisible ?? false,"toolbarControlsEnabled":self.toolbarDisplays?.isEnabled == true && self.toolbarZoom?.isEnabled == true && self.toolbarSettings?.isEnabled == true,"connectionsWindowVisible":self.connectionsWindow.isVisible,"connected":self.ready,"revision":self.revision,"framesDecoded":self.totalFrames,"framesRejected":self.rejectedFrames,"selected":self.selectedMonitors.map(\.id),"bytesReceived":self.bytesReceived,"status":self.statusLabel.stringValue]
            self.disconnect()
            result["returnedToConnections"] = self.connectionsWindow.isVisible && !(self.window?.isVisible ?? false)
            if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:report)) }
            NSApp.terminate(nil)
        }
    }
    func showDemo() {
        demo = true; ready = true; presentSession(name:"Editing Mac"); monitors = [RemoteMonitor(id:"demo-1",name:"Studio controls",width:3840,height:2160,number:1),RemoteMonitor(id:"demo-2",name:"Video edit",width:2560,height:1440,number:2),RemoteMonitor(id:"demo-3",name:"Playback",width:1920,height:1080,number:3)]
        selected = ["demo-1","demo-3"]; resolutionPopup.selectItem(at:1); colorPopup.selectItem(at:0); refreshMonitorButtons(); validateResolution(); rebuildCanvases()
        for monitor in selectedMonitors { canvases[monitor.id]?.demoImage(monitor.number) }
        hostField.stringValue = "Preview · no computer connection"; statusLabel.stringValue = "Demo only · no capture, input, audio, or network connection to a computer."; metricsLabel.stringValue = "2 selected · HD · one session"; connectButton.title = "Connect"
    }
    func configureScreenshot(stage:String,appearance:String,minimum:Bool,popover:String?) {
        testing = true; screenshotFixture = true
        let theme = NSAppearance(named:appearance == "dark" ? .darkAqua : .aqua)
        window?.appearance = theme; connectionsWindow.appearance = theme
        if minimum { window?.setContentSize(NSSize(width:660,height:400)); connectionsWindow.setContentSize(NSSize(width:680,height:472)) }
        hostField.stringValue = "editing-mac.local"; passwordField.stringValue = ""; statusLabel.stringValue = ""; reloadPresets()
        if stage == "session" { showDemo() } else { ready = false; presentConnections() }; NSApp.activate(ignoringOtherApps:true)
        if let popover {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                if popover == "settings", let b = self.toolbarSettings { self.settingsPopoverAction(b) }
                if popover == "displays", let b = self.toolbarDisplays { self.displaysAction(b) }
            }
        }
    }
    func exportSnapshot(path:String) {
        let targetWindow = activePopover?.isShown == true ? activePopover?.contentViewController?.view.window : (ready ? window : connectionsWindow)
        guard let content = targetWindow?.contentView?.superview else { return }
        content.layoutSubtreeIfNeeded(); layoutCanvases()
        (targetWindow?.effectiveAppearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            if let context = NSGraphicsContext(bitmapImageRep:bitmap) { NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context; NSColor.windowBackgroundColor.setFill(); content.bounds.fill(); NSGraphicsContext.restoreGraphicsState() }
            content.cacheDisplay(in:content.bounds,to:bitmap)
            if let png = bitmap.representation(using:.png,properties:[:]) { try? png.write(to:URL(fileURLWithPath:path)) }
        }
        }
    }
}
