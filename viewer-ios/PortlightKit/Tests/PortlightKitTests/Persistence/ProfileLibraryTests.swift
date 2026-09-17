import Testing
@testable import PortlightKit

// `#expect` captures its operands immutably, so every mutating library call runs first and its result is checked after.

@Suite("Persistence: profile library")
struct PersistenceProfileLibraryTests {
    private let groupA = PersistenceFixtures.id(100)
    private let groupB = PersistenceFixtures.id(200)

    private func id(_ n: Int) -> ConnectionProfile.ID { PersistenceFixtures.id(n) }

    /// Ungrouped 1, 2, 3; group A ("Studio") holds 4, 5; group B ("Edit Suites") is empty.
    private func sampleLibrary() -> ProfileLibrary {
        var library = ProfileLibrary()
        library.createGroup(named: "Studio", id: groupA)
        library.createGroup(named: "Edit Suites", id: groupB)
        for n in 1...3 { library.add(PersistenceFixtures.profile(n)) }
        for n in 4...5 { library.add(PersistenceFixtures.profile(n, group: groupA)) }
        return library
    }

    private func order(_ library: ProfileLibrary, _ group: ProfileGroup.ID?) -> [ConnectionProfile.ID] {
        library.profiles(in: group).map(\.id)
    }

    private func positions(_ library: ProfileLibrary, _ group: ProfileGroup.ID?) -> [Int] {
        library.profiles(in: group).map(\.sortIndex)
    }

    // MARK: Profiles

    @Test func addAppendsAtTheEndOfItsGroup() {
        let library = sampleLibrary()
        #expect(order(library, nil) == [id(1), id(2), id(3)])
        #expect(positions(library, nil) == [0, 1, 2])
        #expect(order(library, groupA) == [id(4), id(5)])
        #expect(order(library, groupB).isEmpty)
        #expect(library.groups.map(\.name) == ["Studio", "Edit Suites"])
        #expect(library.groups.map(\.sortIndex) == [0, 1])
        #expect(library.schemaVersion == 1)
    }

    @Test func addIgnoresIncomingPositionAndUnknownGroup() {
        var library = sampleLibrary()
        var stray = PersistenceFixtures.profile(6, group: PersistenceFixtures.id(999))
        stray.sortIndex = -40
        let stored = library.add(stray)
        #expect(stored.groupID == nil)
        #expect(stored.sortIndex == 3)
        #expect(order(library, nil) == [id(1), id(2), id(3), id(6)])
    }

    @Test func addingAnExistingIDUpdatesIt() {
        var library = sampleLibrary()
        library.add(PersistenceFixtures.profile(2, name: "Renamed"))
        #expect(library.profiles.count == 5)
        #expect(library.profile(id: id(2))?.name == "Renamed")
        #expect(order(library, nil) == [id(1), id(2), id(3)])
    }

    @Test func updateKeepsPosition() throws {
        var library = sampleLibrary()
        var edited = try #require(library.profile(id: id(1)))
        edited.name = "Edit Bay"
        edited.sortIndex = 7
        let updated = library.update(edited)
        #expect(updated)
        #expect(order(library, nil) == [id(1), id(2), id(3)])
        #expect(library.profile(id: id(1))?.name == "Edit Bay")
        #expect(library.profile(id: id(1))?.sortIndex == 0)
    }

    @Test func updateIntoAnotherGroupAppendsThere() throws {
        var library = sampleLibrary()
        var edited = try #require(library.profile(id: id(1)))
        edited.groupID = groupA
        let updated = library.update(edited)
        #expect(updated)
        #expect(order(library, groupA) == [id(4), id(5), id(1)])
        #expect(positions(library, groupA) == [0, 1, 2])
        #expect(order(library, nil) == [id(2), id(3)])
        #expect(positions(library, nil) == [0, 1])
    }

    @Test func updateOfUnknownProfileChangesNothing() {
        var library = sampleLibrary()
        let before = library
        let updated = library.update(PersistenceFixtures.profile(42))
        #expect(!updated)
        #expect(library == before)
    }

    @Test func deleteReturnsTheSecretAccountAndRenumbers() {
        var library = sampleLibrary()
        let account = library.delete(profileID: id(2))
        #expect(account == id(2).uuidString)
        #expect(order(library, nil) == [id(1), id(3)])
        #expect(positions(library, nil) == [0, 1])
        #expect(library.profile(id: id(2)) == nil)
        let again = library.delete(profileID: id(2))
        #expect(again == nil)
    }

    @Test func moveWithinAGroup() {
        var library = sampleLibrary()
        let toFront = library.moveProfile(id(3), toGroup: nil, at: 0)
        #expect(toFront)
        #expect(order(library, nil) == [id(3), id(1), id(2)])
        #expect(positions(library, nil) == [0, 1, 2])
        let pastEnd = library.moveProfile(id(3), toGroup: nil, at: 99)
        #expect(pastEnd)
        #expect(order(library, nil) == [id(1), id(2), id(3)])
        let toMiddle = library.moveProfile(id(1), toGroup: nil, at: 1)
        #expect(toMiddle)
        #expect(order(library, nil) == [id(2), id(1), id(3)])
        let negative = library.moveProfile(id(3), toGroup: nil, at: -5)
        #expect(negative)
        #expect(order(library, nil) == [id(3), id(2), id(1)])
    }

    @Test func moveIntoAndOutOfGroups() {
        var library = sampleLibrary()
        let intoA = library.moveProfile(id(2), toGroup: groupA, at: 1)
        #expect(intoA)
        #expect(order(library, groupA) == [id(4), id(2), id(5)])
        #expect(positions(library, groupA) == [0, 1, 2])
        #expect(order(library, nil) == [id(1), id(3)])
        #expect(positions(library, nil) == [0, 1])
        #expect(library.profile(id: id(2))?.groupID == groupA)

        let intoEmptyB = library.moveProfile(id(5), toGroup: groupB, at: 0)
        #expect(intoEmptyB)
        #expect(order(library, groupB) == [id(5)])
        #expect(order(library, groupA) == [id(4), id(2)])

        let outOfGroup = library.moveProfile(id(4), toGroup: nil, at: 0)
        #expect(outOfGroup)
        #expect(order(library, nil) == [id(4), id(1), id(3)])
        #expect(library.profile(id: id(4))?.groupID == nil)
    }

    @Test func moveToUnknownGroupOrProfileFails() {
        var library = sampleLibrary()
        let before = library
        let unknownGroup = library.moveProfile(id(1), toGroup: PersistenceFixtures.id(999), at: 0)
        let unknownProfile = library.moveProfile(id(42), toGroup: nil, at: 0)
        #expect(!unknownGroup)
        #expect(!unknownProfile)
        #expect(library == before)
    }

    @Test func listMoveOffsetsMatchOnMoveSemantics() {
        let cases: [(offsets: [Int], destination: Int, expected: [Int])] = [
            ([0], 3, [2, 3, 1, 4]),
            ([3], 0, [4, 1, 2, 3]),
            ([0, 2], 4, [2, 4, 1, 3]),
            ([1], 2, [1, 2, 3, 4]),
            ([1], 1, [1, 2, 3, 4]),
            ([9], 0, [1, 2, 3, 4]),
        ]
        for testCase in cases {
            var library = ProfileLibrary()
            for n in 1...4 { library.add(PersistenceFixtures.profile(n)) }
            library.moveProfiles(inGroup: nil, fromOffsets: PersistenceFixtures.offsets(testCase.offsets), toOffset: testCase.destination)
            #expect(order(library, nil) == testCase.expected.map { id($0) }, "move \(testCase.offsets) to \(testCase.destination)")
            #expect(positions(library, nil) == [0, 1, 2, 3])
        }
    }

    @Test func markConnectedRecordsTheDate() {
        var library = sampleLibrary()
        let marked = library.markConnected(id(4), at: PersistenceFixtures.now)
        let unknown = library.markConnected(id(42), at: PersistenceFixtures.now)
        #expect(marked)
        #expect(!unknown)
        #expect(library.profile(id: id(4))?.lastConnectedAt == PersistenceFixtures.now)
    }

    @Test func recordSavedPasswordBindsAndClearsTheHint() {
        var library = sampleLibrary()
        let bound = library.recordSavedPassword(id(1), for: PersistenceFixtures.endpoint("Studio.Local", 5921))
        #expect(bound)
        #expect(library.profile(id: id(1))?.hasSavedPassword == true)
        #expect(library.profile(id: id(1))?.passwordEndpointKey == "studio.local:5921")
        let cleared = library.recordSavedPassword(id(1), for: nil)
        #expect(cleared)
        #expect(library.profile(id: id(1))?.hasSavedPassword == false)
        #expect(library.profile(id: id(1))?.passwordEndpointKey == nil)
        let unknown = library.recordSavedPassword(id(42), for: nil)
        #expect(!unknown)
        #expect(order(library, nil) == [id(1), id(2), id(3)])
    }

    // MARK: Groups

    @Test func createGroupCleansNamesAndAppends() {
        var library = ProfileLibrary()
        let trimmed = library.createGroup(named: "  Studio  ")
        let blank = library.createGroup(named: "   ")
        let long = library.createGroup(named: String(repeating: "g", count: 150))
        #expect(trimmed.name == "Studio")
        #expect(blank.name == "New Group")
        #expect(long.name.count == 100)
        #expect(long.sortIndex == 2)
        #expect(long.isExpanded)
        #expect(library.groups.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func renameGroupKeepsTheOldNameWhenBlank() {
        var library = sampleLibrary()
        let renamed = library.renameGroup(groupA, to: "  Edit Bays ")
        #expect(renamed)
        #expect(library.group(id: groupA)?.name == "Edit Bays")
        let blank = library.renameGroup(groupA, to: "  ")
        #expect(!blank)
        #expect(library.group(id: groupA)?.name == "Edit Bays")
        let unknown = library.renameGroup(PersistenceFixtures.id(999), to: "Other")
        #expect(!unknown)
    }

    @Test func groupDisclosureState() {
        var library = sampleLibrary()
        #expect(library.group(id: groupA)?.isExpanded == true)
        let collapsed = library.setGroupExpanded(groupA, false)
        let unknown = library.setGroupExpanded(PersistenceFixtures.id(999), false)
        #expect(collapsed)
        #expect(!unknown)
        #expect(library.group(id: groupA)?.isExpanded == false)
    }

    @Test func deleteGroupUngroupsItsProfilesAndNeverDeletesThem() {
        var library = sampleLibrary()
        let deleted = library.deleteGroup(groupA)
        #expect(deleted)
        #expect(library.profiles.count == 5)
        #expect(order(library, nil) == [id(1), id(2), id(3), id(4), id(5)])
        #expect(positions(library, nil) == [0, 1, 2, 3, 4])
        #expect(library.groups.map(\.id) == [groupB])
        #expect(library.groups.map(\.sortIndex) == [0])
        let again = library.deleteGroup(groupA)
        #expect(!again)
    }

    @Test func reorderGroupsByIDs() {
        var library = ProfileLibrary()
        let ids = (1...3).map { PersistenceFixtures.id(300 + $0) }
        for (n, groupID) in ids.enumerated() { library.createGroup(named: "G\(n + 1)", id: groupID) }
        library.reorderGroups([ids[2], PersistenceFixtures.id(999), ids[0], ids[2]])
        #expect(library.groups.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(library.groups.map(\.sortIndex) == [0, 1, 2])
        library.moveGroups(fromOffsets: PersistenceFixtures.offsets([0]), toOffset: 3)
        #expect(library.groups.map(\.id) == [ids[0], ids[1], ids[2]])
    }

    // MARK: Decoding

    @Test func decodingRepairsInvariants() throws {
        let (g1, g2) = (PersistenceFixtures.id(101), PersistenceFixtures.id(102))
        let json = """
        {"schemaVersion": 1,
         "groups": [{"id": "\(g1.uuidString)", "name": "A", "sortIndex": 7},
                    {"id": "\(g1.uuidString)", "name": "duplicate", "sortIndex": 0},
                    {"id": "\(g2.uuidString)", "name": "B", "sortIndex": 3}],
         "profiles": [{"id": "\(id(1).uuidString)", "host": "h1", "port": 5920, "groupID": "\(id(999).uuidString)", "sortIndex": 9},
                      {"id": "\(id(2).uuidString)", "host": "h2", "port": 5920, "sortIndex": 4},
                      {"id": "\(id(2).uuidString)", "host": "duplicate", "port": 5920, "sortIndex": 0},
                      {"id": "\(id(3).uuidString)", "host": "h3", "port": 5920, "groupID": "\(g2.uuidString)", "sortIndex": 5}]}
        """
        let library = try PersistenceFixtures.decode(ProfileLibrary.self, json: json)
        #expect(library.groups.map(\.id) == [g2, g1])
        #expect(library.groups.map(\.name) == ["B", "A"])
        #expect(library.groups.map(\.sortIndex) == [0, 1])
        #expect(order(library, nil) == [id(2), id(1)])
        #expect(positions(library, nil) == [0, 1])
        #expect(library.profile(id: id(2))?.host == "h2")
        #expect(library.profile(id: id(1))?.groupID == nil)
        #expect(order(library, g2) == [id(3)])
        #expect(library.profiles.count == 3)
    }

    @Test func decodingDropsOnlyDamagedItems() throws {
        let json = """
        {"schemaVersion": 1,
         "groups": [{"id": "\(groupA.uuidString)", "name": "A"}, "not a group", {"name": "no id"}],
         "profiles": [{"id": "\(id(1).uuidString)", "host": "h1", "port": 5920},
                      {"id": "\(id(2).uuidString)", "host": "h2", "port": "5920"},
                      {"id": "\(id(3).uuidString)", "port": 5920},
                      null,
                      {"id": "\(id(4).uuidString)", "host": "h4", "port": 5920, "groupID": "\(groupA.uuidString)"}]}
        """
        let file = try PersistenceFixtures.decode(ProfileLibraryFile.self, json: json)
        #expect(file.droppedElements == 5)
        #expect(file.library.profiles.map(\.id) == [id(1), id(4)])
        #expect(file.library.groups.map(\.id) == [groupA])
        #expect(try PersistenceFixtures.decode(ProfileLibrary.self, json: json) == file.library)
    }

    @Test func equalPositionsFallBackToCreationOrder() throws {
        let json = """
        {"schemaVersion": 1, "profiles": [
          {"id": "\(id(1).uuidString)", "host": "late", "port": 5920, "sortIndex": 0, "createdAt": 50},
          {"id": "\(id(2).uuidString)", "host": "early", "port": 5920, "sortIndex": 0, "createdAt": 10}]}
        """
        let library = try PersistenceFixtures.decode(ProfileLibrary.self, json: json)
        #expect(order(library, nil) == [id(2), id(1)])
        #expect(positions(library, nil) == [0, 1])
    }

    @Test func decodingRejectsAnUnknownSchema() {
        for json in [#"{"schemaVersion": 2, "profiles": [], "groups": []}"#, #"{"profiles": []}"#, #"[]"#,
                     #"{"schemaVersion": 1, "profiles": {}}"#] {
            #expect(throws: (any Error).self) {
                try PersistenceFixtures.decode(ProfileLibrary.self, json: json)
            }
        }
    }
}
