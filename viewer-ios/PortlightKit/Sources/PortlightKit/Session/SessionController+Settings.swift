import Foundation

// Selection, stream settings and viewport commands. Every change resends the complete desired state; the
// engine drops a request equivalent to the last one it sent.
extension SessionController {
    // MARK: Selection

    public func toggleDisplay(_ id: DisplayID) {
        var next = selection
        if let index = next.firstIndex(of: id) { next.remove(at: index) } else { next.append(id) }
        setSelection(next)
    }

    public func selectAll() { setSelection(displays.map(\.id)) }

    /// None is valid: an empty subscription, the empty state, and no input.
    public func selectNone() { setSelection([]) }

    /// Releases held input, re-lays out the compact desktop (Fit refits; otherwise the anchor holds), then
    /// submits. Unknown IDs are ignored; the order is always the host's; at most 16.
    public func setSelection(_ ids: [DisplayID]) {
        let next = DefaultSubscriptionPlanner.hostOrdered(ids, in: displays)
        guard next != selection else { return }
        releaseInput()
        selection = next
        regions = [:]
        resolutionCap = nil
        displayBudgetExceeded = false
        scheduler.cancel()
        applyLayout()
        recomputePresetAvailability()
        syncDerivedState()
        submitDesired()
    }

    // MARK: Stream settings (persisted to the profile)

    /// The ceiling; the phone's memory budget may lower what is requested (see `presetAvailability`).
    /// Never moves the viewport: the world is in logical points.
    public func setResolution(_ preset: ResolutionPreset) {
        guard settings.resolution != preset || resolutionCap != nil else { return }
        settings.resolution = preset
        resolutionCap = nil
        displayBudgetExceeded = false
        recomputePresetAvailability()
        settingsChanged(persist: true)
    }

    public func setColor(_ color: ColorMode) {
        guard settings.color != color else { return }
        settings.color = color
        settingsChanged(persist: true)
    }

    public func setQuality(_ quality: ContentPriority) {
        guard settings.quality != quality else { return }
        settings.quality = quality
        settingsChanged(persist: true)
    }

    public func setSmoothGradients(_ enabled: Bool) {
        guard settings.smoothGradients != enabled else { return }
        settings.smoothGradients = enabled
        settingsChanged(persist: true)
    }

    /// 0 = Automatic; manual values are clamped to 100...100000 kbps.
    public func setBandwidth(kbps: Int) {
        let value = ViewerPreferences.wireBandwidthKbps(kbps)
        guard settings.bandwidthKbps != value else { return }
        settings.bandwidthKbps = value
        settingsChanged(persist: true)
    }

    /// Choosing a rate never turns audio on.
    public func setAudioQuality(_ quality: AudioQuality) {
        guard settings.audioQuality != quality else { return }
        settings.audioQuality = quality
        settingsChanged(persist: true)
    }

    /// Remote audio on or off (not saved: audio starts off on every connection).
    public func setAudioEnabled(_ enabled: Bool) {
        guard settings.audioEnabled != enabled else { return }
        settings.audioEnabled = enabled
        if enabled, capabilities != nil, !audioAvailable { post(.audioUnavailable) }
        settingsChanged(persist: false)
    }

    // MARK: Control state (releases input and clears latches first)

    /// Control On / View Only. View Only keeps local navigation and sends no input.
    public func setControlEnabled(_ enabled: Bool) {
        guard settings.controlEnabled != enabled else { return }
        if !enabled { cancelTyping() } // text still being typed stops with control
        releaseInput(clearingLatches: true)
        settings.controlEnabled = enabled
        syncDerivedState()
        submitDesired()
    }

    /// Pause sends `paused: true, audio: false` and keeps the audio preference; Resume restores it.
    public func setPaused(_ paused: Bool) {
        guard settings.paused != paused else { return }
        if paused { cancelTyping() } // text still being typed stops with the stream
        releaseInput(clearingLatches: true)
        settings.paused = paused
        syncDerivedState()
        submitDesired()
        if !paused { noteViewportChange() } // the view may have moved while paused
    }

    /// Trackpad, Direct or local Pan. Pan is never saved as the starting mode.
    public func setInputMode(_ mode: InputMode) {
        guard settings.inputMode != mode else { return }
        releaseInput(clearingLatches: true)
        settings.inputMode = mode
        if mode != .pan {
            lastNonPanMode = mode
            persistPreferences()
        }
        syncDerivedState()
    }

    func settingsChanged(persist: Bool) {
        if persist { persistPreferences() }
        releaseInput()
        syncDerivedState()
        submitDesired()
    }

    // MARK: Viewport

    /// Drawable size, safe-area (keyboard-free) rect and pixel density of the session surface.
    public func surfaceGeometryChanged(drawableSize: PixelSize, usableRect: DrawableRect, contentScale: Double) {
        changeViewport { $0.setGeometry(drawableSize: drawableSize, usableRect: usableRect, contentScale: contentScale) }
    }

    public func fit() { changeViewport { $0.fit() } }

    /// One host logical point per UI point.
    public func actualSize() { changeViewport { $0.actualSize() } }

    /// Zoom In / Zoom Out by about 10% around the usable center.
    public func zoom(in stepIn: Bool) { changeViewport { $0.zoom(stepIn: stepIn) } }

    public func setControlsHidden(_ hidden: Bool) {
        controlsHidden = hidden
        interpreter.controlsHidden = hidden
    }

    public func setKeyboardRequested(_ requested: Bool) {
        keyboardRequested = requested
    }

    func applyLayout() {
        let layout = DesktopLayout.arrange(displays, selected: selection, compact: true)
        let scales = Dictionary(displays.map { ($0.id, $0.scale) }, uniquingKeysWith: { first, _ in first })
        changeViewport { $0.setLayout(layout, hostScales: scales) }
    }

    func changeViewport(_ body: (inout ViewportModel) -> Void) {
        let before = viewportModel
        body(&viewportModel)
        if viewportModel != before { viewportDidChange() } else { publishViewport() }
    }

    /// Publishes the camera and restarts the settle clock for region refinement.
    func viewportDidChange() {
        publishViewport()
        noteViewportChange()
    }

    func noteViewportChange() {
        scheduler.viewportDidChange(at: now)
        // One pending timer is enough: an early firing answers `.wait` with the remaining time.
        if timers[.settle] == nil { schedule(.settle, after: RegionScheduler.settleDelay) }
    }

    func evaluateRegions() {
        let context = RegionScheduler.Context(connected: phase == .connected, paused: settings.paused,
                                              touchesActive: interpreter.hasActiveTouches, holdingInput: ledger.isHoldingInput,
                                              viewport: viewportModel, selection: selection, current: acceptedRegions)
        switch scheduler.evaluate(at: now, context) {
        case .wait(let remaining):
            schedule(.settle, after: remaining)
        case .submit(let planned):
            regions = planned.filter { !$0.value.isFull }
            scheduler.refinementSubmitted(at: now, regions: planned)
            submitDesired()
        case .idle, .deferred:
            break
        }
    }

    // MARK: Preset availability

    /// Per preset: unavailable when a selected display is smaller than it (the host would not deliver it)
    /// or when its canvases don't fit this device's budget. HD stays choosable, with a reason when over budget.
    func recomputePresetAvailability() {
        let selected = DefaultSubscriptionPlanner.selectedDisplays(displays, selection)
        let next = ResolutionPreset.allCases.map { preset -> PresetAvailability in
            guard !selected.isEmpty else { return PresetAvailability(preset: preset, isAvailable: true) }
            if preset != .hd, let small = selected.first(where: { !preset.isSupported(byNative: $0.nativeSize) }) {
                return PresetAvailability(preset: preset, isAvailable: false,
                                          reason: "\(small.name) is smaller than \(preset.title).")
            }
            let fit = RenderBudget.highestPreset(displays: selected, requested: preset, budget: dependencies.pixelBudget)
            if fit.preset != preset || fit.limitedByBudget {
                let count = selected.count == 1 ? "1 display" : "\(selected.count) displays"
                return PresetAvailability(preset: preset, isAvailable: preset == .hd,
                                          reason: "\(preset.title) needs more memory than this iPhone allows for \(count).")
            }
            return PresetAvailability(preset: preset, isAvailable: true)
        }
        if presetAvailability != next { presetAvailability = next }
    }

    // MARK: Persistence

    var currentPreferences: ViewerPreferences {
        ViewerPreferences(resolution: settings.resolution, color: settings.color, quality: settings.quality,
                          inputMode: settings.inputMode == .pan ? lastNonPanMode : settings.inputMode,
                          audioQuality: settings.audioQuality, bandwidthKbps: settings.bandwidthKbps,
                          smoothGradients: settings.smoothGradients)
    }

    func persistPreferences() {
        guard let writer = preferenceWriter, let id = connection?.profile.id else { return }
        let preferences = currentPreferences
        writer.update(profile: id) { $0.preferences = preferences }
    }

    func recordConnected() {
        guard let writer = preferenceWriter, let id = connection?.profile.id else { return }
        let date = dependencies.wallClock()
        writer.update(profile: id) { $0.lastConnectedAt = date }
    }
}
