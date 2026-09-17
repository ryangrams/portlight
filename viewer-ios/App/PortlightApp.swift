import SwiftUI
import PortlightKit

@main
struct PortlightApp: App {
    /// Non-nil only when launched with PORTLIGHT_UI_GALLERY=1 (UI review and screenshot tests).
    private let gallery: GalleryLaunch?
    /// The composition root and its app state; nil for the gallery and while hosting unit tests, which then build
    /// no session, audio or Keychain machinery.
    @State private var model: AppModel?

    init() {
        let environment = ProcessInfo.processInfo.environment
        let gallery = GalleryLaunch.fromEnvironment(environment)
        self.gallery = gallery
        let composes = gallery == nil && !AppConfiguration.isHostingUnitTests(environment)
        _model = State(initialValue: composes ? AppModel(environment: AppEnvironment.live(environment: environment)) : nil)
    }

    var body: some Scene {
        WindowGroup {
            if let gallery {
                GalleryRootView(launch: gallery)
            } else if let model {
                RootView(model: model)
            } else {
                Color(uiColor: .systemBackground)
            }
        }
    }
}
