import AppKit
import Network
import Security

final class ViewerController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let productName = "Portlight"
    private let connectionsWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:650),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    private let advancedButton = NSButton()
    private let connectionSplit = NSSplitViewController()
    private var connectionSidebar: NSSplitViewItem?
    private var sidebarSizeObservation: NSKeyValueObservation?
    private var lastSidebarWidth: CGFloat = 236
    private var passwordReadCount = 0
    private let saveConnectionButton = NSButton(title:"Save Connection",target:nil,action:nil)
    private let presetNameField = NSTextField(string:"")
    private let rememberPassword = NSButton(checkboxWithTitle:"Remember password in Keychain",target:nil,action:nil)
    private let networkStatusLabel = NSTextField(wrappingLabelWithString:"")
    private let map = DisplayMap(frame:NSRect(x:0,y:0,width:190,height:36))
    private let resolutionButtons = ActiveSegmentedControl()
    private var toolbarPause:NSButton?
    private var toolbarControl:NSButton?
    private var toolbarPan:NSButton?
    private var currentFPS:Double = 0
    private var currentGroup:String?
    private var collapsedGroups = Set<String>()
    private var disconnectZeroTier = false
    private var retainedNetwork:String?
    private var connectionEstablished = false
    private var activeDisconnectZeroTier = false
    private let sessionNetworkLabel = NSTextField(labelWithString:"")
    private var networkFooterHeight:NSLayoutConstraint?
    private let audioQualityPopup = NSPopUpButton()
    private var supportsAAC = false
    private let allowControlButton = NSButton(checkboxWithTitle:"Allow control",target:nil,action:nil)
    private let panningPopup = NSPopUpButton()
    private let bandwidthLimitField = NSComboBox()
    private var connecting = false
    private struct ConnectionRequest { let host:String, port:Int, password:String, network:String?, managed:[String]; var disconnectNetwork:Bool = false }
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
    private lazy var popupSession = ViewerPopupSession { [weak self] object in
        guard let self, self.ready, !self.demo else { return }
        self.transport.send(object)
    }
    private let audio = RemoteAudio()
    private let osc = OSCReceiver()
    private var presets = PresetStore()
    private let hostField = NSTextField(string:UserDefaults.standard.string(forKey:"SU.Remote.LastHost") ?? "")
    private let portField = NSTextField(string:UserDefaults.standard.string(forKey:"SU.Remote.LastPort") ?? "5920")
    private let passwordField = NSSecureTextField(string:"")
    private let connectButton = NSButton(title:"Connect",target:nil,action:nil)
    private let resolutionPopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let colorButtons = ActiveSegmentedControl()
    private let smoothGradients = NSButton(checkboxWithTitle:"Smooth gradients in Video mode",target:nil,action:nil)
    private let qualityPopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let bandwidthField = NSTextField(string:"0")
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
    private var fullscreenTransition = false
    private let helpText = "Click a screen to control it. Option-scroll pans locally. Control-Option-Escape releases remote keys. Audio is off by default."

    init() {
        let w = SessionWindow(contentRect:NSRect(x:0,y:0,width:1220,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = productName; w.minSize = NSSize(width:900,height:150); w.center()
        super.init(window:w); w.delegate = self; w.acceptsMouseMovedEvents = true
        connectionsWindow.title = "Connections"; connectionsWindow.minSize = NSSize(width:611,height:620); connectionsWindow.center(); connectionsWindow.delegate = self
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
        presetNameField.placeholderString = "Saved Connection (optional)"; presetNameField.setAccessibilityLabel("Connection name")
        audioQualityPopup.addItems(withTitles:["Mono · 48 kbps","Stereo · 96 kbps","Stereo · 160 kbps","Stereo · 320 kbps"])
        audioQualityPopup.selectItem(at:1); audioQualityPopup.target = self; audioQualityPopup.action = #selector(settingsAction)
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
        colorPopup.addItems(withTitles:["Full color","256 colors","16 shades of gray"])
        qualityPopup.addItems(withTitles:["Automatic","Text & controls","Video"])
        fpsPopup.addItems(withTitles:["5 fps","10 fps","15 fps","30 fps","60 fps"]); fpsPopup.selectItem(at:4)
        for popup in [resolutionPopup,colorPopup,qualityPopup,fpsPopup] { popup.target = self; popup.action = #selector(settingsAction) }
        resolutionPopup.setAccessibilityLabel("Display resolution"); colorPopup.setAccessibilityLabel("Color depth"); qualityPopup.setAccessibilityLabel("Picture priority"); fpsPopup.setAccessibilityLabel("Frame rate")
        bandwidthField.target = self; bandwidthField.action = #selector(settingsAction); bandwidthField.setAccessibilityLabel("Bandwidth limit in kilobits per second")
        for b in [pauseButton,audioButton,viewOnlyButton,followButton] { b.target = self; b.action = #selector(settingsAction) }
        followButton.title = "Pan as the pointer reaches an edge"
        viewOnlyButton.title = "View only"; pauseButton.title = "Pause streaming"
        allowControlButton.state = .on; allowControlButton.target = self; allowControlButton.action = #selector(allowControlAction)
        panningPopup.addItems(withTitles:["Scroll","Follow pointer"]); panningPopup.target = self; panningPopup.action = #selector(panningAction)
        bandwidthLimitField.addItems(withObjectValues:["Automatic","1","2","4","8","16"]); bandwidthLimitField.stringValue = "Automatic"; bandwidthLimitField.target = self; bandwidthLimitField.action = #selector(bandwidthAction)
        bandwidthLimitField.setAccessibilityLabel("Bandwidth limit in megabits per second")
        allowControlButton.setAccessibilityLabel("Allow remote control"); panningPopup.setAccessibilityLabel("Panning mode")
        audioButton.toolTip = "Play this computer’s system audio"; audioButton.setAccessibilityLabel("System audio")
        statusLabel.stringValue = ""; statusLabel.font = .systemFont(ofSize:12); statusLabel.textColor = .secondaryLabelColor; statusLabel.maximumNumberOfLines = 2; statusLabel.lineBreakMode = .byWordWrapping
        metricsLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); metricsLabel.textColor = .secondaryLabelColor
    }
    private func buildConnectionsWindow() {
        let sidebar = material(.sidebar); sidebar.blendingMode = .behindWindow; sidebar.wantsLayer = true
        let main = NSView(); main.wantsLayer = true
        let mainBackground = material(.underWindowBackground); mainBackground.blendingMode = .withinWindow; pin(mainBackground,to:main,inset:0)
        let sidebarController = NSViewController(); sidebarController.view = sidebar
        let mainController = NSViewController(); mainController.view = main
        let sidebarItem = NSSplitViewItem(sidebarWithViewController:sidebarController); sidebarItem.minimumThickness = 190; sidebarItem.maximumThickness = 320; sidebarItem.canCollapse = true; sidebarItem.preferredThicknessFraction = 0.3; sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        connectionSidebar = sidebarItem
        connectionSplit.addSplitViewItem(sidebarItem)
        let editorItem = NSSplitViewItem(viewController:mainController); editorItem.minimumThickness = 420
        connectionSplit.addSplitViewItem(editorItem)
        sidebarSizeObservation = sidebarItem.observe(\.isCollapsed,options:[.new]) { [weak self] item,_ in self?.updateConnectionWindowMinimum(collapsed:item.isCollapsed) }
        connectionsWindow.contentViewController = connectionSplit
        connectionSplit.splitView.setPosition(236,ofDividerAt:0)
        let toolbar = NSToolbar(identifier:"Portlight.ConnectionsToolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
        connectionsWindow.toolbar = toolbar; connectionsWindow.toolbarStyle = .unified; connectionsWindow.titleVisibility = .hidden

        let listScroll = NSScrollView(); listScroll.drawsBackground = false; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true; listScroll.borderType = .noBorder; listScroll.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(listScroll)
        let column = NSTableColumn(identifier:.init("connection")); column.width = 208; savedTable.addTableColumn(column); savedTable.headerView = nil; savedTable.rowHeight = 27; savedTable.intercellSpacing = NSSize(width:0,height:1); savedTable.backgroundColor = .clear; savedTable.style = .sourceList; savedTable.allowsEmptySelection = true
        savedTable.dataSource = self; savedTable.delegate = self; savedTable.target = self; savedTable.action = #selector(savedTableClick); savedTable.doubleAction = #selector(savedTableConnect); savedTable.setAccessibilityLabel("Saved connections")
        savedTable.registerForDraggedTypes([.init("studio.upgrade.portlight.preset")])
        savedTable.setDraggingSourceOperationMask(.move,forLocal:true)
        listScroll.documentView = savedTable
        let newConnection = toolbarButton("",symbol:"plus",action:#selector(newItemMenu(_:))); newConnection.bezelStyle = .recessed; newConnection.isBordered = false; newConnection.setButtonType(.momentaryChange); (newConnection.cell as? NSButtonCell)?.highlightsBy = .contentsCellMask; newConnection.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(newConnection)
        newConnection.setAccessibilityLabel("Add connection or group")
        let remove = toolbarButton("",symbol:"minus",action:#selector(removeSavedItem)); remove.setAccessibilityLabel("Remove selected connection or group"); remove.bezelStyle = .recessed; remove.isBordered = false; remove.setButtonType(.momentaryChange); (remove.cell as? NSButtonCell)?.highlightsBy = .contentsCellMask; remove.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(remove)
        NSLayoutConstraint.activate([remove.leadingAnchor.constraint(equalTo:newConnection.trailingAnchor,constant:8),remove.centerYAnchor.constraint(equalTo:newConnection.centerYAnchor)])
        emptySavedLabel.font = .systemFont(ofSize:12); emptySavedLabel.textColor = .secondaryLabelColor; emptySavedLabel.maximumNumberOfLines = 0; emptySavedLabel.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(emptySavedLabel)
        NSLayoutConstraint.activate([listScroll.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:8),listScroll.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-8),listScroll.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:12),listScroll.bottomAnchor.constraint(equalTo:newConnection.topAnchor,constant:-16),newConnection.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:16),newConnection.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-20),emptySavedLabel.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:20),emptySavedLabel.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-20),emptySavedLabel.topAnchor.constraint(equalTo:listScroll.topAnchor,constant:12)])
        let root = vertical(spacing:18); root.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(root)
        NSLayoutConstraint.activate([root.centerXAnchor.constraint(equalTo:main.centerXAnchor),root.topAnchor.constraint(equalTo:main.topAnchor,constant:32),root.widthAnchor.constraint(equalToConstant:372),root.bottomAnchor.constraint(lessThanOrEqualTo:main.bottomAnchor,constant:-24)])
        let brandImage = Bundle.main.url(forResource:"Portlight",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
        let mark = NSImageView(image:brandImage ?? NSImage(systemSymbolName:"rectangle.on.rectangle",accessibilityDescription:productName) ?? NSImage()); mark.widthAnchor.constraint(equalToConstant:64).isActive = true; mark.heightAnchor.constraint(equalToConstant:64).isActive = true
        let title = NSTextField(labelWithString:productName); title.font = .systemFont(ofSize:28,weight:.bold)
        let subtitle = NSTextField(labelWithString:"Your screens, closer."); subtitle.font = .systemFont(ofSize:13); subtitle.textColor = .secondaryLabelColor
        let heroText = vertical(spacing:4); heroText.addArrangedSubview(title); heroText.addArrangedSubview(subtitle)
        let hero = row([mark,heroText],spacing:16); root.addArrangedSubview(hero)
        let form = vertical(spacing:14)
        let nameGroup = fieldGroup("Connection name · optional",presetNameField); form.addArrangedSubview(nameGroup); nameGroup.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true
        let computerGroup = fieldGroup("Computer",hostField); form.addArrangedSubview(computerGroup); computerGroup.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true
        let passwordGroup = fieldGroup("Password",passwordField); form.addArrangedSubview(passwordGroup); passwordGroup.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true

        let endpoint = row([label("Port"),portField,NSView()]); portField.widthAnchor.constraint(equalToConstant:66).isActive = true
        form.addArrangedSubview(endpoint); endpoint.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true
        rememberPassword.font = .systemFont(ofSize:11); form.addArrangedSubview(rememberPassword)
        let save = saveConnectionButton; save.target = self; save.action = #selector(savePresetAction); save.bezelStyle = .rounded; let actions = row([save,NSView(),connectButton]); form.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true; connectButton.heightAnchor.constraint(equalToConstant:34).isActive = true
        advancedButton.title = "ZeroTier…"; advancedButton.image = NSImage(systemSymbolName:"network",accessibilityDescription:nil); advancedButton.imagePosition = .imageLeading; advancedButton.bezelStyle = .rounded; advancedButton.target = self; advancedButton.action = #selector(zeroTierAction)
        form.addArrangedSubview(advancedButton)
        networkStatusLabel.font = .systemFont(ofSize:11); networkStatusLabel.textColor = .secondaryLabelColor; form.addArrangedSubview(networkStatusLabel); networkStatusLabel.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true
        root.addArrangedSubview(card(form)); root.arrangedSubviews.last?.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        root.addArrangedSubview(statusLabel); statusLabel.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        let publisher = NSTextField(labelWithString:"by Studio Upgrade"); publisher.font = .systemFont(ofSize:11); publisher.textColor = .secondaryLabelColor; root.addArrangedSubview(publisher)
        connectionsWindow.initialFirstResponder = presetNameField
        connectionsWindow.autorecalculatesKeyViewLoop = false
        savedTable.nextKeyView = presetNameField; presetNameField.nextKeyView = hostField; hostField.nextKeyView = passwordField; passwordField.nextKeyView = portField; portField.nextKeyView = rememberPassword; rememberPassword.nextKeyView = save; save.nextKeyView = connectButton; connectButton.nextKeyView = advancedButton; advancedButton.nextKeyView = savedTable
    }
    func numberOfRows(in tableView:NSTableView) -> Int { savedRows.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard savedRows.indices.contains(row) else { return nil }; let saved = savedRows[row]
        let group = presets.groups.contains { $0.id == saved.id }
        let cell = NSTableCellView()
        let icon = NSImageView(image:NSImage(systemSymbolName:group ? (collapsedGroups.contains(saved.id) ? "chevron.right" : "chevron.down") : "desktopcomputer",accessibilityDescription:nil) ?? NSImage()); icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString:saved.name); name.font = .systemFont(ofSize:12,weight:group ? .semibold : .regular); name.lineBreakMode = .byTruncatingTail
        let address = NSTextField(labelWithString:saved.host); address.font = .systemFont(ofSize:10); address.textColor = .secondaryLabelColor; address.lineBreakMode = .byTruncatingMiddle; address.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let items = self.row([icon,name,address],spacing:7); pin(items,to:cell,inset:3)
        icon.widthAnchor.constraint(equalToConstant:group ? 12 : 18).isActive = true
        if !group && presets.presets.first(where:{$0.id == saved.id})?.groupID != nil { items.edgeInsets.left = 16 }
        cell.setAccessibilityLabel(saved.name + (group ? ", group" : ", " + saved.host)); return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !updatingSavedTable, savedRows.indices.contains(savedTable.selectedRow) else { return }
        let saved = savedRows[savedTable.selectedRow]
        if presets.groups.contains(where:{$0.id == saved.id}) { currentGroup = saved.id; return }
        if screenshotFixture { hostField.stringValue = saved.host; return }
        if recallPreset(saved.id,connect:false) { statusLabel.stringValue = "" }; connectionsWindow.makeFirstResponder(savedTable)
    }
    @objc private func savedTableClick() {
        guard savedRows.indices.contains(savedTable.clickedRow) else { return }
        let id = savedRows[savedTable.clickedRow].id
        toggleSavedGroup(id)
    }
    private func toggleSavedGroup(_ id:String) {
        guard presets.groups.contains(where:{$0.id == id}) else { return }
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
        currentGroup = id; reloadPresets()
    }
    @objc private func savedTableConnect() {
        guard savedRows.indices.contains(savedTable.clickedRow) else { return }
        let id = savedRows[savedTable.clickedRow].id
        guard !presets.groups.contains(where:{$0.id == id}) else { return }
        if presetID != id { _ = recallPreset(id,connect:false) }
        connectAction()
    }
    @objc private func newConnectionAction() {
        if ready || connecting { disconnect() }
        presetID = nil; saveConnectionButton.title = "Save Connection"; passwordField.placeholderString = "Password"; presetNameField.stringValue = ""; hostField.stringValue = ""; passwordField.stringValue = ""; portField.stringValue = "5920"; zeroTierNetwork = nil; zeroTierManaged = []; disconnectZeroTier = false; updateNetworkStatus(); savedTable.deselectAll(nil); statusLabel.stringValue = ""; connectionsWindow.makeFirstResponder(presetNameField)
    }
    private func updateConnectionWindowMinimum(collapsed:Bool) {
        connectionsWindow.minSize = NSSize(width:collapsed ? 420 : 611,height:620)
        guard !collapsed, !connectionsWindow.styleMask.contains(.fullScreen) else { return }
        let needed = 420 + max(190,lastSidebarWidth) + connectionSplit.splitView.dividerThickness
        guard connectionsWindow.frame.width < needed else { return }
        var frame = connectionsWindow.frame; frame.size.width = needed
        if let screen = connectionsWindow.screen { frame.origin.x = max(screen.visibleFrame.minX,min(frame.minX,screen.visibleFrame.maxX-frame.width)) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { connectionsWindow.setFrame(frame,display:true) }
        else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.28; context.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut); connectionsWindow.animator().setFrame(frame,display:true) } }
    }
    @objc private func toggleConnectionSidebar() {
        guard let sidebar = connectionSidebar else { return }
        connectionSplit.view.layoutSubtreeIfNeeded()
        let collapsed = !sidebar.isCollapsed
        if collapsed { lastSidebarWidth = max(190,connectionSplit.splitView.arrangedSubviews.first?.frame.width ?? 236) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { sidebar.isCollapsed = collapsed; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            context.allowsImplicitAnimation = true
            sidebar.animator().isCollapsed = collapsed
        }
    }
    func checkSidebarMotion(report:String) {
        connectionsWindow.makeKeyAndOrderFront(nil)
        connectionSidebar?.isCollapsed = false
        connectionSplit.view.layoutSubtreeIfNeeded()
        let originalFrame = connectionsWindow.frame
        var widths:[Double] = []
        let timer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in
            guard let view = self?.connectionSplit.splitView.arrangedSubviews.last else { return }
            widths.append(Double(view.layer?.presentation()?.frame.minX ?? view.frame.minX))
        }
        toggleConnectionSidebar()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [self] in
            let collapsed = connectionSidebar?.isCollapsed == true
            toggleConnectionSidebar()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { self.toggleConnectionSidebar() }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [self] in
                timer.invalidate()
                let distinct = Set(widths.map { Int($0.rounded()) }).count
                let checks:[String:Bool] = ["collapsed":collapsed,"reversed_to_collapsed":connectionSidebar?.isCollapsed == true,"window_stayed_fixed":connectionsWindow.frame == originalFrame,"intermediate_frames":NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || distinct > 3]
                let data = try! JSONSerialization.data(withJSONObject:["checks":checks,"sampleCount":widths.count,"distinctContentPositions":distinct,"passed":checks.values.allSatisfy{$0}],options:.prettyPrinted)
                try? data.write(to:URL(fileURLWithPath:report)); NSApp.terminate(nil)
            }
        }
    }
    private func buildViewingWindow() {
        guard let window, let content = window.contentView else { return }
        window.title = productName; window.toolbarStyle = .unifiedCompact; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        let toolbar = NSToolbar(identifier:"Portlight.SessionToolbar.v4"); toolbar.delegate = self; toolbar.displayMode = NSToolbar.DisplayMode(rawValue:UInt(max(1,UserDefaults.standard.integer(forKey:"Portlight.Toolbar.DisplayMode")))) ?? .iconOnly; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar; window.toolbarStyle = toolbar.displayMode == .iconAndLabel ? .expanded : .unifiedCompact
        scroll.documentView = desktop; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .underPageBackgroundColor
        let footer = material(.headerView); footer.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(footer)
        networkFooterHeight = footer.heightAnchor.constraint(equalToConstant:0); networkFooterHeight?.isActive = true
        sessionNetworkLabel.font = .systemFont(ofSize:10); sessionNetworkLabel.textColor = .secondaryLabelColor; sessionNetworkLabel.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(sessionNetworkLabel)
        NSLayoutConstraint.activate([footer.leadingAnchor.constraint(equalTo:content.leadingAnchor),footer.trailingAnchor.constraint(equalTo:content.trailingAnchor),footer.bottomAnchor.constraint(equalTo:content.bottomAnchor),sessionNetworkLabel.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:12),sessionNetworkLabel.centerYAnchor.constraint(equalTo:footer.centerYAnchor)])
        scroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:content.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:content.trailingAnchor),scroll.topAnchor.constraint(equalTo:content.topAnchor),scroll.bottomAnchor.constraint(equalTo:footer.topAnchor)])
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
        let view = NSVisualEffectView(); view.material = kind; view.blendingMode = kind == .sidebar ? .behindWindow : .withinWindow; view.state = .followsWindowActiveState; return view
    }
    private func card(_ body:NSView) -> NSView {
        let card = ConnectionCard(); pin(body,to:card,inset:20); return card
    }
    private func toolbarButton(_ title:String,symbol:String,action:Selector) -> NSButton {
        let b = NSButton(title:title,image:NSImage(systemSymbolName:symbol,accessibilityDescription:title) ?? NSImage(),target:self,action:action)
        b.bezelStyle = .texturedRounded; b.contentTintColor = .secondaryLabelColor; b.imagePosition = .imageLeading; b.font = .systemFont(ofSize:12); b.toolTip = title; b.setAccessibilityLabel(title); return b
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) + (toolbar.identifier == "Portlight.ConnectionsToolbar" ? [] : [.init("message")]) }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar.identifier == "Portlight.ConnectionsToolbar" { return [.toggleSidebar,.init("connectionDivider"),.init("connectionTitle"),.flexibleSpace] }
        return [.init("identity"),.flexibleSpace] + ["control","pause","audio","pan","resolution","color"].map { .init($0) } + [.flexibleSpace] + ["displays","zoom","dataRate","disconnect"].map { .init($0) }
    }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool) -> NSToolbarItem? {
        if id.rawValue == "connectionDivider" { return NSTrackingSeparatorToolbarItem(identifier:id,splitView:connectionSplit.splitView,dividerIndex:0) }
        if id.rawValue == "connectionTitle" {
            let item = NSToolbarItem(itemIdentifier:id); let title = NSTextField(labelWithString:"Connections"); title.font = .systemFont(ofSize:15,weight:.semibold); item.view = title; item.label = "Connections"; return item
        }
        if id == .toggleSidebar {
            let item = NSToolbarItem(itemIdentifier:id); item.label = "Sidebar"; item.toolTip = "Show or hide saved connections"; item.image = NSImage(systemSymbolName:"sidebar.left",accessibilityDescription:"Show or hide sidebar"); item.target = self; item.action = #selector(toggleConnectionSidebar); return item
        }
        let item = NSToolbarItem(itemIdentifier:id); item.autovalidates = false; item.isEnabled = true
        func icon(_ title:String,_ symbol:String,_ action:Selector) -> NSButton {
            let b = toolbarButton("",symbol:symbol,action:action); b.setAccessibilityLabel(title); b.toolTip = title; item.label = title; item.view = b; return b
        }
        switch id.rawValue {
        case "message": _ = icon("Send message", "message", #selector(messageAction))
        case "identity":
            let identity = vertical(spacing:1)
            sessionNameLabel.lineBreakMode = .byTruncatingTail
            sessionStatusLabel.font = .systemFont(ofSize:10); sessionStatusLabel.textColor = .secondaryLabelColor
            metricsLabel.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular)
            identity.addArrangedSubview(sessionNameLabel); let detail = row([sessionStatusLabel,metricsLabel],spacing:6); identity.addArrangedSubview(detail)
            sessionNameLabel.heightAnchor.constraint(equalToConstant:15).isActive = true; detail.heightAnchor.constraint(equalToConstant:12).isActive = true
            identity.heightAnchor.constraint(equalToConstant:28).isActive = true
            identity.widthAnchor.constraint(equalToConstant:210).isActive = true
            sessionNameLabel.widthAnchor.constraint(lessThanOrEqualTo:identity.widthAnchor).isActive = true
            ViewerPopupSession.addLauncher(to: identity, button: toolbarButton("", symbol: "message", action: #selector(messageAction)))
            item.view = identity; item.label = "Connection"; item.visibilityPriority = .high
        case "displays":
            map.widthAnchor.constraint(equalToConstant:150).isActive = true; map.heightAnchor.constraint(equalToConstant:28).isActive = true
            map.onToggle = { [weak self] id in self?.toggleDisplay(id) }; map.onExpand = { [weak self] in self?.expandedDisplays() }; item.view = map; item.label = "Displays"
        case "resolution":
            resolutionButtons.segmentCount = 4; resolutionButtons.trackingMode = .selectOne; resolutionButtons.target = self; resolutionButtons.action = #selector(resolutionButtonAction)
            for i in 0..<4 { let image = resolutionGridIcon(i+2); image.isTemplate = true; resolutionButtons.setImage(image,forSegment:i); resolutionButtons.setWidth(29,forSegment:i); resolutionButtons.setToolTip(Resolution.allCases[i+1].label,forSegment:i) }
            resolutionButtons.setAccessibilityLabel("Streaming resolution: HD, FHD, QHD, UHD"); item.view = resolutionButtons; item.label = "Resolution"
        case "color":
            colorButtons.segmentCount = 3; colorButtons.trackingMode = .selectOne; colorButtons.target = self; colorButtons.action = #selector(colorButtonAction)
            for i in 0..<3 { colorButtons.setImage(colorModeIcon(i),forSegment:i); colorButtons.setWidth(30,forSegment:i); colorButtons.setToolTip(colorPopup.itemTitles[i],forSegment:i) }
            colorButtons.setAccessibilityLabel("Full color, 256 colors, or 16 shades of gray"); item.view = colorButtons; item.label = "Colors"
        case "zoom":
            let fit = toolbarButton("Fit",symbol:"arrow.up.left.and.arrow.down.right",action:#selector(fitAction)); toolbarZoom = fit
            let actual = button("100%",#selector(actualSizeAction)); actual.toolTip = "100% of the host’s logical desktop size"
            item.view = row([toolbarButton("",symbol:"plus.magnifyingglass",action:#selector(zoomInAction)),toolbarButton("",symbol:"minus.magnifyingglass",action:#selector(zoomOutAction)),actual,fit],spacing:2); item.label = "Zoom"
        case "pause": toolbarPause = icon("Pause","pause",#selector(pauseAction))
        case "control":
            let control = icon("Control On","cursorarrow",#selector(controlToggleAction)); control.setButtonType(.pushOnPushOff); control.bezelStyle = .rounded; control.isBordered = true
            control.widthAnchor.constraint(equalToConstant:112).isActive = true; toolbarControl = control; item.label = "Control"
        case "pan": toolbarPan = icon("Follow pointer at edges","hand.draw",#selector(panToggleAction)); item.label = "Panning"
        case "audio": toolbarAudio = icon("System audio","speaker.slash",#selector(audioAction(_:))); item.label = "Audio"
        case "dataRate":
            let b = toolbarButton("Mbps",symbol:"chevron.down",action:#selector(settingsPopoverAction(_:))); b.imagePosition = .imageBelow; b.toolTip = "Video and audio data rates"; toolbarSettings = b; item.view = b; item.label = "Data Rate"
        case "separator1", "separator2", "separator3", "separator4":
            let line = NSBox(); line.boxType = .separator; line.widthAnchor.constraint(equalToConstant:1).isActive = true; line.heightAnchor.constraint(equalToConstant:22).isActive = true; item.view = line; item.label = ""
        case "metrics": metricsLabel.widthAnchor.constraint(equalToConstant:110).isActive = true; item.view = metricsLabel; item.label = "Frame rate"
        case "settings": toolbarSettings = icon("Connection settings","slider.horizontal.3",#selector(settingsPopoverAction(_:)))
        case "fullscreen": _ = icon("Full screen","arrow.up.left.and.arrow.down.right",#selector(fullscreenAction))
        case "disconnect": _ = icon("Disconnect","xmark.circle",#selector(disconnectAction)); item.visibilityPriority = .user
        default:return nil
        }
        let overflow = NSMenuItem(title:item.label,action:#selector(overflowAction(_:)),keyEquivalent:""); overflow.target = self; overflow.representedObject = id.rawValue
        if ["resolution","color","zoom","audioQuality"].contains(id.rawValue) {
            let menu = NSMenu(); menu.autoenablesItems = false
            let names:[String]
            switch id.rawValue { case "resolution": names = Array(Resolution.allCases.dropFirst()).map(\.label); case "color": names = colorPopup.itemTitles; case "zoom": names = ["Fit to Window","100%","Zoom In","Zoom Out"]; default:names = audioQualityPopup.itemTitles }
            for (i,name) in names.enumerated() { let choice = NSMenuItem(title:name,action:#selector(toolbarChoice(_:)),keyEquivalent:""); choice.target = self; choice.tag = i; choice.representedObject = id.rawValue; menu.addItem(choice) }
            overflow.submenu = menu
        }
        item.paletteLabel = item.label
        item.menuFormRepresentation = overflow
        return item
    }
    @objc private func messageAction() {
        releaseInput(); activePopover?.close()
        popupSession.show(appearance:window?.appearance, defaults:testing || demo ? nil : .standard)
    }
    @objc private func toolbarChoice(_ sender:NSMenuItem) {
        switch sender.representedObject as? String {
        case "resolution": guard resolutionPopup.item(at:sender.tag+1)?.isEnabled == true else { return }; resolutionPopup.selectItem(at:sender.tag+1); settingsAction()
        case "color": colorPopup.selectItem(at:sender.tag); settingsAction()
        case "audioQuality": guard supportsAAC else { return }; audioQualityPopup.selectItem(at:sender.tag); settingsAction()
        case "zoom": switch sender.tag { case 0:fitAction(); case 1:actualSizeAction(); case 2:zoomInAction(); default:zoomOutAction() }
        default:break
        }
    }
    @objc private func overflowAction(_ sender:NSMenuItem) {
        switch sender.representedObject as? String {
        case "message": messageAction()
        case "displays": expandedDisplays()
        case "pause": pauseAction()
        case "control": controlToggleAction()
        case "pan": panToggleAction()
        case "audio": if let b = toolbarAudio, audioButton.isEnabled { audioAction(b) }
        case "dataRate", "settings": if let b = toolbarSettings { settingsPopoverAction(b) }
        case "fullscreen": fullscreenAction()
        case "disconnect": disconnectAction()
        default:break
        }
    }
    private func toggleDisplay(_ id:String) {
        releaseInput(); if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        refreshMonitorButtons(); validateResolution(); rebuildCanvases(); fitWindowAspect(); scheduleSubscription()
    }
    private func expandedDisplays() {
        releaseInput()
        let frames = displayLayout(monitors,compact:false), union = displayLayout(monitors,compact:false).values.reduce(CGRect.null) { $0.union($1) }
        let targetScale = max(30/max(1,frames.values.map(\.width).min() ?? 30),22/max(1,frames.values.map(\.height).min() ?? 22))
        let size = union.isNull ? CGSize(width:280,height:140) : CGSize(width:max(280,union.width*targetScale+16),height:max(140,union.height*targetScale+16))
        let large = DisplayMap(frame:NSRect(origin:.zero,size:size)); large.expanded = true; large.monitors = monitors; large.selected = selected
        large.onToggle = { [weak self,weak large] id in self?.toggleDisplay(id); large?.selected = self?.selected ?? [] }
        let scroller = NSScrollView(); scroller.documentView = large; scroller.hasVerticalScroller = true; scroller.hasHorizontalScroller = true; scroller.autohidesScrollers = true; scroller.drawsBackground = false
        scroller.widthAnchor.constraint(equalToConstant:280).isActive = true; scroller.heightAnchor.constraint(equalToConstant:140).isActive = true
        let content = vertical(spacing:8); content.addArrangedSubview(scroller)
        let hint = NSTextField(wrappingLabelWithString:"Click a display to turn it on or off."); hint.widthAnchor.constraint(equalToConstant:280).isActive = true; hint.font = .systemFont(ofSize:12); hint.textColor = .secondaryLabelColor; content.addArrangedSubview(hint)
        showPopover(content,anchor:map,width:280)
    }
    @objc private func resolutionButtonAction() { resolutionPopup.selectItem(at:resolutionButtons.selectedSegment+1); settingsAction() }
    @objc private func pauseAction() { pauseButton.state = pauseButton.state == .on ? .off : .on; settingsAction() }
    @objc private func controlToggleAction() { viewOnlyButton.state = viewOnlyButton.state == .on ? .off : .on; settingsAction() }
    @objc private func panToggleAction() { followButton.state = followButton.state == .on ? .off : .on; settingsAction() }
    @objc private func audioQualityAction(_ sender:NSButton) {
        let content = vertical(spacing:12); content.addArrangedSubview(audioQualityPopup)
        let note = NSTextField(wrappingLabelWithString:supportsAAC ? "Lower audio rates save bandwidth. Audio is off until you enable the speaker button." : "This host supports legacy mono audio (192 kbps). Update the host for compressed audio quality choices.")
        note.widthAnchor.constraint(equalToConstant:280).isActive = true; note.textColor = .secondaryLabelColor; content.addArrangedSubview(note); audioQualityPopup.isEnabled = supportsAAC
        showPopover(content,anchor:sender,width:280)
    }
    @objc private func toolbarItemAction(_ item:NSToolbarItem) {
        switch item.itemIdentifier.rawValue {
        case "displays": expandedDisplays()
        case "zoom": if let b = toolbarZoom { zoomMenuAction(b) }
        case "audio": if let b = toolbarAudio { audioAction(b) }
        case "dataRate", "settings": if let b = toolbarSettings { settingsPopoverAction(b) }
        default: break
        }
    }
    private func updateToolbar() {
        let name = serverName.isEmpty ? productName : serverName
        let state = demo ? "Preview" : (connecting ? "Connecting" : (paused ? "Paused" : (ready ? "Connected" : "Disconnected")))
        let title = NSMutableAttributedString(string:name,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:NSColor.labelColor])
        sessionStatusLabel.stringValue = state
        sessionNameLabel.attributedStringValue = title; sessionNameLabel.toolTip = name + " · " + state; sessionNameLabel.setAccessibilityLabel(name + ", " + state)
        if map.monitors != monitors { map.monitors = monitors }; if map.selected != selected { map.selected = selected }
        colorButtons.selectedSegment = colorPopup.indexOfSelectedItem; colorButtons.needsDisplay = true
        resolutionButtons.selectedSegment = max(0,resolutionPopup.indexOfSelectedItem-1); resolutionButtons.needsDisplay = true
        for i in 0..<4 { resolutionButtons.setEnabled(resolutionPopup.item(at:i+1)?.isEnabled ?? true,forSegment:i) }
        for item in window?.toolbar?.items ?? [] {
            for choice in item.menuFormRepresentation?.submenu?.items ?? [] {
                if item.itemIdentifier.rawValue == "resolution" { choice.isEnabled = resolutionPopup.item(at:choice.tag+1)?.isEnabled ?? false; choice.state = choice.tag+1 == resolutionPopup.indexOfSelectedItem ? .on : .off }
                if item.itemIdentifier.rawValue == "audioQuality" { choice.isEnabled = supportsAAC; choice.state = choice.tag == audioQualityPopup.indexOfSelectedItem ? .on : .off }
                if item.itemIdentifier.rawValue == "color" { choice.state = choice.tag == colorPopup.indexOfSelectedItem ? .on : .off }
            }
        }
        toolbarPause?.image = NSImage(systemSymbolName:paused ? "play.fill" : "pause",accessibilityDescription:paused ? "Resume" : "Pause")
        toolbarPause?.toolTip = paused ? "Resume streaming" : "Pause streaming and control"
        let controlEnabled = viewOnlyButton.state != .on && !paused
        let controlTitle = paused ? "Control Paused" : (controlEnabled ? "Control On" : "View Only")
        toolbarControl?.title = controlTitle
        toolbarControl?.image = NSImage(systemSymbolName:paused ? "pause.fill" : (controlEnabled ? "cursorarrow" : "eye"),accessibilityDescription:controlTitle)
        toolbarControl?.state = controlEnabled ? .on : .off
        toolbarControl?.bezelColor = controlEnabled ? .controlAccentColor : nil
        toolbarControl?.contentTintColor = controlEnabled ? .white : .secondaryLabelColor
        toolbarControl?.isEnabled = !paused
        toolbarControl?.toolTip = paused ? "Resume streaming to restore control." : (controlEnabled ? "Keyboard and mouse control is enabled. Click to switch to view only." : "Viewing only: keyboard and mouse input is blocked. Click to enable control.")
        toolbarControl?.setAccessibilityLabel(controlTitle)
        toolbarControl?.setAccessibilityValue(controlEnabled ? "Enabled" : "Disabled")
        if let controlItem = window?.toolbar?.items.first(where:{$0.itemIdentifier.rawValue == "control"}) { controlItem.label = controlTitle; controlItem.menuFormRepresentation?.title = controlTitle; controlItem.menuFormRepresentation?.state = controlEnabled ? .on : .off; controlItem.menuFormRepresentation?.isEnabled = !paused }
        toolbarPan?.contentTintColor = followButton.state == .on ? .controlAccentColor : .secondaryLabelColor
        toolbarDisplays?.title = "Displays"; toolbarDisplays?.toolTip = "Choose displays · \(selected.count) selected"
        toolbarZoom?.title = "Fit"; toolbarZoom?.contentTintColor = autoFit ? .controlAccentColor : .labelColor
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
        let visibleAnchor = anchor.window == nil ? (ready ? scroll : connectionsWindow.contentView!) : anchor
        activePopover = popover; popover.show(relativeTo:visibleAnchor.bounds,of:visibleAnchor,preferredEdge:.minY)
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
        for (title,action) in [("Fit displays",#selector(fitAction)),("Actual size",#selector(actualSizeAction)),("Zoom in",#selector(zoomInAction)),("Zoom out",#selector(zoomOutAction))] {
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
        let content = vertical(spacing:14)
        let heading = NSTextField(labelWithString:"Data rates"); heading.font = .systemFont(ofSize:17,weight:.semibold); content.addArrangedSubview(heading)
        content.addArrangedSubview(preferenceRow("Video limit",row([bandwidthLimitField,label("Mbps")],spacing:6)))
        content.addArrangedSubview(preferenceRow("Picture priority",qualityPopup))
        smoothGradients.target = self; smoothGradients.action = #selector(settingsAction); content.addArrangedSubview(smoothGradients)
        let ditherNote = NSTextField(wrappingLabelWithString:"Smoother reduced-color video uses more data. Leave off for the lowest latency."); ditherNote.font = .systemFont(ofSize:11); ditherNote.textColor = .secondaryLabelColor; ditherNote.widthAnchor.constraint(equalToConstant:324).isActive = true; content.addArrangedSubview(ditherNote)
        content.addArrangedSubview(divider())
        audioQualityPopup.isEnabled = supportsAAC; content.addArrangedSubview(preferenceRow("Audio quality",audioQualityPopup))
        let note = NSTextField(wrappingLabelWithString:supportsAAC ? "Automatic video adapts to the connection. Lower audio rates use less data. Enable audio with the speaker button." : "Automatic video adapts to the connection. This host uses legacy mono audio; update it for compressed audio choices.")
        note.font = .systemFont(ofSize:12); note.textColor = .secondaryLabelColor; note.widthAnchor.constraint(equalToConstant:324).isActive = true; content.addArrangedSubview(note)
        showPopover(content,anchor:sender,width:324)
    }
    @objc private func colorButtonAction() { colorPopup.selectItem(at:colorButtons.selectedSegment); settingsAction() }

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
        serverName = name; activePopover?.close(); connectionsWindow.orderOut(nil); window?.title = name; window?.makeKeyAndOrderFront(nil); updateToolbar(); updateNetworkStatus(); layoutCanvases()
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
    private var color:String { ["full","color256","gray16"][max(0,colorPopup.indexOfSelectedItem)] }
    private var quality:String { ["auto","desktop","motion"][max(0,qualityPopup.indexOfSelectedItem)] }
    private var fps:Int { 60 }
    private var cap:Int { let v = Int(bandwidthField.stringValue) ?? 0; return v == 0 ? 0 : min(100000,max(100,v)) }
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
        if passwordField.stringValue.isEmpty, let id = presetID,
           let preset = presets.presets.first(where:{$0.id == id}), preset.host == hostField.stringValue, preset.port == port, !testing {
            guard let password = loadPassword(preset:id) else { statusLabel.stringValue = "Enter a password, or allow Keychain access when connecting."; connectionsWindow.makeFirstResponder(passwordField); return }
            passwordField.stringValue = password
        }
        connectionAttempt = UUID(); let attempt = connectionAttempt
        let request = ConnectionRequest(host:hostField.stringValue,port:port,password:passwordField.stringValue,network:zeroTierNetwork,managed:Array(Set(zeroTierManaged+presets.presets.compactMap(\.zeroTierNetwork))),disconnectNetwork:disconnectZeroTier)
        demo = false; connectionEstablished = false; connecting = true; connectButton.title = "Cancel"; connectButton.isEnabled = true; hostField.isEnabled = false; passwordField.isEnabled = false; advancedButton.isEnabled = false
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
            activationInFlight = true; activeDisconnectZeroTier = request.disconnectNetwork; statusLabel.stringValue = "Connecting ZeroTier before the desktop…"; updateNetworkStatus("Waiting for network authorization and an address…")
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
                self.zeroTierTransaction = result["transactionId"] as? String; self.updateNetworkStatus("Network ready · connecting to desktop…")
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
        popupSession.disconnect()
        let finishAction = connectionEstablished ? "finish" : "restore"; connectionEstablished = false
        ready = false; connecting = false; acceptedRevision = -1; connectButton.title = "Connect"; connectButton.isEnabled = !activationInFlight && !restorationInFlight; advancedButton.isEnabled = connectButton.isEnabled; hostField.isEnabled = true; passwordField.isEnabled = true; presentConnections(); audio.stop(); pointerButtons = 0; pressedKeys.removeAll(); modifiers = []
        if let transaction = zeroTierTransaction {
            zeroTierTransaction = nil; restorationInFlight = true; connectButton.isEnabled = false; advancedButton.isEnabled = false
            runZeroTier(["action":finishAction,"transactionId":transaction,"disconnect":activeDisconnectZeroTier]) { [weak self] result in
                guard let self else { return }
                if result["ok"] as? Bool != true { self.statusLabel.stringValue = "Disconnected; ZeroTier needs attention. Open ZeroTier to recover the session." }
                self.updateNetworkStatus(self.activeDisconnectZeroTier ? "Disconnected · will reconnect next time" : "Left connected for faster reconnection")
                self.finishNetworkChange(succeeded:result["ok"] as? Bool == true)
            }
        }
    }
    private func receive(_ object:[String:Any],data:Data?) {
        guard let type = object["type"] as? String else { return }
        if popupSession.receive(object) { return }
        switch type {
        case "welcome","displays":
            guard let rows = object["displays"] as? [[String:Any]], rows.count <= 32 else { statusLabel.stringValue = "The computer sent an invalid display list."; return }
            var parsed: [RemoteMonitor] = []
            for (index,row) in rows.enumerated() {
                guard let id = row["id"] as? String, let width = row["width"] as? Int, let height = row["height"] as? Int, width > 0, height > 0, width <= 32768, height <= 32768, !parsed.contains(where:{$0.id == id}) else { continue }
                let scale = max(0.25,min(8,row["scale"] as? Double ?? 1))
                let lx = row["x"] as? Double ?? Double(parsed.reduce(0) { $0+$1.width }), ly = row["y"] as? Double ?? 0
                let lw = row["logicalWidth"] as? Double ?? Double(width)/scale, lh = row["logicalHeight"] as? Double ?? Double(height)/scale
                guard [lx,ly,lw,lh].allSatisfy({$0.isFinite && abs($0) <= 131072}), lw > 0, lh > 0 else { continue }
                parsed.append(RemoteMonitor(id:id,name:row["name"] as? String ?? "Display \(index+1)",width:width,height:height,logicalX:lx,logicalY:ly,logicalWidth:lw,logicalHeight:lh,number:index+1))
            }
            releaseInput(); let firstWelcome = !ready; monitors = parsed; ready = true; connectionEstablished = true; connecting = false; hostField.isEnabled = true; passwordField.isEnabled = true; advancedButton.isEnabled = true; connectButton.title = "Connect"
            let available = Set(parsed.map(\.id))
            if firstWelcome { selected = available; pendingMonitorIDs = nil }
            else { selected = selected.intersection(available) }
            if let capabilities = object["capabilities"] as? [String:Any], let audioCodecs = capabilities["audio"] as? [String] { supportsAAC = audioCodecs.contains("aac"); audioButton.isEnabled = audioCodecs.contains("mulaw") || supportsAAC; if !audioButton.isEnabled { audioButton.state = .off } }
            presentSession(name:object["serverName"] as? String ?? hostField.stringValue); updateNetworkStatus("Connected")
            refreshMonitorButtons(); validateResolution(); rebuildCanvases(); scheduleSubscription(immediate:true)
            statusLabel.stringValue = "Connected to \(object["serverName"] as? String ?? hostField.stringValue). Choose the displays to view."
            if type == "welcome" { popupSession.welcome(object) }
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
            guard let data, !paused, audioButton.state == .on, let audioRevision = object["revision"] as? Int, audioRevision >= 0, audioRevision <= revision else { return }
            if object["codec"] as? String == "aac", object["sampleRate"] as? Int == 48000, object["samples"] as? Int == 1024, let channels = object["channels"] as? Int, let encodedCookie = object["cookie"] as? String, encodedCookie.count <= 5500, let cookie = Data(base64Encoded:encodedCookie) {
                audio.playAAC(data,channels:channels,cookie:cookie); bytesReceived += data.count
            } else if object["codec"] as? String == "mulaw", let rate = object["sampleRate"] as? Int, let channels = object["channels"] as? Int, object["samples"] as? Int == data.count {
                audio.play(data,sampleRate:rate,channels:channels); bytesReceived += data.count
            }
        case "cursor":
            guard let id = object["display"] as? String, selected.contains(id), let x = object["x"] as? Double, let y = object["y"] as? Double, x.isFinite, y.isFinite, (0..<1).contains(x), (0..<1).contains(y) else { return }
            for (monitorID,c) in canvases { c.remoteCursor = monitorID == id ? NSPoint(x:x,y:y) : nil }
        case "pong": if let timestamp = object["time"] as? Double { latency = (Date().timeIntervalSince1970-timestamp)*1000 }
        case "error":
            let message = object["message"] as? String ?? "The computer reported an error."
            if object["code"] as? String == "authentication" { disconnect(); statusLabel.stringValue = message }
            else { statusLabel.stringValue = message; if ready { showSessionError(message) } }
        case "stats": if let measured = object["fps"] as? Double, measured.isFinite { currentFPS = measured/max(1,Double(selected.count)) }
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
        for c in canvases.values { c.viewOnly = viewOnlyButton.state == .on || paused; c.paused = paused }
        fitWindowAspect(); layoutCanvases()
    }
    private func layoutCanvases() {
        guard !inLayout else { return }; inLayout = true; defer { inLayout = false }
        let frames = displayLayout(selectedMonitors,compact:true)
        let union = frames.values.reduce(CGRect.null) { $0.union($1) }
        let width = union.isNull ? 1 : max(1,union.width), height = union.isNull ? 1 : max(1,union.height)
        if autoFit { zoom = max(0.005,min(Double(scroll.contentSize.width)/width,Double(scroll.contentSize.height)/height)) }
        let renderedWidth = width*zoom, renderedHeight = height*zoom
        let offsetX = max(0,(scroll.contentSize.width-renderedWidth)/2), offsetY = max(0,(scroll.contentSize.height-renderedHeight)/2)
        for (id,frame) in frames { canvases[id]?.frame = CGRect(x:offsetX+frame.minX*zoom,y:offsetY+frame.minY*zoom,width:frame.width*zoom,height:frame.height*zoom) }
        desktop.frame = CGRect(x:0,y:0,width:max(scroll.contentSize.width,renderedWidth),height:max(scroll.contentSize.height,renderedHeight))
        if autoFit { scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView) }
        updateToolbar()
        zoomLabel.stringValue = autoFit ? "Fit \(Int(zoom*100))%" : "\(Int(zoom*100))%"
    }
    @objc private func settingsAction() {
        releaseInput(); bandwidthField.stringValue = String(cap); syncSettings(); validateResolution(); rebuildCanvases()
        if audioButton.state != .on || paused { audio.stop() }
        if demo { for (index,m) in selectedMonitors.enumerated() { canvases[m.id]?.demoImage(index+1) } }
        updateToolbar(); scheduleSubscription()
    }
    @objc private func fitAction() { autoFit = true; fitWindowAspect(); layoutCanvases(); scheduleSubscription() }
    @objc private func fitMonitorAction() {
        guard let canvas = (window?.firstResponder as? MonitorCanvas) ?? selectedMonitors.first.flatMap({canvases[$0.id]}) else { return }
        autoFit = false; zoom = min(Double(scroll.contentSize.width)/canvas.pixelSize.width,Double(scroll.contentSize.height)/canvas.pixelSize.height); layoutCanvases(); scroll.contentView.scroll(to:canvas.frame.origin); scheduleSubscription()
    }
    @objc private func zoomInAction() { setZoom(zoom*1.1) }
    @objc private func zoomOutAction() { setZoom(zoom/1.1) }
    @objc private func actualSizeAction() { setZoom(1) }
    private func setZoom(_ value:Double) { guard value.isFinite else { return }; autoFit = false; zoom = clamp(value,0.05,4); layoutCanvases(); scheduleSubscription() }
    @objc private func fullscreenAction() { window?.toggleFullScreen(nil) }
    @objc private func viewportChanged() { if !inLayout { if autoFit { layoutCanvases() }; scheduleSubscription() } }
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
        transport.send(["type":"subscribe","revision":revision,"displays":selectedMonitors.map(\.id),"maxWidth":Int(box.width),"maxHeight":Int(box.height),"color":color,"quality":quality,"dither":smoothGradients.state == .on,"fps":fps,"bandwidthKbps":cap,"paused":paused,"audio":audioButton.state == .on && !paused,"audioCodec":supportsAAC ? "aac" : "mulaw","audioBitrate":[48000,96000,160000,320000][max(0,audioQualityPopup.indexOfSelectedItem)],"viewOnly":viewOnlyButton.state == .on,"regions":regions])
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
        if ready && !demo { let rate = Double(bytesReceived-lastBytes)*8/1000; metricsLabel.stringValue = String(format:"%.0f fps · %.1f Mb/s",currentFPS,rate/1000); metricsLabel.toolTip = "Average host updates per selected display; unchanged screens need no new frames. Latency: \(Int(latency)) ms."; lastBytes = bytesReceived; frameCount = 0; transport.send(["type":"ping","time":Date().timeIntervalSince1970]) }
    }
    private func fitWindowAspect() {
        guard autoFit, let window, !window.styleMask.contains(.fullScreen), !fullscreenTransition, ready else { return }
        let union = displayLayout(selectedMonitors,compact:true).values.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else { return }
        let ratio = union.width/union.height
        window.minSize = NSSize(width:min(900,max(300,150*ratio)),height:150)
        let chrome = window.frame.height-scroll.contentSize.height
        var size = NSSize(width:window.frame.width,height:window.frame.width/ratio+chrome)
        if let visible = window.screen?.visibleFrame, size.height > visible.height { size.height = visible.height; size.width = (size.height-chrome)*ratio }
        var frame = window.frame; frame.origin.y += frame.height-size.height; frame.size = size; window.setFrame(frame,display:true)
    }
    func windowWillResize(_ sender:NSWindow,to frameSize:NSSize) -> NSSize {
        guard sender === window, autoFit, !fullscreenTransition, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let union = displayLayout(selectedMonitors,compact:true).values.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else { return frameSize }
        let chrome = sender.frame.height-scroll.contentSize.height
        return NSSize(width:frameSize.width,height:frameSize.width*union.height/union.width+chrome)
    }
    func windowWillEnterFullScreen(_ notification:Notification) { fullscreenTransition = true }
    func windowDidEnterFullScreen(_ notification:Notification) { fullscreenTransition = false; layoutCanvases(); scheduleSubscription() }
    func windowWillExitFullScreen(_ notification:Notification) { fullscreenTransition = true }
    func windowDidExitFullScreen(_ notification:Notification) { fullscreenTransition = false; fitWindowAspect(); layoutCanvases(); scheduleSubscription() }
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
            runZeroTier(["action":connectionEstablished ? "finish" : "restore","transactionId":transaction,"disconnect":activeDisconnectZeroTier]) { [weak self] result in
                if result["ok"] as? Bool != true { self?.statusLabel.stringValue = "ZeroTier restore needs attention; recovery transaction is saved." }
                self?.finishNetworkChange(succeeded:result["ok"] as? Bool == true)
            }
        } else { RunLoop.main.perform(inModes:[.default,.modalPanel,.eventTracking],block:completion) }
    }
    private func reloadPresets() {
        let selectedID = savedRows.indices.contains(savedTable.selectedRow) ? savedRows[savedTable.selectedRow].id : presetID
        updatingSavedTable = true
        let list = presets.presets.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        let groups = presets.groups.sorted { $0.order < $1.order }
        savedRows = list.filter { preset in preset.groupID == nil || !groups.contains(where: { g in g.id == preset.groupID }) }.map { ($0.id,$0.name,$0.host) }
        for group in groups {
            savedRows.append((group.id,group.name,""))
            if !collapsedGroups.contains(group.id) { savedRows += list.filter { $0.groupID == group.id }.map { ($0.id,$0.name,$0.host) } }
        }
        if screenshotFixture { savedRows = [("preview-editing","Editing Mac","editing-mac.local"),("preview-studio","Studio Mac","studio-mac.local")] }
        savedTable.reloadData(); if let id = selectedID, let index = savedRows.firstIndex(where:{$0.id == id}) { savedTable.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }; emptySavedLabel.isHidden = !savedRows.isEmpty
        if screenshotFixture { savedTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
        updatingSavedTable = false
        presetPopup.removeAllItems(); presetPopup.addItem(withTitle:"Saved connections")
        for p in presets.presets { presetPopup.addItem(withTitle:p.name); presetPopup.lastItem?.representedObject = p.id }
    }
    @objc private func savedConnectionAction(_ sender:NSButton) { if let id = sender.identifier?.rawValue { _ = recallPreset(id,connect:false) } }
    @objc private func savePresetAction() {
        activePopover?.close()
        guard let port = validPort(portField.stringValue), !hostField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { statusLabel.stringValue = "Enter a computer address and valid port before saving."; return }
        let enteredName = presetNameField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let name = enteredName.isEmpty ? "Saved Connection" : String(enteredName.prefix(100))
        let id = presetID ?? UUID().uuidString
        let p = ViewPreset(id:id,name:name,host:hostField.stringValue,port:port,monitors:selectedMonitors.map(\.id),resolution:resolution.rawValue,color:color,quality:quality,bandwidthKbps:cap,fps:fps,zoom:autoFit ? 0 : zoom,follow:followButton.state == .on,viewOnly:viewOnlyButton.state == .on,fullScreen:window?.styleMask.contains(.fullScreen) ?? false,zeroTierNetwork:zeroTierNetwork,zeroTierManaged:zeroTierManaged,groupID:currentGroup,order:presets.presets.first(where:{$0.id == id})?.order ?? presets.presets.count,disconnectZeroTier:disconnectZeroTier,audioBitrate:[48000,96000,160000,320000][max(0,audioQualityPopup.indexOfSelectedItem)])
        presets.save(p); presetID = id; saveConnectionButton.title = "Update Connection"; presetNameField.stringValue = name
        if rememberPassword.state == .on && !passwordField.stringValue.isEmpty { savePassword(passwordField.stringValue,preset:id) }
        reloadPresets(); presetPopup.selectItem(withTitle:p.name); statusLabel.stringValue = "Saved \(p.name)."
    }
    @objc private func recallPresetAction() { if let id = presetPopup.selectedItem?.representedObject as? String { recallPreset(id,connect:false) } }
    @discardableResult private func recallPreset(_ id:String,connect:Bool) -> Bool {
        guard let p = presets.presets.first(where:{$0.id == id || $0.name == id}) else { return false }
        disconnect(); presetID = p.id; presetNameField.stringValue = p.name; currentGroup = p.groupID; hostField.stringValue = p.host; portField.stringValue = String(p.port); passwordField.stringValue = ""; passwordField.placeholderString = "Saved password is retrieved when connecting"; saveConnectionButton.title = "Update Connection"; rememberPassword.state = .off
        pendingMonitorIDs = Set(p.monitors)
        resolutionPopup.selectItem(at:Resolution.allCases.firstIndex(where:{$0.rawValue == p.resolution}) ?? 2)
        colorPopup.selectItem(at:["full","color256","gray16"].firstIndex(of:p.color) ?? 0)
        qualityPopup.selectItem(at:["auto","desktop","motion"].firstIndex(of:p.quality) ?? 0)
        fpsPopup.selectItem(at:[5,10,15,30,60].firstIndex(of:p.fps) ?? 2); bandwidthField.stringValue = String(p.bandwidthKbps)
        autoFit = p.zoom == 0; zoom = p.zoom > 0 ? clamp(p.zoom,0.05,4) : 1; followButton.state = p.follow ? .on : .off; viewOnlyButton.state = p.viewOnly ? .on : .off
        audioButton.state = .off; pauseButton.state = .off; zeroTierNetwork = p.zeroTierNetwork; zeroTierManaged = p.zeroTierManaged ?? []; disconnectZeroTier = p.disconnectZeroTier ?? false; audioQualityPopup.selectItem(at:[48000,96000,160000,320000].firstIndex(of:p.audioBitrate ?? 96000) ?? 1); updateNetworkStatus()
        pendingFullScreen = p.fullScreen
        statusLabel.stringValue = "Loaded \(p.name)."; if connect { connectAction() }; return true
    }
    private func savePassword(_ password:String,preset:String) {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"studio.upgrade.remote.viewer",kSecAttrAccount as String:preset]
        SecItemDelete(query as CFDictionary); var item = query; item[kSecValueData as String] = Data(password.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary,nil) != errSecSuccess { statusLabel.stringValue = "Connection saved; its password could not be stored in Keychain." }
    }
    private func loadPassword(preset:String) -> String? {
        passwordReadCount += 1
        if testing { return nil }
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
            guard let value = firstString(), let i = ["full","color256","gray16"].firstIndex(of:value) else { error("Unsupported color mode"); return }; colorPopup.selectItem(at:i); settingsAction()
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
        let alert = NSAlert(); alert.messageText = "Pair one ZeroTier network"
        let available = result["ok"] as? Bool == true
        alert.informativeText = available ? "Portlight connects this network before opening the desktop. It uses one paired network at a time; networks you have not paired with Portlight are left alone." : (result["message"] as? String ?? result["error"] as? String ?? "ZeroTier is unavailable.")
        let choices = NSPopUpButton(frame:NSRect(x:0,y:116,width:450,height:26)); choices.addItem(withTitle:"None")
        var known = UserDefaults.standard.dictionary(forKey:"Portlight.ZeroTier.Networks") as? [String:String] ?? [:]
        for preset in presets.presets { if let id = preset.zeroTierNetwork, known[id] == nil { known[id] = id } }
        for n in networks { if let id = n["id"] as? String { known[id] = n["name"] as? String ?? id } }
        if let id = zeroTierNetwork, known[id] == nil { known[id] = id }
        for id in known.keys.sorted() {
            let state = networks.first(where:{$0["id"] as? String == id})?["status"] as? String ?? "Not connected"
            choices.addItem(withTitle:"\(known[id] ?? id) · \(id) · \(state)"); choices.lastItem?.representedObject = id
            if id == zeroTierNetwork { choices.selectItem(at:choices.numberOfItems-1) }
        }
        let disconnect = NSButton(checkboxWithTitle:"Disconnect this network when the desktop disconnects",target:nil,action:nil); disconnect.state = disconnectZeroTier ? .on : .off; disconnect.frame = NSRect(x:0,y:80,width:450,height:24)
        let note = NSTextField(wrappingLabelWithString:"Leaving it connected makes reconnecting faster. Disconnecting it closes the network connection, but the next connection takes longer while ZeroTier becomes ready.")
        note.font = .systemFont(ofSize:12); note.textColor = .secondaryLabelColor; note.frame = NSRect(x:0,y:0,width:450,height:66)
        let body = NSView(frame:NSRect(x:0,y:0,width:450,height:146)); body.addSubview(choices); body.addSubview(disconnect); body.addSubview(note); alert.accessoryView = body
        alert.addButton(withTitle:"Use Network"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Add Network…")
        let pending = result["pendingTransactions"] as? [[String:Any]] ?? []; if !pending.isEmpty { alert.addButton(withTitle:"Recover Previous Session…") }
        let response = alert.runModal()
        if response.rawValue == 1003 { showZeroTierRecovery(pending); return }
        if response == .alertThirdButtonReturn {
            let add = NSAlert(); add.messageText = "Add ZeroTier network"; add.informativeText = "Enter its 16-character network ID. Joining happens when you connect to the desktop."
            let field = NSTextField(string:""); field.frame = NSRect(x:0,y:0,width:360,height:26); add.accessoryView = field; add.addButton(withTitle:"Add"); add.addButton(withTitle:"Cancel"); add.window.initialFirstResponder = field
            if add.runModal() == .alertFirstButtonReturn {
                let id = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                if id.range(of:"^[0-9a-f]{16}$",options:.regularExpression) != nil { known[id] = id; UserDefaults.standard.set(known,forKey:"Portlight.ZeroTier.Networks"); zeroTierNetwork = id }
                else { statusLabel.stringValue = "A ZeroTier network ID needs exactly 16 hexadecimal characters." }
            }
            showZeroTier(result); return
        }
        guard response == .alertFirstButtonReturn else { return }
        zeroTierNetwork = choices.selectedItem?.representedObject as? String
        disconnectZeroTier = disconnect.state == .on
        // Exclusivity covers only networks paired with Portlight, never arbitrary memberships.
        zeroTierManaged = Array(Set(presets.presets.compactMap(\.zeroTierNetwork) + [zeroTierNetwork].compactMap{$0}))
        updateNetworkStatus(); statusLabel.stringValue = "Network pairing updated. Save Connection to keep it."
    }
    @objc private func newItemMenu(_ sender:NSButton) {
        let menu = NSMenu()
        for (name,action) in [("New Connection",#selector(newConnectionAction)),("New Group…",#selector(newGroup))] { let item = NSMenuItem(title:name,action:action,keyEquivalent:""); item.target = self; menu.addItem(item) }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.maxY),in:sender)
    }
    @objc private func newGroup() {
        let alert = NSAlert(); alert.messageText = "New group"; let field = NSTextField(string:"New Group"); field.frame = NSRect(x:0,y:0,width:300,height:24); alert.accessoryView = field; alert.addButton(withTitle:"Create Group"); alert.addButton(withTitle:"Cancel"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); guard !name.isEmpty else { return }
        let group = PresetGroup(id:UUID().uuidString,name:String(name.prefix(100)),order:presets.groups.count); presets.groups.append(group); currentGroup = group.id; reloadPresets()
    }
    @objc private func removeSavedItem() {
        guard savedRows.indices.contains(savedTable.selectedRow) else { return }; let id = savedRows[savedTable.selectedRow].id
        if presets.groups.contains(where:{$0.id == id}) {
            presets.groups.removeAll { $0.id == id }; var list = presets.presets
            for i in list.indices where list[i].groupID == id { list[i].groupID = nil }; presets.presets = list
            if currentGroup == id { currentGroup = nil }
        } else {
            presets.presets.removeAll { $0.id == id }
            if presetID == id { presetID = nil }
            SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"studio.upgrade.remote.viewer",kSecAttrAccount as String:id] as CFDictionary)
        }
        reloadPresets()
    }
    func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int) -> NSPasteboardWriting? {
        guard savedRows.indices.contains(row) else { return nil }; let item = NSPasteboardItem(); item.setString(savedRows[row].id,forType:.init("studio.upgrade.portlight.preset")); return item
    }
    func tableView(_ tableView:NSTableView,validateDrop info:NSDraggingInfo,proposedRow row:Int,proposedDropOperation operation:NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType:.init("studio.upgrade.portlight.preset")) != nil else { return [] }
        if operation == .on && (!savedRows.indices.contains(row) || !presets.groups.contains(where:{$0.id == savedRows[row].id})) { tableView.setDropRow(row,dropOperation:.above) }
        return .move
    }
    func tableView(_ tableView:NSTableView,acceptDrop info:NSDraggingInfo,row:Int,dropOperation operation:NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType:.init("studio.upgrade.portlight.preset")) else { return false }
        let target = savedRows.indices.contains(row) ? savedRows[row].id : nil
        return moveSavedItem(id,target:target,operation:operation)
    }
    private func moveSavedItem(_ id:String,target:String?,operation:NSTableView.DropOperation) -> Bool {
        guard id != target else { return false }
        var groups = presets.groups.sorted { $0.order < $1.order }
        if let index = groups.firstIndex(where:{$0.id == id}) {
            let group = groups.remove(at:index); let destination = groups.firstIndex(where:{$0.id == target}) ?? groups.count; groups.insert(group,at:destination)
            for i in groups.indices { groups[i].order = i }; presets.groups = groups
        } else {
            var list = presets.presets.sorted { ($0.order ?? 0) < ($1.order ?? 0) }; guard let index = list.firstIndex(where:{$0.id == id}) else { return false }; var preset = list.remove(at:index)
            if let target, groups.contains(where:{$0.id == target}) { preset.groupID = operation == .on ? target : nil }
            else { preset.groupID = list.first(where:{$0.id == target})?.groupID }
            let destination = list.firstIndex(where:{$0.id == target}) ?? list.count; list.insert(preset,at:destination)
            for i in list.indices { list[i].order = i }; presets.presets = list
            if presetID == id { currentGroup = preset.groupID }
        }
        reloadPresets(); return true
    }
    private func updateNetworkStatus(_ message:String? = nil) {
        guard let id = zeroTierNetwork else { networkStatusLabel.stringValue = "No ZeroTier network paired"; sessionNetworkLabel.stringValue = ""; networkFooterHeight?.constant = 0; return }
        networkStatusLabel.stringValue = "ZeroTier · \(id)\n" + (message ?? (ready ? "Connected" : "Paired · connects before the desktop")); sessionNetworkLabel.stringValue = serverName + " · " + networkStatusLabel.stringValue.replacingOccurrences(of:"\n",with:" · "); networkFooterHeight?.constant = 22
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
        let testDomain = "Portlight.UICheck."+UUID().uuidString
        let testDefaults = UserDefaults(suiteName:testDomain)!
        presets = PresetStore(defaults:testDefaults)
        defer { testDefaults.removePersistentDomain(forName:testDomain) }
        var checks:[String:Bool] = [:]
        checks["sidebar_can_collapse"] = connectionSidebar?.canCollapse == true
        connectionSidebar?.isCollapsed = true; checks["sidebar_hides"] = connectionSidebar?.isCollapsed == true
        checks["collapsed_minimum_width"] = connectionsWindow.minSize.width == 420
        connectionSidebar?.isCollapsed = false; checks["sidebar_restores"] = connectionSidebar?.isCollapsed == false
        checks["expanded_minimum_width"] = connectionsWindow.minSize.width == 611
        checks["sidebar_toggle_visible"] = connectionsWindow.toolbar?.items.contains(where:{$0.itemIdentifier == .toggleSidebar}) == true
        checks["disconnect_is_last"] = toolbarDefaultItemIdentifiers(window!.toolbar!).last == .init("disconnect")
        checks["three_toolbar_sections"] = toolbarDefaultItemIdentifiers(window!.toolbar!).filter {$0 == .flexibleSpace}.count == 2
        checks["identity_is_first"] = toolbarDefaultItemIdentifiers(window!.toolbar!).first == .init("identity")
        checks["name_tab_reaches_computer"] = presetNameField.nextKeyView === hostField
        checks["computer_shift_tab_reaches_name"] = hostField.previousKeyView === presetNameField
        checks["password_tab_reaches_port"] = passwordField.nextKeyView === portField
        checks["three_color_modes_only"] = colorPopup.itemTitles == ["Full color","256 colors","16 shades of gray"]
        checks["native_toolbar_customization"] = window?.toolbar?.allowsUserCustomization == true
        checks["no_settings_or_fullscreen_toolbar"] = !(window?.toolbar?.items.contains(where:{ ["settings","fullscreen","audioQuality"].contains($0.itemIdentifier.rawValue) }) ?? true)

        configureScreenshot(stage:"session",appearance:"light",minimum:true,popover:nil)
        checks["map_simple_layout_direct_selection"] = !map.needsExpansion
        let oldSelection = selected; toggleDisplay("demo-2"); checks["map_toggles_subscription_selection"] = selected.contains("demo-2"); selected = oldSelection; rebuildCanvases()
        pauseAction(); checks["pause_blocks_input_and_dims_canvas"] = paused && canvases.values.allSatisfy { $0.viewOnly && $0.paused }; pauseAction()
        let fitted = zoom; zoomInAction(); checks["zoom_uses_small_steps"] = abs(zoom-fitted*1.1) < 0.001; fitAction()
        if let w = window {
            let resized = windowWillResize(w,to:NSSize(width:1000,height:800))
            let union = displayLayout(selectedMonitors,compact:true).values.reduce(CGRect.null) { $0.union($1) }
            let chrome = w.frame.height-scroll.contentSize.height
            checks["fit_window_uses_collection_aspect"] = abs((resized.height-chrome)/resized.width-union.height/union.width) < 0.001
            w.setContentSize(NSSize(width:1000,height:400)); layoutCanvases()
            let content = canvases.values.reduce(CGRect.null) { $0.union($1.frame) }
            checks["fit_stays_centered_after_resize"] = abs(content.midX-desktop.bounds.midX) < 1 && abs(content.midY-desktop.bounds.midY) < 1 && autoFit
        }
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
        screenshotFixture = false; hostField.stringValue = "saved-test.local"; portField.stringValue = "5920"; presetNameField.stringValue = ""; savePresetAction()
        let savedID = presetID!
        let readsBeforeSelection = passwordReadCount
        _ = recallPreset(savedID,connect:false)
        checks["select_connection_does_not_connect"] = !connecting && !ready
        checks["select_connection_does_not_read_keychain"] = passwordReadCount == readsBeforeSelection && passwordField.stringValue.isEmpty
        checks["existing_connection_uses_update_button"] = saveConnectionButton.title == "Update Connection"

        checks["save_name_is_not_ip_address"] = presets.presets.first?.name == "Saved Connection" && presets.presets.first?.host == "saved-test.local"
        let group = PresetGroup(id:UUID().uuidString,name:"Studio",order:0); presets.groups = [group]
        checks["drag_preset_into_group"] = moveSavedItem(savedID,target:group.id,operation:.on) && presets.presets.first?.groupID == group.id
        toggleSavedGroup(group.id); checks["group_single_action_collapses"] = collapsedGroups.contains(group.id)
        toggleSavedGroup(group.id); checks["group_single_action_expands"] = !collapsedGroups.contains(group.id)
        let persisted = PresetStore(defaults:testDefaults)
        checks["groups_and_membership_persist"] = persisted.groups.first?.id == group.id && persisted.presets.first?.groupID == group.id
        if let row = savedRows.firstIndex(where:{$0.id == group.id}) { savedTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); removeSavedItem() }
        checks["removing_group_keeps_connections"] = presets.groups.isEmpty && presets.presets.count == 1 && presets.presets.first?.groupID == nil
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
        // Initial subscription must include every monitor without a manual selection action.
        DispatchQueue.main.asyncAfter(deadline:.now()+5) {
            self.exportSnapshot(path:snapshot)
            var result:[String:Any] = ["startedInConnections":startedInConnections,"sessionWindowVisible":self.window?.isVisible ?? false,"toolbarControlsEnabled":!self.map.monitors.isEmpty && self.toolbarZoom?.isEnabled == true && self.toolbarSettings?.isEnabled == true,"connectionsWindowVisible":self.connectionsWindow.isVisible,"connected":self.ready,"revision":self.revision,"framesDecoded":self.totalFrames,"framesRejected":self.rejectedFrames,"selected":self.selectedMonitors.map(\.id),"bytesReceived":self.bytesReceived,"status":self.statusLabel.stringValue]
            self.disconnect()
            result["returnedToConnections"] = self.connectionsWindow.isVisible && !(self.window?.isVisible ?? false)
            if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:report)) }
            NSApp.terminate(nil)
        }
    }
    func showDemo() {
        demo = true; ready = true; presentSession(name:"Editing Mac"); monitors = [RemoteMonitor(id:"demo-1",name:"Studio controls",width:3840,height:2160,logicalX:0,logicalWidth:1920,logicalHeight:1080,number:1),RemoteMonitor(id:"demo-2",name:"Video edit",width:2560,height:1440,logicalX:1920,logicalWidth:1920,logicalHeight:1080,number:2),RemoteMonitor(id:"demo-3",name:"Playback",width:1920,height:1080,logicalX:3840,logicalWidth:1920,logicalHeight:1080,number:3)]
        selected = ["demo-1","demo-3"]; resolutionPopup.selectItem(at:1); colorPopup.selectItem(at:0); refreshMonitorButtons(); validateResolution(); rebuildCanvases()
        for monitor in selectedMonitors { canvases[monitor.id]?.demoImage(monitor.number) }
        hostField.stringValue = "Preview · no computer connection"; statusLabel.stringValue = "Demo only · no capture, input, audio, or network connection to a computer."; metricsLabel.stringValue = "0 fps · 0 Mb/s"; connectButton.title = "Connect"
    }
    func configureScreenshot(stage:String,appearance:String,minimum:Bool,popover:String?) {
        testing = true; screenshotFixture = true
        let theme = NSAppearance(named:appearance == "dark" ? .darkAqua : .aqua)
        window?.appearance = theme; connectionsWindow.appearance = theme
        if minimum { window?.setContentSize(NSSize(width:660,height:400)); connectionsWindow.setContentSize(NSSize(width:680,height:472)) }
        hostField.stringValue = "editing-mac.local"; passwordField.stringValue = ""; statusLabel.stringValue = ""; reloadPresets()
        if ["session","paused","stacked","view-only"].contains(stage) { showDemo(); if stage == "paused" { pauseAction() }; if stage == "view-only" { viewOnlyButton.state = .on; settingsAction() }; if stage == "stacked" { monitors[1].logicalX = 0; monitors[1].logicalY = -1080; monitors[2].logicalX = 1920; allMonitorsAction() } } else { ready = false; presentConnections() }; NSApp.activate(ignoringOtherApps:true)
        if ["connections-hidden","connections-small","connections-small-expanded"].contains(stage) { connectionSidebar?.isCollapsed = true }
        if stage.hasPrefix("connections-small") {
            var frame = connectionsWindow.frame; frame.size.width = 420; connectionsWindow.setFrame(frame,display:true)
            if stage == "connections-small-expanded" { toggleConnectionSidebar() }
        }
        if popover == "labels" { window?.toolbarStyle = .expanded; window?.toolbar?.displayMode = .iconAndLabel }
        if let popover {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                if popover == "settings", let b = self.toolbarSettings { self.settingsPopoverAction(b) }
                if popover == "displays" { self.expandedDisplays() }
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
