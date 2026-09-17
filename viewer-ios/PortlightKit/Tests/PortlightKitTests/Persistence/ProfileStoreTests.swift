import Testing
@testable import PortlightKit

@Suite("Persistence: profile store")
struct PersistenceProfileStoreTests {
    /// File name the corrupt library was moved to, if the outcome was a recovery.
    private func quarantined(_ outcome: ProfileStore.LoadOutcome) -> String? {
        if case .recovered(let file) = outcome { return file.lastPathComponent }
        return nil
    }

    private func isUnavailable(_ outcome: ProfileStore.LoadOutcome) -> Bool {
        if case .unavailable = outcome { return true }
        return false
    }

    /// Groups, grouped and ungrouped profiles, non-default preferences, a bound password and fractional dates.
    private func richLibrary() -> ProfileLibrary {
        var library = ProfileLibrary()
        let studio = library.createGroup(named: "Studio", id: PersistenceFixtures.id(100))
        library.setGroupExpanded(studio.id, false)
        var first = PersistenceFixtures.profile(1, name: "Edit Bay", host: "studio.local", hasSavedPassword: true)
        first.lastConnectedAt = PersistenceFixtures.date(sinceReference: 810_771_330.987_654_3)
        first.preferences = ViewerPreferences(resolution: .fhd, color: .color256, quality: .text, inputMode: .direct,
                                              audioQuality: .mono48, bandwidthKbps: 2000, smoothGradients: true)
        library.add(first)
        library.add(PersistenceFixtures.profile(2, host: "fe80::1", port: 5921, group: studio.id))
        library.add(PersistenceFixtures.profile(3, name: "Color", group: studio.id))
        return library
    }

    private func profileJSON(_ n: Int, _ extra: String = "") -> String {
        #"{"id":"\#(PersistenceFixtures.id(n).uuidString)","host":"h\#(n).local","port":5920\#(extra)}"#
    }

    @Test func missingFileLoadsAnEmptyLibraryWithoutCreatingOne() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let result = ProfileStore(directory: directory.url).load()
        #expect(result.outcome == .loaded)
        #expect(result.outcome.message == nil)
        #expect(result.library.isEmpty)
        #expect(directory.fileNames.isEmpty)
    }

    @Test func saveThenLoadRoundTripsTheLibrary() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url)
        _ = store.load()
        let library = richLibrary()
        try store.save(library)

        let reloaded = ProfileStore(directory: directory.url).load()
        #expect(reloaded.outcome == .loaded)
        #expect(reloaded.library == library)
        #expect(reloaded.library.group(id: PersistenceFixtures.id(100))?.isExpanded == false)
        #expect(reloaded.library.profile(id: PersistenceFixtures.id(1))?.passwordEndpointKey == "studio.local:5920")
        #expect(store.fileURL.lastPathComponent == "Connections.json")
    }

    @Test func fileIsVersionedJSONWithoutSecrets() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url)
        _ = store.load()
        try store.save(richLibrary())
        let object = try #require(PersistenceFixtures.jsonObject(try directory.contents(of: "Connections.json")))
        #expect(object["schemaVersion"] as? Int == 1)
        #expect((object["profiles"] as? [Any])?.count == 3)
        let text = try #require(try directory.text(of: "Connections.json"))
        #expect(!text.contains("\"password\""))
        #expect(!text.contains("displays"))
    }

    @Test func atomicSavesLeaveOnlyTheFile() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url)
        _ = store.load()
        var library = ProfileLibrary()
        for n in 1...3 {
            library.add(PersistenceFixtures.profile(n))
            try store.save(library)
        }
        #expect(directory.fileNames == ["Connections.json"])
        #expect(ProfileStore(directory: directory.url).load().library.profiles.count == 3)
    }

    @Test func saveCreatesTheDirectory() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let nested = directory.subdirectory("Application Support/Portlight")
        let store = ProfileStore(directory: nested)
        _ = store.load()
        try store.save(richLibrary())
        #expect(ProfileStore(directory: nested).load().library == richLibrary())
    }

    // MARK: Damaged files

    @Test func corruptFileIsSetAsideWithATimestampAndKept() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url, now: { PersistenceFixtures.now })
        let garbage = #"{"schemaVersion": 1, "profiles": ["#
        try directory.write(garbage, to: "Connections.json")

        let result = store.load()
        let aside = try #require(quarantined(result.outcome))
        #expect(aside == "Connections.corrupt-\(PersistenceFixtures.nowStamp).json")
        #expect(try directory.contents(of: aside) == PersistenceFixtures.bytes(garbage))
        #expect(result.library.isEmpty)
        #expect(result.outcome.message?.contains(aside) == true)
        #expect(directory.fileNames == ["Connections.corrupt-20260910T221530Z.json"])

        var library = ProfileLibrary()
        library.add(PersistenceFixtures.profile(1))
        try store.save(library)
        #expect(directory.fileNames == ["Connections.corrupt-20260910T221530Z.json", "Connections.json"])
        #expect(ProfileStore(directory: directory.url).load().library == library)
        #expect(try directory.contents(of: aside) == PersistenceFixtures.bytes(garbage))
    }

    @Test func repeatedRecoveryNeverOverwritesAnEarlierCopy() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url, now: { PersistenceFixtures.now })
        try directory.write("first", to: "Connections.json")
        let first = try #require(quarantined(store.load().outcome))
        try directory.write("second", to: "Connections.json")
        let second = try #require(quarantined(store.load().outcome))
        #expect(first == "Connections.corrupt-20260910T221530Z.json")
        #expect(second == "Connections.corrupt-20260910T221530Z-2.json")
        #expect(try directory.text(of: first) == "first")
        #expect(try directory.text(of: second) == "second")
    }

    @Test(arguments: ["", "[]", #"{"schemaVersion": "1"}"#, #"{"schemaVersion": 0}"#, #"{"profiles": []}"#,
                      #"{"schemaVersion": 1, "profiles": 5}"#, "ÿþ"])
    func undecodableContentIsRecovered(_ content: String) throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url, now: { PersistenceFixtures.now })
        try directory.write(content, to: "Connections.json")
        let result = store.load()
        #expect(quarantined(result.outcome) != nil)
        #expect(result.library.isEmpty)
        #expect(try directory.text(of: "Connections.corrupt-20260910T221530Z.json") == content)
    }

    @Test func oneDamagedItemLeavesTheRestLoaded() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url, now: { PersistenceFixtures.now })
        let original = """
        {"schemaVersion":1,
         "groups":[{"id":"\(PersistenceFixtures.id(100).uuidString)","name":"Studio"},{"name":"no id"}],
         "profiles":[\(profileJSON(1)),
                     {"id":"\(PersistenceFixtures.id(2).uuidString)","host":"bad.local","port":"5920"},
                     \(profileJSON(3, #","groupID":"\#(PersistenceFixtures.id(100).uuidString)""#)),
                     42]}
        """
        try directory.write(original, to: "Connections.json")

        let result = store.load()
        let copy = "Connections.corrupt-20260910T221530Z.json"
        guard case .partiallyRecovered(let dropped, let file) = result.outcome else {
            Issue.record("expected a partial recovery, got \(result.outcome)")
            return
        }
        #expect(dropped == 3)
        #expect(file.lastPathComponent == copy)
        #expect(result.outcome.message == "3 saved items couldn't be read and were left out. The original list was kept as \(copy).")
        #expect(result.library.profiles.map(\.id) == [PersistenceFixtures.id(1), PersistenceFixtures.id(3)])
        #expect(result.library.groups.map(\.name) == ["Studio"])
        #expect(try directory.text(of: copy) == original)

        // The list without the damaged items already replaced the original, so the next launch is clean.
        let relaunched = ProfileStore(directory: directory.url, now: { PersistenceFixtures.now }).load()
        #expect(relaunched.outcome == .loaded)
        #expect(relaunched.library == result.library)
        #expect(directory.fileNames == [copy, "Connections.json"])
        try store.save(result.library)
    }

    @Test func partialRecoveryMessageForOneItem() {
        let outcome = ProfileStore.LoadOutcome.partiallyRecovered(dropped: 1, quarantinedCopy: PersistenceFixtures.asideURL)
        #expect(outcome.message == "One saved item couldn't be read and was left out. The original list was kept as Connections.corrupt-20260910T221530Z.json.")
    }

    @Test func partialRecoveryWithoutACopyProtectsTheOriginal() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let original = #"{"schemaVersion":1,"profiles":[\#(profileJSON(1)),{"host":"no id"}]}"#
        try directory.write(original, to: "Connections.json")
        directory.setWritable(false)
        let store = ProfileStore(directory: directory.url, now: { PersistenceFixtures.now })
        let result = store.load()
        #expect(isUnavailable(result.outcome))
        #expect(result.library.isEmpty)
        #expect(throws: PersistenceError.existingFileNotLoaded("Connections.json")) { try store.save(ProfileLibrary()) }
        directory.setWritable(true)
        #expect(try directory.text(of: "Connections.json") == original)
        #expect(directory.fileNames == ["Connections.json"])
    }

    @Test func malformedOptionalValuesAreRepairedNotDropped() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let json = """
        {"schemaVersion":1,"profiles":[\(profileJSON(1, #","name":5,"preferences":5,"sortIndex":"x","createdAt":"x","hasSavedPassword":"yes""#))],
         "groups":[{"id":"\(PersistenceFixtures.id(100).uuidString)","name":7,"isExpanded":"no"}]}
        """
        try directory.write(json, to: "Connections.json")
        let result = ProfileStore(directory: directory.url).load()
        #expect(result.outcome == .loaded)
        let profile = try #require(result.library.profiles.first)
        #expect(profile.name == "")
        #expect(profile.preferences == .standard)
        #expect(!profile.hasSavedPassword)
        #expect(result.library.groups.first?.name == "New Group")
        #expect(result.library.groups.first?.isExpanded == true)
    }

    @Test func profileWithAnImpossibleAddressIsKeptForCorrection() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        try directory.write(#"{"schemaVersion":1,"profiles":[{"id":"\#(PersistenceFixtures.id(1).uuidString)","host":"h.local","port":0}]}"#,
                            to: "Connections.json")
        let result = ProfileStore(directory: directory.url).load()
        #expect(result.outcome == .loaded)
        let profile = try #require(result.library.profiles.first)
        // The row can't connect (no endpoint); opening it shows the port error so the user can fix it.
        #expect(profile.endpoint == nil)
        #expect(ConnectionDraft(editing: profile).validate(for: .save).message(for: .port) == ConnectionDraft.Message.portInvalid)
    }

    // MARK: Files that must not be replaced

    @Test func fileFromANewerVersionIsNeverReplacedOrMoved() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let future = #"{"schemaVersion":2,"profiles":[{"id":"\#(PersistenceFixtures.id(1).uuidString)","host":"h","port":5920}],"groups":[]}"#
        try directory.write(future, to: "Connections.json")
        let store = ProfileStore(directory: directory.url, now: { PersistenceFixtures.now })

        let result = store.load()
        #expect(result.outcome == .newerVersion(schemaVersion: 2))
        #expect(result.outcome.message == "A newer version of Portlight saved these connections. Update Portlight to open and change them.")
        #expect(result.library.isEmpty)
        #expect(throws: PersistenceError.savedByNewerVersion("Connections.json")) { try store.save(result.library) }
        #expect(try directory.text(of: "Connections.json") == future)
        #expect(directory.fileNames == ["Connections.json"])
        #expect(PersistenceError.savedByNewerVersion("Connections.json").errorDescription
            == "A newer version of Portlight saved this data, so this version didn't change it. Update Portlight, then try again.")

        // Only once that file is gone may a new list be written.
        try directory.remove("Connections.json")
        try store.save(result.library)
        #expect(directory.fileNames == ["Connections.json"])
    }

    @Test func unreadableFileIsNeitherQuarantinedNorReplaced() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url, now: { PersistenceFixtures.now })
        // A directory where the file should be reads like protected data before the first unlock: present, unreadable.
        try directory.makeDirectory(named: "Connections.json")

        let result = store.load()
        #expect(isUnavailable(result.outcome))
        #expect(result.outcome.message != nil)
        #expect(result.library.isEmpty)
        #expect(throws: PersistenceError.existingFileNotLoaded("Connections.json")) {
            try store.save(richLibrary())
        }
        #expect(directory.fileNames == ["Connections.json"])
        #expect(directory.isDirectory("Connections.json"))

        try directory.remove("Connections.json")
        #expect(store.load().outcome == .loaded)
        try store.save(richLibrary())
        #expect(ProfileStore(directory: directory.url).load().library == richLibrary())
    }

    @Test func saveBeforeLoadNeverClobbersAnExistingFile() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let first = ProfileStore(directory: directory.url)
        _ = first.load()
        try first.save(richLibrary())

        let second = ProfileStore(directory: directory.url)
        #expect(throws: PersistenceError.existingFileNotLoaded("Connections.json")) {
            try second.save(ProfileLibrary())
        }
        #expect(second.load().library == richLibrary())
        try second.save(ProfileLibrary())
        #expect(ProfileStore(directory: directory.url).load().library.isEmpty)
    }

    @Test func concurrentSavesLeaveOneReadableFile() throws {
        let directory = try PersistenceFixtures.TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ProfileStore(directory: directory.url)
        _ = store.load()
        PersistenceFixtures.concurrently(16) { n in
            var library = ProfileLibrary()
            for k in 0...n { library.add(PersistenceFixtures.profile(k + 1)) }
            try? store.save(library)
        }
        let result = ProfileStore(directory: directory.url).load()
        #expect(result.outcome == .loaded)
        #expect((1...16).contains(result.library.profiles.count))
        #expect(directory.fileNames == ["Connections.json"])
    }

    @Test func quarantineTimestampIsUTC() {
        #expect(PersistenceFiles.timestamp(PersistenceFixtures.now) == "20260910T221530Z")
        #expect(PersistenceFiles.timestamp(PersistenceFixtures.date(sinceReference: -978_307_200)) == "19700101T000000Z")
    }
}
