import Testing
import UIKit
import PortlightKit
@testable import Portlight

/// The composed app: launch configuration, the launch load and orphan sweep, Save/Connect flows through
/// `AppModel`, and the pure session-screen mappings. No network: every Connect here stops before a socket opens.
@MainActor
@Suite("App composition")
struct AppCompositionTests {
    // MARK: Configuration

    @Test func launchEnvironmentSelectsTestStoresAndTranscript() {
        let temp = AppTestSupport.url("/tmp/app-temp")
        let documents = AppTestSupport.url("/tmp/app-docs")
        let relative = AppConfiguration.from(environment: ["PORTLIGHT_TEST_DATA_DIR": "run-1", "PORTLIGHT_TRANSCRIPT": "1"],
                                             temporaryDirectory: temp, documentsDirectory: documents)
        #expect(relative.dataDirectory?.path == "/tmp/app-temp/run-1")
        #expect(relative.usesTestStores)
        #expect(relative.defaultsSuiteName == "studio.upgrade.portlight.test.run-1")
        #expect(relative.transcriptURL?.path == "/tmp/app-docs/portlight-transcript.log")

        let absolute = AppConfiguration.from(environment: ["PORTLIGHT_TEST_DATA_DIR": "/tmp/elsewhere",
                                                           "PORTLIGHT_TRANSCRIPT": "1",
                                                           "PORTLIGHT_TRANSCRIPT_FILE": "portlight-transcript-refused.log"],
                                             temporaryDirectory: temp, documentsDirectory: documents)
        #expect(absolute.dataDirectory?.path == "/tmp/elsewhere")
        #expect(absolute.transcriptURL?.lastPathComponent == "portlight-transcript-refused.log")

        let production = AppConfiguration.from(environment: [:], temporaryDirectory: temp, documentsDirectory: documents)
        #expect(production == .production)
        #expect(!production.usesTestStores)
        #expect(AppConfiguration.from(environment: ["PORTLIGHT_TRANSCRIPT": "0"], temporaryDirectory: temp,
                                      documentsDirectory: documents).transcriptURL == nil)
    }

    @Test func transcriptNamesStayInsideDocuments() {
        #expect(AppConfiguration.transcriptFileName(nil) == AppConfiguration.defaultTranscriptName)
        #expect(AppConfiguration.transcriptFileName("../escape.log") == AppConfiguration.defaultTranscriptName)
        #expect(AppConfiguration.transcriptFileName(".hidden") == AppConfiguration.defaultTranscriptName)
        #expect(AppConfiguration.transcriptFileName("a\\b") == AppConfiguration.defaultTranscriptName)
        #expect(AppConfiguration.transcriptFileName("portlight-transcript-b.log") == "portlight-transcript-b.log")
    }

    @Test func hostedUnitTestsAreDetected() {
        #expect(AppConfiguration.isHostingUnitTests(["XCTestConfigurationFilePath": "/x"]))
        #expect(!AppConfiguration.isHostingUnitTests(["PORTLIGHT_TEST_DATA_DIR": "x"]))
    }

    @Test func testStoresNeverUseTheKeychain() {
        let environment = AppEnvironment(configuration: AppTestSupport.configuration())
        #expect(environment.secrets is InMemorySecretStore)
        #expect(environment.transcript == nil)
        #expect(environment.storageNotice == nil)
    }

    // MARK: Launch load

    @Test func everyLaunchOutcomeButACleanLoadHasANotice() {
        let file = AppTestSupport.url("/tmp/Connections.json.damaged")
        #expect(AppModel.launchNotice(for: .loaded) == nil)
        for outcome: ProfileStore.LoadOutcome in [.recovered(quarantinedFile: file),
                                                  .partiallyRecovered(dropped: 2, quarantinedCopy: file),
                                                  .unavailable(reason: "locked"), .newerVersion(schemaVersion: 9)] {
            #expect(AppModel.launchNotice(for: outcome)?.isEmpty == false, "\(outcome)")
        }
    }

    @Test func orphanedPasswordsAreRemovedOnlyAfterACleanLoad() throws {
        let environment = AppEnvironment(configuration: AppTestSupport.configuration())
        var draft = AppTestSupport.draft(password: "fixture-secret")
        let first = AppModel(environment: environment)
        _ = first.save(&draft)
        let saved = try #require(first.library.profiles.first)
        try environment.secrets.setPassword("left-behind", for: "orphan-account")

        let relaunched = AppModel(environment: environment)
        #expect(relaunched.notices.isEmpty)
        #expect(try environment.secrets.listAccounts() == [saved.secretAccount])
    }

    @Test func aDamagedFileShowsANoticeAndKeepsEveryPassword() throws {
        let configuration = AppTestSupport.configuration()
        let directory = try #require(configuration.dataDirectory)
        try AppTestSupport.write("{ not json", to: directory.appendingPathComponent(ProfileStore.fileName))
        let environment = AppEnvironment(configuration: configuration)
        try environment.secrets.setPassword("keep", for: "unknown-account")

        let model = AppModel(environment: environment)
        #expect(model.notices.count == 1)
        #expect(model.library.profiles.isEmpty)
        #expect(try environment.secrets.listAccounts() == ["unknown-account"])
    }

    // MARK: Save and Connect

    @Test func saveAddsOnceThenUpdatesAndTheFileNeverHoldsThePassword() throws {
        let environment = AppEnvironment(configuration: AppTestSupport.configuration())
        let model = AppModel(environment: environment)
        var draft = AppTestSupport.draft(password: "fixture-secret")

        #expect(model.save(&draft) == nil)
        #expect(!draft.isNew)
        draft.name = "Fixture Mac"
        #expect(model.save(&draft) == nil)

        #expect(model.library.profiles.count == 1)
        let profile = try #require(model.library.profiles.first)
        #expect(profile.displayTitle == "Fixture Mac")
        #expect(profile.hasSavedPassword)
        #expect(try environment.secrets.password(for: profile.secretAccount) == "fixture-secret")
        let file = try #require(AppTestSupport.text(at: environment.profileStore.fileURL))
        #expect(file.contains("Fixture Mac"))
        #expect(!file.contains("fixture-secret"))
        #expect(environment.profileStore.load().library.profiles.map(\.id) == [profile.id])
    }

    @Test func connectWithoutAPasswordStaysOnTheFormWithAnInlineError() throws {
        let model = AppModel(environment: AppEnvironment(configuration: AppTestSupport.configuration()))
        var draft = AppTestSupport.draft(remember: false)
        _ = model.save(&draft)

        model.connect(draft: draft)
        #expect(model.connectError == ConnectFieldError(profileID: draft.original?.id, field: .password,
                                                        message: ConnectionDraft.Message.passwordRequired))
        #expect(model.controller.phase == .idle)
        #expect(!model.isSessionPresented)
    }

    @Test func aMissingKeychainItemClearsTheSavedPasswordHint() throws {
        let environment = AppEnvironment(configuration: AppTestSupport.configuration())
        let model = AppModel(environment: environment)
        var draft = AppTestSupport.draft(password: "fixture-secret")
        _ = model.save(&draft)
        let profile = try #require(model.library.profiles.first)
        #expect(profile.hasSavedPassword)
        try environment.secrets.deletePassword(for: profile.secretAccount)

        model.connectFromList(profile)
        #expect(model.path == [.edit(profile.id)])
        #expect(model.connectError?.message == AppModel.missingSavedPassword)
        #expect(model.library.profile(id: profile.id)?.hasSavedPassword == false)
        #expect(environment.profileStore.load().library.profile(id: profile.id)?.hasSavedPassword == false)
        #expect(model.controller.phase == .idle)
    }

    @Test func listEditsNeverRevertPreferencesTheSessionSaved() throws {
        let environment = AppEnvironment(configuration: AppTestSupport.configuration())
        let model = AppModel(environment: environment)
        var draft = AppTestSupport.draft()
        _ = model.save(&draft)
        let id = try #require(model.library.profiles.first?.id)

        // The session controller writes preferences straight to the file (read-modify-write).
        var disk = environment.profileStore.load().library
        var written = try #require(disk.profile(id: id))
        written.preferences.resolution = .fhd
        _ = disk.update(written)
        try environment.profileStore.save(disk)

        var edited = model.library
        edited.createGroup(named: "Edit Suites")
        model.applyListEdit(edited)

        let saved = environment.profileStore.load().library
        #expect(saved.groups.map(\.name) == ["Edit Suites"])
        #expect(saved.profile(id: id)?.preferences.resolution == .fhd)
        #expect(model.library.profile(id: id)?.preferences.resolution == .fhd)
    }

    @Test func deletingAConnectionRemovesItsPasswordAndItsForm() throws {
        let environment = AppEnvironment(configuration: AppTestSupport.configuration())
        let model = AppModel(environment: environment)
        var draft = AppTestSupport.draft(password: "fixture-secret")
        _ = model.save(&draft)
        let profile = try #require(model.library.profiles.first)
        model.path = [.edit(profile.id)]

        model.delete(profile)
        #expect(model.library.profiles.isEmpty)
        #expect(model.path.isEmpty)
        #expect(try environment.secrets.listAccounts().isEmpty)
        #expect(environment.profileStore.load().library.profiles.isEmpty)
    }

    // MARK: Session screen mappings

    @Test func statusLineFollowsThePhaseAndTheEffectiveResolution() {
        #expect(SessionPresentation.statusLine(phase: .connected, paused: false, effective: .preset(.hd)) == "Connected · HD")
        #expect(SessionPresentation.statusLine(phase: .connected, paused: false, effective: .native) == "Connected · Native")
        #expect(SessionPresentation.statusLine(phase: .connected, paused: false, effective: nil) == "Connected")
        #expect(SessionPresentation.statusLine(phase: .connected, paused: true, effective: .preset(.fhd)) == "Paused")
        #expect(SessionPresentation.statusLine(phase: .reconnecting(attempt: 2, after: .networkLost), paused: false,
                                               effective: .preset(.hd)) == "Reconnecting")
        #expect(SessionPresentation.statusLine(phase: .authenticating, paused: false, effective: nil) == "Authenticating")
    }

    @Test func chromeShowsOnlyForAConnectedOrFrozenSession() {
        #expect(SessionPresentation.showsChrome(phase: .connected, isShowingFrozenFrame: false))
        #expect(SessionPresentation.showsChrome(phase: .reconnecting(attempt: 1, after: .networkLost), isShowingFrozenFrame: true))
        #expect(!SessionPresentation.showsChrome(phase: .connecting(patient: false), isShowingFrozenFrame: false))
        #expect(!SessionPresentation.showsChrome(phase: .failed(.refused), isShowingFrozenFrame: false))
    }

    @Test func fitUsesTheSafeAreaMinusChromeAndKeyboard() {
        let surface = AppTestSupport.portraitSurface
        let chrome = ChromeInsets(top: 50, bottom: 60)
        let usable = SessionPresentation.usableRect(safe: surface.usableRect, contentScale: 3, chrome: chrome)
        #expect(usable == DrawableRect(x: 0, y: 327, width: 1206, height: 2343 - 150 - 180))

        let rails = SessionPresentation.usableRect(safe: surface.usableRect, contentScale: 3,
                                                   chrome: ChromeInsets(leading: 84, trailing: 84))
        #expect(rails == DrawableRect(x: 252, y: 177, width: 1206 - 504, height: 2343))

        // Safe bottom is (177 + 2343) / 3 = 840 pt; a keyboard whose top is at 500 pt covers 340 pt of it.
        #expect(SessionPresentation.keyboardOverlap(keyboardTop: 500, surface: surface) == 340)
        #expect(SessionPresentation.keyboardOverlap(keyboardTop: 900, surface: surface) == 0)
        #expect(SessionPresentation.keyboardOverlap(keyboardTop: nil, surface: surface) == 0)
        let typing = SessionPresentation.usableRect(safe: surface.usableRect, contentScale: 3, chrome: chrome, keyboardOverlap: 340)
        #expect(typing.height == 2343 - 150 - 180 - 1020)
    }

    @Test func audioIsExplainedOnlyOnceTheHostSaidItHasNone() {
        #expect(SessionPresentation.audioUnavailableReason(capabilities: nil) == nil)
        let silent = HostCapabilities(imageCodecs: ["png"], audioCodecs: [], colorModes: ["full"], maxViewers: 1)
        #expect(SessionPresentation.audioUnavailableReason(capabilities: silent) == SessionNotice.audioUnavailable.message)
        let audible = HostCapabilities(imageCodecs: ["png"], audioCodecs: [.aac], colorModes: ["full"], maxViewers: 1)
        #expect(SessionPresentation.audioUnavailableReason(capabilities: audible) == nil)
    }

    @Test func qualityFootnoteNeverRepeatsThePresetName() {
        let memory = PresetAvailability(preset: .uhd, isAvailable: false, reason: "UHD for 3 displays needs more memory than this iPhone allows.")
        #expect(QualitySheet.footnote(for: memory) == "UHD for 3 displays needs more memory than this iPhone allows.")
        let controllerReason = PresetAvailability(preset: .uhd, isAvailable: false,
                                                  reason: "UHD needs more memory than this iPhone allows for 3 displays.")
        #expect(!QualitySheet.footnote(for: controllerReason).hasPrefix("UHD: UHD"))
        let smaller = PresetAvailability(preset: .qhd, isAvailable: false, reason: "Test Display 2 is smaller than QHD.")
        #expect(QualitySheet.footnote(for: smaller) == "QHD: Test Display 2 is smaller than QHD.")
        #expect(QualitySheet.footnote(for: PresetAvailability(preset: .fhd, isAvailable: false)).hasPrefix("FHD: "))
    }

    @Test func controlOnUsesAClickingPointerNotASpinnerLookalike() {
        #expect(ControlModeButton.symbol(isOn: true) == "cursorarrow.click.2")
        #expect(ControlModeButton.symbol(isOn: false) == "eye")
        #expect(UIImage(systemName: ControlModeButton.symbol(isOn: true)) != nil)
        #expect(UIImage(systemName: ControlModeButton.symbol(isOn: false)) != nil)
    }

    @Test func keyboardBarLatchesMirrorTheController() {
        let latches = ModifierLatches(displaying: [.command: .latched, .shift: .locked, .option: .off])
        #expect(latches[.command] == .latched)
        #expect(latches[.shift] == .locked)
        #expect(latches[.option] == .off)
        #expect(latches[.control] == .off)
    }

    @Test func scenePhasesMapOneToOne() {
        #expect(SessionScreen.sessionPhase(.active) == .active)
        #expect(SessionScreen.sessionPhase(.inactive) == .inactive)
        #expect(SessionScreen.sessionPhase(.background) == .background)
    }
}
