import Testing
@testable import PortlightKit
// No `import Foundation` in @Test files: the Command Line Tools Testing lacks the Foundation cross-import overlay.

/// The additive Session API from the review (wave 3): alerts for conditions Core's notices can't express,
/// serialized saves of Connections.json, and the precise reason a password is needed.
@Suite @MainActor struct SessionReviewAPITests {
    // MARK: Alerts

    @Test func aTruncatedPasteIsExplained() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.typePastedText(String(repeating: "x", count: 5000))
        h.settle()
        #expect(h.controller.alerts == [.textTruncated(typedCharacters: SessionController.maxTypedCharacters)])
        #expect(h.controller.notices.isEmpty)
        let alert = try #require(h.controller.alerts.first)
        #expect(alert.title == "Text Shortened")
        #expect(alert.message.hasPrefix("Only the first ") && alert.message.hasSuffix(" characters were typed on the Mac."))
        #expect(!alert.offersResume)
        h.controller.dismissAlert()
        #expect(h.controller.alerts.isEmpty)
        h.controller.typePastedText("short")
        h.settle()
        #expect(h.controller.alerts.isEmpty)
    }

    @Test func longCommittedTextIsBoundedLikeAPaste() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.insertText(String(repeating: "y", count: 10_000)) // dictation, say
        h.advanceFrames(20)
        #expect(h.typedText == String(repeating: "y", count: SessionController.maxTypedCharacters))
        #expect(h.controller.alerts == [.textTruncated(typedCharacters: SessionController.maxTypedCharacters)])
    }

    @Test func boundingKeepsWholeCharactersAndReportsCuts() {
        let limit = SessionController.maxTypedCharacters
        let exact = String(repeating: "a", count: limit)
        #expect(SessionController.boundedText(exact) == (exact, false))
        #expect(SessionController.boundedText(exact + "b") == (exact, true))
        #expect(SessionController.boundedText("") == ("", false))
        #expect(SessionController.boundedText("héllo 👋🏽") == ("héllo 👋🏽", false))
        let zalgo = "e" + String(repeating: "\u{301}", count: 20_000)
        #expect(SessionController.boundedText(zalgo) == ("", true)) // one partial character is never typed
        let flag = "🇺🇸"                                               // 2 scalars
        let flags = String(repeating: flag, count: 9000)               // 18,000 scalars: cut by the scalar bound
        let (head, cut) = SessionController.boundedText(flags)
        #expect(cut && head.count == limit && head.allSatisfy { String($0) == flag })
    }

    @Test func aFailedAudioSessionIsExplainedAndResumeStillWorks() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.setAudioEnabled(true)
        h.settle()
        h.accept(audio: true, audioCodec: .aac)
        #expect(h.controller.audioState == .playing)
        let reason = "The operation couldn’t be completed. (OSStatus error 561017449.)"
        h.audioControl.simulate(.failed(reason))
        #expect(h.controller.audioState == .interrupted)
        #expect(h.controller.alerts == [.audioFailed(reason)])
        #expect(!h.controller.notices.contains(.audioInterrupted))
        let alert = try #require(h.controller.alerts.first)
        #expect(alert.offersResume)
        #expect(alert.title == "Audio Couldn’t Start")
        #expect(!alert.message.contains("OSStatus"))
        h.controller.resumeAudio()
        #expect(h.audioControl.resumeCount == 1)
        h.audioControl.simulate(.active)
        #expect(h.controller.audioState == .playing)
        #expect(h.controller.alerts.isEmpty)
    }

    @Test func audioBannersFollowTheAudioSession() throws {
        let h = SessionHarness()
        try h.connectToStreaming()
        h.controller.setAudioEnabled(true)
        h.settle()
        h.accept(audio: true, audioCodec: .aac)
        h.audioControl.simulate(.interrupted)
        #expect(h.controller.notices == [.audioInterrupted])
        h.audioControl.simulate(.failed("refused"))  // Resume tried after the interruption, refused
        #expect(h.controller.notices == [.audioInterrupted] && h.controller.alerts == [.audioFailed("refused")])
        h.controller.resumeAudio()                  // either banner's Resume retries
        #expect(h.audioControl.resumeCount == 1)
        h.audioControl.simulate(.paused(.outputDeviceRemoved))
        #expect(h.controller.notices == [.audioInterrupted] && h.controller.alerts.isEmpty)
        h.audioControl.simulate(.active)            // the system resumed on its own
        #expect(h.controller.notices.isEmpty && h.controller.alerts.isEmpty)
    }

    // MARK: Saving Connections.json

    /// The app's load → merge → save, run inside `withProfileWritesSerialized`, sees every session write queued
    /// before it and is never overwritten by one queued during it (both keep each other's fields).
    @Test func appSavesSerializeWithTheSessionsPreferenceWrites() throws {
        let h = SessionHarness(persistProfiles: true)
        defer { h.profileFixture?.directory.remove() }
        try h.connectToStreaming()
        let store = try #require(h.profileFixture?.store)
        let writer = try #require(h.controller.preferenceWriter)
        h.controller.setColor(.gray16)            // queued off the main actor
        try h.controller.withProfileWritesSerialized {
            var library = store.load().library
            var profile = try #require(library.profile(id: SessionProfileFixture.profileID))
            #expect(profile.preferences.color == .gray16)
            writer.update(profile: SessionProfileFixture.profileID) { $0.preferences.quality = .text }
            profile.name = "Renamed"
            library.update(profile)
            try store.save(library)
            #expect(store.load().library.profile(id: SessionProfileFixture.profileID)?.preferences.quality == .automatic)
        }
        h.waitForPreferenceWrites()
        let stored = try #require(h.profileFixture?.stored())
        #expect(stored.name == "Renamed")
        #expect(stored.preferences.color == .gray16 && stored.preferences.quality == .text)
        let nested = h.controller.withProfileWritesSerialized { h.controller.withProfileWritesSerialized { 42 } }
        #expect(nested == 42)
    }

    @Test func withoutAProfileStoreSavesSimplyRun() throws {
        let h = SessionHarness()
        #expect(h.controller.withProfileWritesSerialized { 7 } == 7)
        #expect(throws: SessionConnectError.passwordRequired) {
            _ = try h.controller.withProfileWritesSerialized { () throws -> Int in throw SessionConnectError.passwordRequired }
        }
    }

    // MARK: Missing passwords

    @Test func aMissingKeychainItemIsReportedPrecisely() throws {
        let h = SessionHarness(savedPassword: nil)
        h.profile.hasSavedPassword = true
        h.profile.passwordEndpointKey = Fixture.endpoint.canonicalKey
        #expect(throws: SessionConnectError.passwordRequired) { try h.controller.connect(profile: h.profile) }
        #expect(h.controller.missingPassword == .missingFromKeychain)
        #expect(h.secrets.readCount == 1)
        #expect(h.transports.isEmpty && h.controller.phase == .idle)

        h.profile.passwordEndpointKey = "another-mac.local:5920"
        #expect(throws: SessionConnectError.passwordRequired) { try h.controller.connect(profile: h.profile) }
        #expect(h.controller.missingPassword == .differentComputer)
        #expect(h.secrets.readCount == 1) // not read for another computer

        h.profile.hasSavedPassword = false
        #expect(throws: SessionConnectError.passwordRequired) { try h.controller.connect(profile: h.profile) }
        #expect(h.controller.missingPassword == .noneSaved)
        #expect(h.secrets.readCount == 1)

        try h.connect(typedPassword: "typed")
        #expect(h.controller.missingPassword == nil)
        #expect(h.transports.count == 1)
    }

    @Test func aKeychainFailureIsNotAMissingPassword() {
        let h = SessionHarness()
        h.secrets.injectFailures(read: .keychain(-25308))
        #expect(throws: SessionConnectError.self) { try h.controller.connect(profile: h.profile) }
        #expect(h.controller.missingPassword == nil)
    }
}
