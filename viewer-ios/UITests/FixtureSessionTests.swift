import XCTest
import Darwin

/// The composed app against a real, isolated Portlight fixture host (three synthetic displays, no capture, no
/// input injection). `scripts/test-e2e` starts the fixture on a free loopback port of the Mac running the
/// simulator and exports PORTLIGHT_FIXTURE_HOST, _PORT, _FINGERPRINT and _PASSWORD; `scripts/test-ui` forwards
/// them to this runner. Without them (an ordinary `scripts/test-ui` run) every test is skipped.
///
/// Each launch uses a fresh PORTLIGHT_TEST_DATA_DIR (in-memory secrets, never the Keychain) and writes the
/// engine transcript (PORTLIGHT_TRANSCRIPT=1) to its own file in the app's Documents, which test-e2e checks.
final class FixtureSessionTests: XCTestCase {
    private struct Fixture {
        let host: String
        let port: Int
        let fingerprint: String
        let password: String
    }

    /// Also listed in scripts/test-e2e, which checks that no transcript contains it.
    static let wrongPassword = "wrong-e2e-password"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: Tests

    /// DISP-01, NET-01, VIEW-02, QUALITY-01, SAVE-01: save a connection, trust the fixture's exact certificate,
    /// see all three displays, change the selection, quality, pause and control state, disconnect back to the
    /// form, reconnect from the row's context menu with the saved password and pin, then relaunch and find the
    /// connection saved (selecting it connects nothing).
    @MainActor
    func testA_TrustConnectAndDriveTheSession() throws {
        let fixture = try fixture()
        let dataDirectory = "e2e-session-" + UUID().uuidString
        let app = launch(dataDirectory: dataDirectory, transcriptFile: "portlight-transcript.log")

        fillNewConnection(app, name: "Fixture", host: fixture.host, password: fixture.password, port: fixture.port)
        app.buttons["connection.save"].tap()
        waitFor(app.buttons["connection.save"], "label == 'Update Connection'", timeout: 10, "Save Connection didn't save")
        XCTAssertTrue(app.navigationBars["Fixture"].exists, "the form now edits the saved connection")
        capture(app, "fixture-saved-form")

        app.buttons["connection.connect"].tap()
        approveTrust(app, fixture: fixture, screenshot: "fixture-trust-sheet")

        // First connection in this data directory: the gesture guide appears once, by itself.
        let guide = app.navigationBars["Gesture Guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 30), "the gesture guide should appear on the first session")
        capture(app, "fixture-gesture-guide")
        guide.buttons["Done"].tap()

        waitUntilConnected(app)
        XCTAssertTrue(app.descendants(matching: .any)["session.surface.ready"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["chrome.displays"].value as? String, "3 of 3 shown")
        pause(4) // decoded frames for all three displays
        capture(app, "fixture-connected")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(app, landscape: true)
        pause(3)
        capture(app, "fixture-connected-landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(app, landscape: false)
        pause(2)

        openMore(app, item: "Diagnostics")
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 10))
        expandSheet(app, title: "Diagnostics")
        capture(app, "fixture-diagnostics")
        app.navigationBars["Diagnostics"].buttons["Done"].tap()

        // Displays: three rows, all shown; hiding Display 2 puts 1 and 3 side by side.
        app.buttons["chrome.displays"].tap()
        XCTAssertTrue(app.navigationBars["Displays"].waitForExistence(timeout: 10))
        expandSheet(app, title: "Displays")
        let row2 = app.buttons["displays.row.2"]
        XCTAssertTrue(row2.waitForExistence(timeout: 10))
        for number in 1...3 {
            XCTAssertEqual(app.buttons["displays.row.\(number)"].value as? String, "Shown", "display \(number)")
        }
        XCTAssertFalse(app.buttons["displays.row.4"].exists, "the fixture has exactly three displays")
        capture(app, "fixture-displays-sheet")
        row2.tap()
        waitFor(row2, "value == 'Hidden'", timeout: 5, "Display 2 didn't turn off")
        capture(app, "fixture-displays-2-off-sheet")
        app.navigationBars["Displays"].buttons["Done"].tap()
        waitFor(app.buttons["chrome.displays"], "value == '2 of 3 shown'", timeout: 10, "the selection didn't change")
        pause(4)
        capture(app, "fixture-display-2-off")

        // Quality: four resolutions, three colours, no FPS; 256 Colors resubscribes.
        openMore(app, item: "Quality…")
        XCTAssertTrue(app.navigationBars["Quality"].waitForExistence(timeout: 10))
        expandSheet(app, title: "Quality")
        XCTAssertTrue(app.buttons["quality.resolution.hd"].waitForExistence(timeout: 10))
        for preset in ["hd", "fhd", "qhd", "uhd"] {
            XCTAssertTrue(app.buttons["quality.resolution.\(preset)"].exists, preset)
        }
        XCTAssertTrue(app.buttons["quality.resolution.hd"].isSelected, "HD is the phone's starting ceiling")
        for mode in ["full", "color256", "gray16"] {
            XCTAssertTrue(app.buttons["quality.color.\(mode)"].exists, mode)
        }
        let fps = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'fps' OR label CONTAINS[c] 'frame rate' OR identifier CONTAINS[c] 'fps'"))
        XCTAssertEqual(fps.count, 0, "no FPS control")
        capture(app, "fixture-quality")
        app.buttons["quality.color.color256"].tap()
        XCTAssertTrue(app.buttons["quality.color.color256"].isSelected)
        app.navigationBars["Quality"].buttons["Done"].tap()
        pause(4)
        capture(app, "fixture-256-colors")

        // Pause dims the retained picture and blocks input; Resume restores it.
        let pauseButton = app.buttons["chrome.pause"]
        pauseButton.tap()
        XCTAssertTrue(app.buttons["paused.resume"].waitForExistence(timeout: 10))
        XCTAssertEqual(pauseButton.label, "Resume")
        pause(1)
        capture(app, "fixture-paused")
        app.buttons["paused.resume"].tap()
        waitFor(app.buttons["paused.resume"], "exists == false", timeout: 10, "Resume didn't clear the overlay")

        // View Only: a different word, icon and style.
        let control = app.buttons["chrome.control"]
        XCTAssertEqual(control.label, "Control On")
        XCTAssertTrue(control.isSelected)
        control.tap()
        waitFor(control, "label == 'View Only'", timeout: 5, "Control didn't switch to View Only")
        XCTAssertFalse(control.isSelected)
        pause(1)
        capture(app, "fixture-view-only")

        // Disconnect returns to the connection's form.
        app.buttons["chrome.disconnect"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout: 15), "Disconnect should return to the form")
        XCTAssertTrue(app.navigationBars["Fixture"].exists)
        capture(app, "fixture-after-disconnect")

        // Back in the list, the saved row connects from its context menu with the saved password and pin.
        app.navigationBars["Fixture"].buttons.element(boundBy: 0).tap()
        let row = app.buttons["connections.row.Fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the saved connection is listed")
        capture(app, "fixture-saved-list")
        row.press(forDuration: 1.5)
        let connect = app.buttons["Connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "the row's context menu offers Connect")
        connect.tap()
        waitUntilConnected(app)
        XCTAssertFalse(app.buttons["trust.approve"].exists, "a pinned certificate needs no second approval")
        XCTAssertFalse(app.navigationBars["Gesture Guide"].exists, "the gesture guide is shown only once")
        pause(3)
        capture(app, "fixture-context-menu-connected")
        app.buttons["chrome.disconnect"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout: 15), "the session ends on the row's form")
        XCTAssertTrue(app.navigationBars["Fixture"].exists)

        // Relaunch: the connection is still saved, and selecting it only opens the form.
        app.terminate()
        let relaunched = launch(dataDirectory: dataDirectory, transcriptFile: nil)
        let savedRow = relaunched.buttons["connections.row.Fixture"]
        XCTAssertTrue(savedRow.waitForExistence(timeout: 15), "the connection survives a relaunch")
        capture(relaunched, "fixture-relaunch-list")
        savedRow.tap()
        XCTAssertTrue(relaunched.buttons["connection.connect"].waitForExistence(timeout: 10))
        pause(2)
        XCTAssertFalse(relaunched.buttons["status.cancel"].exists, "selecting a row never connects")
        XCTAssertFalse(relaunched.buttons["trust.approve"].exists, "selecting a row never connects")
        capture(relaunched, "fixture-relaunch-form")
    }

    /// NET-04 (UI): a wrong password is reported as such after the certificate was trusted; no Try Again.
    @MainActor
    func testB_WrongPasswordShowsPasswordNotAccepted() throws {
        let fixture = try fixture()
        let app = launch(dataDirectory: "e2e-wrong-password-" + UUID().uuidString,
                         transcriptFile: "portlight-transcript-wrong-password.log")
        fillNewConnection(app, name: "Wrong Password", host: fixture.host, password: Self.wrongPassword, port: fixture.port)
        app.buttons["connection.connect"].tap()
        approveTrust(app, fixture: fixture, screenshot: nil)

        expectFailureTitle(app, "Password Not Accepted")
        XCTAssertFalse(app.buttons["failure.tryAgain"].exists, "a rejected password is never retried as is")
        capture(app, "fixture-wrong-password")
        app.buttons["failure.dismiss"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout: 10), "Edit Connection returns to the form")
    }

    /// NET-04 (UI): a port with nothing listening is "Portlight Host Isn't Listening", with Try Again.
    @MainActor
    func testC_RefusedPortShowsHostIsNotListening() throws {
        let fixture = try fixture()
        let port = Self.unusedLoopbackPort()
        let app = launch(dataDirectory: "e2e-refused-" + UUID().uuidString, transcriptFile: "portlight-transcript-refused.log")
        fillNewConnection(app, name: "Nothing Listening", host: fixture.host, password: "unused-e2e-password", port: port)
        app.buttons["connection.connect"].tap()

        expectFailureTitle(app, "Portlight Host Isn\u{2019}t Listening")
        XCTAssertFalse(app.buttons["trust.approve"].exists, "nothing answered, so there is no certificate to trust")
        XCTAssertTrue(app.buttons["failure.tryAgain"].exists, "a refused port can be retried")
        capture(app, "fixture-refused")
        app.buttons["failure.dismiss"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout: 10), "Edit Connection returns to the form")
    }

    /// NET-04 (UI): the host's single viewer slot is taken. The test holds it with its own pinned, authenticated viewer,
    /// so the app's hello is answered with `busy` (after trust, with Try Again). Once that viewer leaves, Try Again
    /// connects with the certificate approved a moment earlier.
    @MainActor
    func testD_BusyHostShowsAnotherViewerIsConnected() throws {
        let fixture = try fixture()
        let holder = FixtureViewerSlot(fingerprint: fixture.fingerprint)
        defer { holder.close() }
        try holder.hold(host: fixture.host, port: fixture.port, password: fixture.password)

        let app = launch(dataDirectory: "e2e-busy-" + UUID().uuidString, transcriptFile: "portlight-transcript-busy.log")
        fillNewConnection(app, name: "Busy Host", host: fixture.host, password: fixture.password, port: fixture.port)
        app.buttons["connection.connect"].tap()
        approveTrust(app, fixture: fixture, screenshot: nil)

        expectFailureTitle(app, "Another Viewer Is Connected")
        let tryAgain = app.buttons["failure.tryAgain"]
        XCTAssertTrue(tryAgain.exists, "a busy host can be tried again once the other viewer leaves")
        capture(app, "fixture-busy")

        holder.close()
        pause(2) // the host frees its slot when the other viewer's socket closes
        tryAgain.tap()
        let guide = app.navigationBars["Gesture Guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 30), "the first session in this data directory shows the guide")
        guide.buttons["Done"].tap()
        waitUntilConnected(app)
        XCTAssertFalse(app.buttons["trust.approve"].exists, "the certificate approved a moment ago stays pinned")
        pause(2)
        capture(app, "fixture-busy-then-connected")
        app.buttons["chrome.disconnect"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout: 15), "Disconnect returns to the form")
    }

    /// NET-04 (UI): a computer that accepts the TCP connection and then never answers (a loopback listener this test
    /// holds without ever reading) is "The Computer Didn't Answer" at the 10 s connect deadline, with Try Again.
    @MainActor
    func testE_SilentHostShowsComputerDidNotAnswer() throws {
        let fixture = try fixture()
        let listener = try SilentLoopbackListener()
        defer { listener.close() }
        let app = launch(dataDirectory: "e2e-silent-" + UUID().uuidString, transcriptFile: "portlight-transcript-silent.log")
        fillNewConnection(app, name: "Silent Host", host: fixture.host, password: "unused-e2e-password", port: listener.port)
        app.buttons["connection.connect"].tap()

        expectFailureTitle(app, "The Computer Didn\u{2019}t Answer")
        XCTAssertFalse(app.buttons["trust.approve"].exists, "no certificate arrived, so there is nothing to trust")
        XCTAssertTrue(app.buttons["failure.tryAgain"].exists, "an unanswered connection can be retried")
        capture(app, "fixture-silent-host")
        app.buttons["failure.dismiss"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout: 10), "Edit Connection returns to the form")
    }

    /// NET-04 (UI): an address this Mac has no route to. 100::1 is in the IPv6 discard-only prefix (RFC 6666); with
    /// IPv4-only routing the kernel refuses it at once and nothing leaves the machine. Where it is routed the attempt
    /// would only time out, so the test skips.
    @MainActor
    func testF_UnroutableAddressShowsCannotReachTheComputer() throws {
        _ = try fixture()
        let address = "100::1"
        guard FixtureRouting.noRouteError(toIPv6: address, port: 9) != nil else {
            throw XCTSkip("This Mac has a route to \(address), so it can't show a no-route failure.")
        }
        let app = launch(dataDirectory: "e2e-no-route-" + UUID().uuidString, transcriptFile: "portlight-transcript-no-route.log")
        fillNewConnection(app, name: "No Route", host: address, password: "unused-e2e-password", port: 9)
        app.buttons["connection.connect"].tap()

        expectFailureTitle(app, "Can\u{2019}t Reach the Computer")
        XCTAssertFalse(app.buttons["trust.approve"].exists, "nothing answered, so there is no certificate to trust")
        XCTAssertTrue(app.buttons["failure.tryAgain"].exists, "a missing route can be retried, say after turning on a VPN")
        capture(app, "fixture-no-route")
        app.buttons["failure.dismiss"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout: 10), "Edit Connection returns to the form")
    }

    /// LIFE-01 (simulator part): going to the background ends the session and leaves the privacy cover for the app
    /// switcher's snapshot. Coming back reconnects on its own with the pin, without a second approval. test-e2e
    /// checks the transcript: the session ends between two welcomes, and no input is sent.
    @MainActor
    func testG_BackgroundCoversTheSessionAndForegroundReconnects() throws {
        let fixture = try fixture()
        let app = launch(dataDirectory: "e2e-lifecycle-" + UUID().uuidString, transcriptFile: "portlight-transcript-lifecycle.log")
        fillNewConnection(app, name: "Lifecycle", host: fixture.host, password: fixture.password, port: fixture.port)
        app.buttons["connection.connect"].tap()
        approveTrust(app, fixture: fixture, screenshot: nil)
        let guide = app.navigationBars["Gesture Guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 30), "the first session in this data directory shows the guide")
        guide.buttons["Done"].tap()
        waitUntilConnected(app)
        pause(3)

        XCUIDevice.shared.press(.home)
        let inBackground = NSPredicate { _, _ in [.runningBackground, .runningBackgroundSuspended].contains(app.state) }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: inBackground, object: nil)], timeout: 20),
                       .completed, "the app should reach the background")
        // The app switcher shows the snapshot iOS took on the way out: the privacy cover, not the Mac's screen.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.998))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)),
                   withVelocity: .slow, thenHoldForDuration: 1.0)
        pause(2)
        let switcher = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        switcher.name = "fixture-app-switcher"
        switcher.lifetime = .keepAlways
        add(switcher)

        app.activate()
        waitUntilConnected(app)
        XCTAssertFalse(app.buttons["trust.approve"].exists, "the pinned certificate needs no second approval")
        XCTAssertTrue(app.descendants(matching: .any)["session.surface.ready"].waitForExistence(timeout: 15))
        pause(3)
        capture(app, "fixture-foreground-reconnected")
        app.buttons["chrome.disconnect"].tap()
        XCTAssertTrue(app.buttons["connection.connect"].waitForExistence(timeout: 15), "Disconnect returns to the form")
    }

    // MARK: Steps

    private func fixture() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["PORTLIGHT_FIXTURE_HOST"], !host.isEmpty,
              let port = environment["PORTLIGHT_FIXTURE_PORT"].flatMap(Int.init),
              let fingerprint = environment["PORTLIGHT_FIXTURE_FINGERPRINT"], !fingerprint.isEmpty,
              let password = environment["PORTLIGHT_FIXTURE_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("No fixture host: run scripts/test-e2e, which starts one and passes PORTLIGHT_FIXTURE_*.")
        }
        return Fixture(host: host, port: port, fingerprint: fingerprint, password: password)
    }

    /// - Parameter transcriptFile: the transcript's name in Documents; nil writes none (so a relaunch never
    ///   truncates an earlier transcript).
    @MainActor
    private func launch(dataDirectory: String, transcriptFile: String?) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PORTLIGHT_TEST_DATA_DIR"] = dataDirectory
        if let transcriptFile {
            app.launchEnvironment["PORTLIGHT_TRANSCRIPT"] = "1"
            app.launchEnvironment["PORTLIGHT_TRANSCRIPT_FILE"] = transcriptFile
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 30), "the Connections list should appear")
        return app
    }

    @MainActor
    private func fillNewConnection(_ app: XCUIApplication, name: String, host: String, password: String, port: Int) {
        let newConnection = app.buttons["New Connection"].firstMatch
        XCTAssertTrue(newConnection.waitForExistence(timeout: 10), "a fresh data directory starts empty")
        newConnection.tap()

        let nameField = app.textFields["connection.field.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(name)
        let hostField = app.textFields["connection.field.host"]
        hostField.tap()
        hostField.typeText(host)
        let passwordField = app.secureTextFields["connection.field.password"]
        passwordField.tap()
        passwordField.typeText(password)
        let portField = app.textFields["connection.field.port"]
        portField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        portField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + String(port))
        XCTAssertEqual(portField.value as? String, String(port))
        let done = app.toolbars.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
    }

    /// The sheet must show exactly the fixture's certificate (hex digits compared, separators ignored).
    @MainActor
    private func approveTrust(_ app: XCUIApplication, fixture: Fixture, screenshot: String?) {
        let approve = app.buttons["trust.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 30), "a first connection asks to trust the certificate")
        XCTAssertTrue(app.staticTexts["Trust This Computer?"].exists)
        let shown = app.descendants(matching: .any)["trust.fingerprint"].firstMatch.value as? String ?? ""
        XCTAssertEqual(Self.hexDigits(shown), Self.hexDigits(fixture.fingerprint), "the sheet must show the fixture's fingerprint")
        XCTAssertEqual(Self.hexDigits(shown).count, 64)
        if let screenshot { capture(app, screenshot) }
        approve.tap()
    }

    @MainActor
    private func waitUntilConnected(_ app: XCUIApplication) {
        let title = app.descendants(matching: .any)["chrome.title"].firstMatch
        waitFor(title, "label CONTAINS 'Connected'", timeout: 45, "the session never reached Connected")
    }

    /// The failure card combines its texts into one element, so more than one element can carry the title's
    /// identifier: one of them must read exactly the title (alone, or first in the combined label).
    @MainActor
    private func expectFailureTitle(_ app: XCUIApplication, _ expected: String) {
        let titles = app.descendants(matching: .any).matching(identifier: "failure.title")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 30), "the failure card should appear")
        let match = titles.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", expected, expected + ",")).firstMatch
        XCTAssertTrue(match.exists, "the failure card should read \(expected); found \(titles.allElementsBoundByIndex.map(\.label))")
    }

    /// Sheets open at the medium detent, where a list creates no cells below the fold: drag the sheet's
    /// navigation bar up to the large detent first.
    @MainActor
    private func expandSheet(_ app: XCUIApplication, title: String) {
        let bar = app.navigationBars[title]
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: top)
        pause(1)
    }

    @MainActor
    private func openMore(_ app: XCUIApplication, item: String) {
        app.buttons["chrome.more"].tap()
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "More should offer \(item)")
        button.tap()
    }

    @MainActor
    private func waitForOrientation(_ app: XCUIApplication, landscape: Bool) {
        let window = app.windows.firstMatch
        let predicate = NSPredicate { _, _ in (window.frame.width > window.frame.height) == landscape }
        // Rotation on a busy simulator host can take well over 10 s; the assertion is about the end state.
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 45), .completed,
                       "the window never turned \(landscape ? "landscape" : "portrait")")
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Reading a frame waits for the app to go idle, so the screenshot never catches a transition.
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        _ = app.windows.firstMatch.frame
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    static func hexDigits(_ text: String) -> String {
        String(text.uppercased().filter { "0123456789ABCDEF".contains($0) })
    }

    /// A loopback port nothing listens on: bind port 0, read the port the system chose, close it.
    static func unusedLoopbackPort() -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return 9 }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(descriptor, raw, length) == 0 && getsockname(descriptor, raw, &length) == 0
            }
        }
        guard bound else { return 9 }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
