import Foundation

/// Builds complete desired states: revision 1 right after `welcome` (called by the engine in the same turn)
/// and every later subscription (called by the controller), so both follow one set of rules.
///
/// - Selection: a fresh connection takes every advertised display in host order, at most 16 (the wire
///   limit); a reconnect keeps the previous IDs that still exist, in host order, and never adds others.
/// - Resolution: `RenderBudget.highestPreset` for the selected displays, so the phone's memory budget lowers
///   the stream resolution instead of dropping displays.
/// - Audio: requested only when enabled, not paused, and advertised; the codec is the host's preferred one.
/// - Dither: `settings.effectiveDither`. Regions: none (every display in full) unless refined later.
/// The revision is left 0: the engine assigns revisions.
public struct DefaultSubscriptionPlanner: SubscriptionPlanner {
    public var settings: SessionSettings
    public var pixelBudget: Int
    /// A lower ceiling imposed after the host's canvases exceeded the budget (nil = none).
    public var resolutionCap: ResolutionPreset?

    public init(settings: SessionSettings, pixelBudget: Int = RenderBudget.devicePixelBudget, resolutionCap: ResolutionPreset? = nil) {
        self.settings = settings; self.pixelBudget = pixelBudget; self.resolutionCap = resolutionCap
    }

    public func initialSubscription(for welcome: WelcomeMessage, previousSelection: [DisplayID]?) -> SubscriptionRequest {
        let selection = Self.initialSelection(displays: welcome.displays, previousSelection: previousSelection)
        return Self.request(displays: welcome.displays, selection: selection, settings: settings,
                            capabilities: welcome.capabilities, pixelBudget: pixelBudget, resolutionCap: resolutionCap)
    }

    /// nil: every display (fresh connection). Non-nil: the previous selection intersected with the host's displays.
    public static func initialSelection(displays: [HostDisplay], previousSelection: [DisplayID]?) -> [DisplayID] {
        hostOrdered(previousSelection ?? displays.map(\.id), in: displays)
    }

    /// `ids` that name an advertised display, in host order, without duplicates, at most 16.
    public static func hostOrdered(_ ids: [DisplayID], in displays: [HostDisplay]) -> [DisplayID] {
        let wanted = Set(ids)
        var seen = Set<DisplayID>()
        var result: [DisplayID] = []
        for display in displays where wanted.contains(display.id) && seen.insert(display.id).inserted {
            result.append(display.id)
        }
        return Array(result.prefix(PortlightProtocol.maxSubscribedDisplays))
    }

    /// The preset to request for this selection, and whether the memory budget (or the cap) lowered it.
    public static func resolution(displays: [HostDisplay], selection: [DisplayID], requested: ResolutionPreset,
                                  cap: ResolutionPreset?, pixelBudget: Int) -> (preset: ResolutionPreset, limitedByBudget: Bool) {
        let selected = selectedDisplays(displays, selection)
        let ceiling = cap.map { min($0, requested) } ?? requested
        let result = RenderBudget.highestPreset(displays: selected, requested: ceiling, budget: pixelBudget)
        return (result.preset, result.limitedByBudget || ceiling != requested)
    }

    public static func request(displays: [HostDisplay], selection: [DisplayID], settings: SessionSettings,
                               capabilities: HostCapabilities?, pixelBudget: Int, resolutionCap: ResolutionPreset? = nil,
                               regions: [DisplayID: NormalizedRect] = [:]) -> SubscriptionRequest {
        let preset = resolution(displays: displays, selection: selection, requested: settings.resolution,
                                cap: resolutionCap, pixelBudget: pixelBudget).preset
        let audioAdvertised = capabilities?.supportsAudio ?? false
        // Omitted = the whole display; `.full` entries are dropped so equivalent states compare equal.
        let wanted = Set(selection)
        let refined = regions.filter { wanted.contains($0.key) && $0.value.isValid && !$0.value.isFull }
        return SubscriptionRequest(
            revision: 0, displays: selection, resolution: preset, color: settings.color, quality: settings.quality,
            fps: 60, bandwidthKbps: ViewerPreferences.wireBandwidthKbps(settings.bandwidthKbps),
            paused: settings.paused, audio: settings.audioEnabled && !settings.paused && audioAdvertised,
            audioCodec: capabilities?.preferredAudioCodec ?? .aac, audioBitrate: settings.audioQuality,
            viewOnly: !settings.controlEnabled, regions: refined, dither: settings.effectiveDither)
    }

    static func selectedDisplays(_ displays: [HostDisplay], _ selection: [DisplayID]) -> [HostDisplay] {
        let wanted = Set(selection)
        return displays.filter { wanted.contains($0.id) }
    }
}
