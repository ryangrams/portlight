import Testing
@testable import PortlightKit

@Suite("Persistence: profile values")
struct PersistenceProfileValueTests {
    private let id5 = PersistenceFixtures.id(5)

    @Test func unnamedProfileIsTitledSavedConnectionNotItsAddress() {
        for name in ["", "   ", "\n\t"] {
            let profile = ConnectionProfile(name: name, host: "192.168.1.20")
            #expect(profile.isUnnamed)
            #expect(profile.displayTitle == "Saved Connection")
            #expect(profile.subtitle == "192.168.1.20")
        }
        #expect(ConnectionProfile.unnamedTitle == "Saved Connection")
    }

    @Test func namedProfileTitleIsTrimmed() {
        let profile = ConnectionProfile(name: "  Edit Bay  ", host: "studio.local")
        #expect(!profile.isUnnamed)
        #expect(profile.displayTitle == "Edit Bay")
        #expect(profile.subtitle == "studio.local")
    }

    @Test func subtitleShowsThePortOnlyWhenNotDefault() {
        #expect(ConnectionProfile(host: "studio.local").subtitle == "studio.local")
        #expect(ConnectionProfile(host: "studio.local", port: 5921).subtitle == "studio.local:5921")
        #expect(ConnectionProfile(host: "fe80::1").subtitle == "fe80::1")
        #expect(ConnectionProfile(host: "fe80::1", port: 5921).subtitle == "[fe80::1]:5921")
    }

    @Test func endpointAndSecretAccount() throws {
        let profile = PersistenceFixtures.profile(7, host: "Studio.Local", port: 5921)
        let endpoint = try #require(profile.endpoint)
        #expect(endpoint.canonicalKey == "studio.local:5921")
        #expect(profile.secretAccount == PersistenceFixtures.id(7).uuidString)
        #expect(ConnectionProfile(host: "wss://studio.local").endpoint == nil)
    }

    // MARK: Saved-password binding

    @Test func savedPasswordIsBoundToTheProfilesOwnComputer() {
        let profile = ConnectionProfile(host: "Studio.Local", port: 5921, hasSavedPassword: true)
        #expect(profile.passwordEndpointKey == "studio.local:5921")
        #expect(profile.canUseSavedPassword(for: PersistenceFixtures.endpoint("studio.local", 5921)))
        #expect(!profile.canUseSavedPassword(for: PersistenceFixtures.endpoint("studio.local")))
        #expect(!profile.canUseSavedPassword(for: PersistenceFixtures.endpoint("other.local", 5921)))

        let explicit = ConnectionProfile(host: "new.local", hasSavedPassword: true, passwordEndpointKey: "old.local:5920")
        #expect(explicit.passwordEndpointKey == "old.local:5920")
        #expect(!explicit.canUseSavedPassword(for: PersistenceFixtures.endpoint("new.local")))

        let none = ConnectionProfile(host: "studio.local", hasSavedPassword: false, passwordEndpointKey: "studio.local:5920")
        #expect(none.passwordEndpointKey == nil)
        #expect(!none.canUseSavedPassword(for: PersistenceFixtures.endpoint("studio.local")))
    }

    @Test func decodedBindingIsKeptAndAMissingOneStaysMissing() throws {
        let bound = try PersistenceFixtures.decode(ConnectionProfile.self, json:
            #"{"id":"\#(id5.uuidString)","host":"b.local","port":5920,"hasSavedPassword":true,"passwordEndpointKey":"a.local:5920"}"#)
        #expect(bound.passwordEndpointKey == "a.local:5920")
        #expect(!bound.canUseSavedPassword(for: PersistenceFixtures.endpoint("b.local")))

        // Saved before passwords were bound: never used automatically.
        let legacy = try PersistenceFixtures.decode(ConnectionProfile.self, json:
            #"{"id":"\#(id5.uuidString)","host":"a.local","port":5920,"hasSavedPassword":true}"#)
        #expect(legacy.hasSavedPassword)
        #expect(legacy.passwordEndpointKey == nil)
        #expect(!legacy.canUseSavedPassword(for: PersistenceFixtures.endpoint("a.local")))

        let stray = try PersistenceFixtures.decode(ConnectionProfile.self, json:
            #"{"id":"\#(id5.uuidString)","host":"a.local","port":5920,"hasSavedPassword":false,"passwordEndpointKey":"a.local:5920"}"#)
        #expect(stray.passwordEndpointKey == nil)
    }

    // MARK: Preferences

    @Test func defaultPreferencesAreThePhoneDefaults() {
        let preferences = ViewerPreferences()
        #expect(preferences.resolution == .hd)
        #expect(preferences.color == .full)
        #expect(preferences.quality == .automatic)
        #expect(preferences.inputMode == .trackpad)
        #expect(preferences.audioQuality == .stereo96)
        #expect(preferences.bandwidthKbps == 0)
        #expect(preferences.smoothGradients == false)
        #expect(ConnectionProfile(host: "h").preferences == .standard)
        #expect(ConnectionProfile(host: "h").port == 5920)
    }

    @Test func bandwidthStaysWireValid() {
        #expect(ViewerPreferences(bandwidthKbps: 50).bandwidthKbps == 100)
        #expect(ViewerPreferences(bandwidthKbps: 250_000).bandwidthKbps == 100_000)
        #expect(ViewerPreferences(bandwidthKbps: -3).bandwidthKbps == 0)
        var preferences = ViewerPreferences()
        preferences.bandwidthKbps = 4000
        #expect(preferences.bandwidthKbps == 4000)
        preferences.bandwidthKbps = 1
        #expect(preferences.bandwidthKbps == 100)
        preferences.bandwidthKbps = 0
        #expect(preferences.bandwidthKbps == 0)
    }

    @Test func panIsNeverSavedAsTheStartingMode() throws {
        #expect(ViewerPreferences(inputMode: .pan).inputMode == .trackpad)
        #expect(ViewerPreferences(inputMode: .direct).inputMode == .direct)
        var preferences = ViewerPreferences(inputMode: .direct)
        preferences.inputMode = .pan
        #expect(preferences.inputMode == .trackpad)
        #expect(ViewerPreferences.startingInputMode(.pan) == .trackpad)
        #expect(ViewerPreferences.startingInputMode(.direct) == .direct)

        var profile = PersistenceFixtures.profile(1)
        profile.preferences.inputMode = .pan
        #expect(try PersistenceFixtures.roundTrip(profile).preferences.inputMode == .trackpad)
        #expect(try PersistenceFixtures.decode(ViewerPreferences.self, json: #"{"inputMode":"pan"}"#).inputMode == .trackpad)
        #expect(try PersistenceFixtures.decode(ViewerPreferences.self, json: #"{"inputMode":"direct"}"#).inputMode == .direct)
    }

    // MARK: Coding

    @Test func profileRoundTripsThroughJSON() throws {
        var profile = PersistenceFixtures.profile(3, name: "Color Suite", host: "fe80::1", port: 5921,
                                                  group: PersistenceFixtures.id(90), hasSavedPassword: true)
        profile.lastConnectedAt = PersistenceFixtures.date(sinceReference: 810_771_330.123_456_7)
        profile.preferences = ViewerPreferences(resolution: .qhd, color: .gray16, quality: .video, inputMode: .direct,
                                                audioQuality: .stereo320, bandwidthKbps: 8000, smoothGradients: true)
        #expect(try PersistenceFixtures.roundTrip(profile) == profile)
    }

    @Test func savedProfileHasNoDisplaySelectionOrSecret() throws {
        let object = try #require(try PersistenceFixtures.encodedObject(PersistenceFixtures.profile(1, hasSavedPassword: true)))
        #expect(Set(object.keys) == ["id", "name", "host", "port", "sortIndex", "createdAt", "hasSavedPassword",
                                     "passwordEndpointKey", "preferences"])
        // The binding is the computer's address, not a secret.
        #expect(object["passwordEndpointKey"] as? String == "192.168.1.1:5920")
        let preferences = try #require(object["preferences"] as? [String: Any])
        #expect(Set(preferences.keys) == ["resolution", "color", "quality", "inputMode", "audioQuality", "bandwidthKbps", "smoothGradients"])

        let unsaved = try #require(try PersistenceFixtures.encodedObject(PersistenceFixtures.profile(1)))
        #expect(unsaved["passwordEndpointKey"] == nil)
    }

    @Test func unknownOrMissingPreferenceValuesFallBackToDefaults() throws {
        let json = #"{"resolution":"native","color":"rgb565","inputMode":"stylus","audioQuality":96000,"bandwidthKbps":42}"#
        let preferences = try PersistenceFixtures.decode(ViewerPreferences.self, json: json)
        #expect(preferences.resolution == .hd)
        #expect(preferences.color == .full)
        #expect(preferences.quality == .automatic)
        #expect(preferences.inputMode == .trackpad)
        #expect(preferences.audioQuality == .stereo96)
        #expect(preferences.bandwidthKbps == 100)
        #expect(preferences.smoothGradients == false)
    }

    @Test func minimalProfileDecodesWithDefaults() throws {
        let json = #"{"id":"\#(id5.uuidString)","host":"studio.local","port":5920}"#
        let profile = try PersistenceFixtures.decode(ConnectionProfile.self, json: json)
        #expect(profile.id == id5)
        #expect(profile.name == "")
        #expect(profile.groupID == nil)
        #expect(profile.hasSavedPassword == false)
        #expect(profile.passwordEndpointKey == nil)
        #expect(profile.preferences == .standard)
        #expect(profile.lastConnectedAt == nil)
    }

    @Test func malformedOptionalValuesFallBackToDefaults() throws {
        let json = #"""
        {"id":"\#(id5.uuidString)","host":"studio.local","port":5920,"name":5,"groupID":"not-a-uuid","sortIndex":"x",
         "createdAt":"x","lastConnectedAt":[],"hasSavedPassword":"yes","passwordEndpointKey":7,"preferences":5}
        """#
        let profile = try PersistenceFixtures.decode(ConnectionProfile.self, json: json)
        #expect(profile.name == "")
        #expect(profile.groupID == nil)
        #expect(profile.sortIndex == 0)
        #expect(profile.createdAt == PersistenceFixtures.date(sinceReference: -978_307_200))
        #expect(profile.lastConnectedAt == nil)
        #expect(!profile.hasSavedPassword)
        #expect(profile.passwordEndpointKey == nil)
        #expect(profile.preferences == .standard)

        let group = try PersistenceFixtures.decode(ProfileGroup.self, json: #"{"id":"\#(id5.uuidString)","name":[],"sortIndex":"x","isExpanded":1.5}"#)
        #expect(group.name == "New Group")
        #expect(group.sortIndex == 0)
        #expect(group.isExpanded)
    }

    @Test(arguments: [#"{"host":"h","port":5920}"#, #"{"id":"x","host":"h","port":5920}"#,
                      #"{"id":"00000000-0000-0000-0000-000000000005","port":5920}"#,
                      #"{"id":"00000000-0000-0000-0000-000000000005","host":"h","port":"5920"}"#])
    func identityAndAddressAreRequired(_ json: String) {
        #expect(throws: (any Error).self) { try PersistenceFixtures.decode(ConnectionProfile.self, json: json) }
    }

    @Test func groupNamesAreCleaned() {
        #expect(ProfileGroup.cleanedName("  Studio  ") == "Studio")
        #expect(ProfileGroup.cleanedName(" \n ") == nil)
        #expect(ProfileGroup.cleanedName(String(repeating: "x", count: 150))?.count == 100)
    }
}
