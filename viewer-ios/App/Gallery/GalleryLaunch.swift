import SwiftUI
import UIKit

/// The UI gallery is reachable only when the app is launched with PORTLIGHT_UI_GALLERY=1; any other launch shows
/// `RootView`. Optional variables:
/// - PORTLIGHT_UI_GALLERY_PAGE: open one page directly (screenshots).
/// - PORTLIGHT_UI_GALLERY_APPEARANCE: `light` or `dark`.
/// - PORTLIGHT_UI_GALLERY_A11Y: comma-separated `reduceTransparency`, `reduceMotion`, `increaseContrast`.
/// - PORTLIGHT_UI_GALLERY_STILL=1: no UIKit animations, so screenshots never catch a transition.
struct GalleryLaunch: Equatable {
    var page: GalleryPage?
    var colorScheme: ColorScheme?
    var overrides: AccessibilityOverrides
    var still: Bool

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> GalleryLaunch? {
        guard environment["PORTLIGHT_UI_GALLERY"] == "1" else { return nil }
        let scheme: ColorScheme? = switch environment["PORTLIGHT_UI_GALLERY_APPEARANCE"] {
        case "dark": .dark
        case "light": .light
        default: nil
        }
        let flags = Set((environment["PORTLIGHT_UI_GALLERY_A11Y"] ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        return GalleryLaunch(page: environment["PORTLIGHT_UI_GALLERY_PAGE"].flatMap(GalleryPage.init(rawValue:)),
                             colorScheme: scheme,
                             overrides: AccessibilityOverrides(reduceTransparency: flags.contains("reduceTransparency"),
                                                               reduceMotion: flags.contains("reduceMotion"),
                                                               increaseContrast: flags.contains("increaseContrast")),
                             still: environment["PORTLIGHT_UI_GALLERY_STILL"] == "1")
    }
}

enum GalleryPage: String, CaseIterable, Identifiable, Hashable {
    case connections
    case connectionsEmpty = "connections-empty"
    case detailNew = "detail-new"
    case detailSaved = "detail-saved"
    case trustFirstUse = "trust-first-use"
    case trustChanged = "trust-changed"
    case statusConnecting = "status-connecting"
    case statusReconnecting = "status-reconnecting"
    case failure
    case failureLocalNetwork = "failure-local-network"
    case sessionControl = "session-control"
    case sessionViewOnly = "session-view-only"
    case sessionPaused = "session-paused"
    case sessionHidden = "session-hidden"
    case sessionNotice = "session-notice"
    case sessionEmpty = "session-empty"
    case sessionContrast = "session-contrast"
    case displays
    case quality
    case keyboard
    case keyboardLive = "keyboard-live"
    case gestures
    case diagnostics
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections: "Connections"
        case .connectionsEmpty: "Connections — Empty"
        case .detailNew: "New Connection — Validation"
        case .detailSaved: "Saved Connection"
        case .trustFirstUse: "Trust — First Use"
        case .trustChanged: "Trust — Identity Changed"
        case .statusConnecting: "Connecting"
        case .statusReconnecting: "Reconnecting"
        case .failure: "Failure"
        case .failureLocalNetwork: "Failure — Local Network"
        case .sessionControl: "Session — Control On"
        case .sessionViewOnly: "Session — View Only"
        case .sessionPaused: "Session — Paused"
        case .sessionHidden: "Session — Controls Hidden"
        case .sessionNotice: "Session — Notice"
        case .sessionEmpty: "Session — No Displays"
        case .sessionContrast: "Session — Contrast"
        case .displays: "Displays"
        case .quality: "Quality"
        case .keyboard: "Keyboard Bar"
        case .keyboardLive: "Keyboard — Live Responder"
        case .gestures: "Gesture Guide"
        case .diagnostics: "Diagnostics"
        case .privacy: "Privacy Cover"
        }
    }
}

struct GalleryRootView: View {
    let launch: GalleryLaunch

    var body: some View {
        Group {
            if let page = launch.page {
                GalleryPageView(page: page)
            } else {
                GalleryIndexView()
            }
        }
        .environment(\.accessibilityOverrides, launch.overrides)
        .preferredColorScheme(launch.colorScheme)
        .onAppear {
            if launch.still { UIView.setAnimationsEnabled(false) }
        }
    }
}

/// Every page, each opened full screen with a close button.
struct GalleryIndexView: View {
    @State private var presented: GalleryPage?

    var body: some View {
        NavigationStack {
            List(GalleryPage.allCases) { page in
                Button {
                    presented = page
                } label: {
                    HStack {
                        Text(page.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("gallery.index.\(page.rawValue)")
            }
            .navigationTitle("UI Gallery")
        }
        .fullScreenCover(item: $presented) { page in
            GalleryPageView(page: page)
                .overlay(alignment: .topTrailing) {
                    Button {
                        presented = nil
                    } label: {
                        Label("Close", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .padding(.top, 52)
                    .padding(.trailing, 8)
                    .accessibilityIdentifier("gallery.close")
                }
        }
    }
}
