import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsConnections() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "launch-connections"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
