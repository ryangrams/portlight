import Foundation

/// The saved connections and their optional groups.
///
/// A value type: the app owns one copy, changes it only through these operations, and hands it to
/// `ProfileStore` to persist. Position is owned here — `add` appends, `update` keeps a profile where it is,
/// and only the move operations reorder — so a stale `sortIndex` from an edit form can't reshuffle the list.
///
/// Invariants after every operation and after decoding: ids are unique, every `groupID` names an existing
/// group, and `sortIndex` runs 0..<n among the groups, among the ungrouped profiles, and within each group.
public struct ProfileLibrary: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Every profile, ungrouped first and then by group order. Use `profiles(in:)` for one list's display order.
    public private(set) var profiles: [ConnectionProfile]
    /// Every group, in display order.
    public private(set) var groups: [ProfileGroup]

    public init() {
        self.init(profiles: [], groups: [])
    }

    /// A library of these items, repaired into the invariants above.
    init(profiles: [ConnectionProfile], groups: [ProfileGroup]) {
        schemaVersion = Self.currentSchemaVersion
        self.profiles = profiles
        self.groups = groups
        normalize()
    }

    // MARK: Queries

    public var isEmpty: Bool { profiles.isEmpty && groups.isEmpty }

    public func profile(id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

    public func group(id: UUID) -> ProfileGroup? { groups.first { $0.id == id } }

    /// Profiles in one group (nil = ungrouped), in display order.
    public func profiles(in groupID: UUID?) -> [ConnectionProfile] {
        profiles.filter { $0.groupID == groupID }.sorted(by: Self.displayOrder)
    }

    // MARK: Profiles

    /// Appends the profile at the end of its group; an unknown group means ungrouped. Adding an id that
    /// already exists updates it instead. Returns the stored profile.
    @discardableResult
    public mutating func add(_ profile: ConnectionProfile) -> ConnectionProfile {
        if profiles.contains(where: { $0.id == profile.id }) {
            update(profile)
        } else {
            var added = profile
            if let groupID = added.groupID, group(id: groupID) == nil { added.groupID = nil }
            added.sortIndex = Int.max
            profiles.append(added)
            normalize()
        }
        return self.profile(id: profile.id) ?? profile
    }

    /// Replaces the stored profile with the same id. It keeps its position unless its group changed, in which
    /// case it moves to the end of the new group. Returns false when no such profile exists.
    ///
    /// This replaces every field. To apply an edit form, merge it into the current copy first
    /// (`ConnectionDraft.makeProfile(mergingInto:)`, or `ConnectionCredentials.saveConnection`).
    @discardableResult
    public mutating func update(_ profile: ConnectionProfile) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        var updated = profile
        if let groupID = updated.groupID, group(id: groupID) == nil { updated.groupID = nil }
        updated.sortIndex = updated.groupID == profiles[index].groupID ? profiles[index].sortIndex : Int.max
        profiles[index] = updated
        normalize()
        return true
    }

    /// Removes a profile and returns the Keychain account whose password the caller must delete
    /// (see `ConnectionCredentials.deleteProfile`), or nil when no such profile exists.
    @discardableResult
    public mutating func delete(profileID: UUID) -> String? {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return nil }
        let removed = profiles.remove(at: index)
        normalize()
        return removed.secretAccount
    }

    /// Moves a profile to `index` within `groupID`'s list (nil = ungrouped), counted after removing the
    /// profile itself and clamped to the list. Returns false for an unknown profile or group.
    @discardableResult
    public mutating func moveProfile(_ id: UUID, toGroup groupID: UUID?, at index: Int) -> Bool {
        guard var moving = profile(id: id) else { return false }
        if let groupID, group(id: groupID) == nil { return false }
        var destination = profiles(in: groupID).filter { $0.id != id }
        moving.groupID = groupID
        destination.insert(moving, at: min(max(index, 0), destination.count))
        applyOrder(destination, group: groupID)
        return true
    }

    /// List `onMove` semantics within one group: `toOffset` is an offset in the list before the move.
    public mutating func moveProfiles(inGroup groupID: UUID?, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        applyOrder(Self.reordered(profiles(in: groupID), moving: offsets, to: destination), group: groupID)
    }

    /// Records a successful connection time (for "recent" hints). Returns false for an unknown profile.
    @discardableResult
    public mutating func markConnected(_ id: UUID, at date: Date) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].lastConnectedAt = date
        return true
    }

    /// Records that a password is now saved for `endpoint`'s computer, or with nil that none is — for example
    /// after `ConnectionCredentials.resolvePassword` reported `.missingFromKeychain`. Changes only the hint;
    /// persist the library afterwards. Returns false for an unknown profile.
    @discardableResult
    public mutating func recordSavedPassword(_ id: UUID, for endpoint: HostEndpoint?) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].hasSavedPassword = endpoint != nil
        profiles[index].passwordEndpointKey = endpoint?.canonicalKey
        return true
    }

    // MARK: Groups

    /// Appends a group; a blank name becomes "New Group". Returns the created group.
    @discardableResult
    public mutating func createGroup(named name: String, id: UUID = UUID()) -> ProfileGroup {
        let created = ProfileGroup(id: id, name: ProfileGroup.cleanedName(name) ?? ProfileGroup.defaultName, sortIndex: Int.max)
        groups.append(created)
        normalize()
        return group(id: created.id) ?? created
    }

    /// Returns false for an unknown group or a blank name (the old name is kept).
    @discardableResult
    public mutating func renameGroup(_ id: UUID, to name: String) -> Bool {
        guard let cleaned = ProfileGroup.cleanedName(name), let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[index].name = cleaned
        return true
    }

    @discardableResult
    public mutating func setGroupExpanded(_ id: UUID, _ isExpanded: Bool) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[index].isExpanded = isExpanded
        return true
    }

    /// Removes the group only. Its profiles are never deleted: they become ungrouped, after the existing
    /// ungrouped profiles and in their previous order. Returns false for an unknown group.
    @discardableResult
    public mutating func deleteGroup(_ id: UUID) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        let members = profiles(in: id)
        let ungroupedCount = profiles(in: nil).count
        groups.remove(at: index)
        for (offset, member) in members.enumerated() {
            guard let position = profiles.firstIndex(where: { $0.id == member.id }) else { continue }
            profiles[position].groupID = nil
            profiles[position].sortIndex = ungroupedCount + offset
        }
        normalize()
        return true
    }

    /// Puts groups in the given order. Unknown ids are ignored; groups not listed keep their relative order after.
    public mutating func reorderGroups(_ orderedIDs: [UUID]) {
        var seen = Set<UUID>()
        var ordered = orderedIDs.compactMap { id in seen.insert(id).inserted ? group(id: id) : nil }
        ordered += groups.filter { !seen.contains($0.id) }
        for index in ordered.indices { ordered[index].sortIndex = index }
        groups = ordered
        normalize()
    }

    /// List `onMove` semantics for the group rows.
    public mutating func moveGroups(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        reorderGroups(Self.reordered(groups, moving: offsets, to: destination).map(\.id))
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey { case schemaVersion, profiles, groups }

    /// Rejects an unknown schema and repairs a hand-edited or partially written file into the invariants above.
    /// A profile or group that can't be decoded is dropped; `ProfileStore` reports how many.
    public init(from decoder: Decoder) throws {
        self = try ProfileLibraryFile(from: decoder).library
    }

    // MARK: Ordering

    private static func displayOrder(_ a: ConnectionProfile, _ b: ConnectionProfile) -> Bool {
        (a.sortIndex, a.createdAt, a.id.uuidString) < (b.sortIndex, b.createdAt, b.id.uuidString)
    }

    /// Assigns positions 0..<n in `groupID` to `ordered`, then renormalizes (closing any gap it left elsewhere).
    private mutating func applyOrder(_ ordered: [ConnectionProfile], group groupID: UUID?) {
        for (position, member) in ordered.enumerated() {
            guard let index = profiles.firstIndex(where: { $0.id == member.id }) else { continue }
            profiles[index].groupID = groupID
            profiles[index].sortIndex = position
        }
        normalize()
    }

    /// `onMove` semantics without SwiftUI: `destination` is an offset in `items` before removal.
    private static func reordered<Item>(_ items: [Item], moving offsets: IndexSet, to destination: Int) -> [Item] {
        let moving = offsets.filter { items.indices.contains($0) }
        guard !moving.isEmpty else { return items }
        let target = min(max(destination, 0), items.count)
        let insertion = target - moving.filter { $0 < target }.count
        var remaining = items.enumerated().filter { !moving.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moving.map { items[$0] }, at: min(max(insertion, 0), remaining.count))
        return remaining
    }

    private mutating func normalize() {
        var groupIDs = Set<UUID>()
        var cleanGroups = groups.filter { groupIDs.insert($0.id).inserted }
        cleanGroups.sort { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        for index in cleanGroups.indices { cleanGroups[index].sortIndex = index }
        groups = cleanGroups

        var profileIDs = Set<UUID>()
        var buckets: [UUID?: [ConnectionProfile]] = [:]
        for var profile in profiles where profileIDs.insert(profile.id).inserted {
            if let groupID = profile.groupID, !groupIDs.contains(groupID) { profile.groupID = nil }
            buckets[profile.groupID, default: []].append(profile)
        }
        var ordered: [ConnectionProfile] = []
        let bucketOrder: [UUID?] = [nil] + groups.map { Optional($0.id) }
        for bucket in bucketOrder {
            var members = (buckets[bucket] ?? []).sorted(by: Self.displayOrder)
            for index in members.indices { members[index].sortIndex = index }
            ordered += members
        }
        profiles = ordered
    }
}

/// `Connections.json` as read from disk: the library plus how many damaged items were left out of it.
/// An unknown schema is rejected; within a known one each profile and group decodes on its own, so one bad item
/// can't make every other saved connection unreadable.
struct ProfileLibraryFile: Decodable {
    let library: ProfileLibrary
    /// Profiles and groups that couldn't be decoded and were dropped.
    let droppedElements: Int

    private enum CodingKeys: String, CodingKey { case schemaVersion, profiles, groups }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...ProfileLibrary.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Unsupported saved-connections schema \(version)")
        }
        let profiles = try container.decodeIfPresent([LossyDecodable<ConnectionProfile>].self, forKey: .profiles) ?? []
        let groups = try container.decodeIfPresent([LossyDecodable<ProfileGroup>].self, forKey: .groups) ?? []
        droppedElements = profiles.filter { $0.value == nil }.count + groups.filter { $0.value == nil }.count
        library = ProfileLibrary(profiles: profiles.compactMap(\.value), groups: groups.compactMap(\.value))
    }
}
