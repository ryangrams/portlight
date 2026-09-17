import Testing
import UIKit
@testable import Portlight

@MainActor
@Test func rootViewBuilds() {
    let model = AppModel(environment: AppEnvironment(configuration: AppTestSupport.configuration()))
    _ = RootView(model: model).body
}
