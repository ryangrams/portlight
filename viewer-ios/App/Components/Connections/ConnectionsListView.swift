import SwiftUI
import PortlightKit

/// Where the Connections navigation goes: a saved connection's detail or a new draft.
enum ConnectionRoute: Hashable {
    case edit(UUID)
    case new(groupID: UUID?)
}

/// The root list of saved connections (UI-SPEC §2).
///
/// Reordering, group moves and group disclosure edit `library` directly; the owner persists it on change.
/// Anything with side effects (connecting, deleting a Keychain item, pushing a draft) is a closure. Tapping a
/// row only pushes `ConnectionRoute.edit`; it never connects and never reads the Keychain.
struct ConnectionsListView: View {
    @Binding var library: ProfileLibrary
    private let onConnect: @MainActor (ConnectionProfile) -> Void
    private let onEdit: @MainActor (ConnectionProfile) -> Void
    private let onDelete: @MainActor (ConnectionProfile) -> Void
    private let onNewConnection: @MainActor (UUID?) -> Void

    @State private var isNamingGroup = false
    /// nil while naming a new group, otherwise the group being renamed.
    @State private var namingTarget: UUID?
    @State private var groupName = ""

    init(library: Binding<ProfileLibrary>,
         onConnect: @escaping @MainActor (ConnectionProfile) -> Void,
         onEdit: @escaping @MainActor (ConnectionProfile) -> Void,
         onDelete: @escaping @MainActor (ConnectionProfile) -> Void,
         onNewConnection: @escaping @MainActor (UUID?) -> Void) {
        _library = library
        self.onConnect = onConnect
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onNewConnection = onNewConnection
    }

    var body: some View {
        content
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton().disabled(library.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { addMenu }
            }
            .alert(namingTarget == nil ? "New Group" : "Rename Group", isPresented: $isNamingGroup) {
                TextField("Group Name", text: $groupName)
                Button(namingTarget == nil ? "Create" : "Rename") { commitGroupName() }
                Button("Cancel", role: .cancel) {}
            }
    }

    @ViewBuilder
    private var content: some View {
        if library.isEmpty {
            EmptyStateView("No Saved Connections", systemImage: "display.2",
                           message: "Add the Mac that runs Portlight Host to see and control its screens.") {
                Button {
                    onNewConnection(nil)
                } label: {
                    Text("New Connection").onAccentLabel()
                }
                .buttonStyle(.borderedProminent)
            }
            .safeAreaInset(edge: .bottom) { PublisherFooter().padding(.bottom, 12) }
        } else {
            List {
                ungroupedSection
                ForEach(library.groups) { group in
                    groupSection(group)
                }
                Section {
                } footer: {
                    PublisherFooter().padding(.top, 8)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private var ungroupedSection: some View {
        let ungrouped = library.profiles(in: nil)
        if !ungrouped.isEmpty {
            Section {
                ForEach(ungrouped) { profile in
                    row(profile)
                }
                .onMove { library.moveProfiles(inGroup: nil, fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    for index in offsets { onDelete(ungrouped[index]) }
                }
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: ProfileGroup) -> some View {
        let members = library.profiles(in: group.id)
        Section {
            if group.isExpanded {
                if members.isEmpty {
                    Text("No connections in this group")
                        .foregroundStyle(PortlightTheme.secondaryText)
                } else {
                    ForEach(members) { profile in
                        row(profile)
                    }
                    .onMove { library.moveProfiles(inGroup: group.id, fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        for index in offsets { onDelete(members[index]) }
                    }
                }
            }
        } header: {
            GroupHeader(group: group, count: members.count) {
                withAnimation { _ = library.setGroupExpanded(group.id, !group.isExpanded) }
            }
            .contextMenu {
                Button {
                    namingTarget = group.id
                    groupName = group.name
                    isNamingGroup = true
                } label: {
                    Label("Rename Group…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    _ = library.deleteGroup(group.id)
                } label: {
                    Label("Delete Group", systemImage: "folder.badge.minus")
                }
            }
        }
    }

    private func row(_ profile: ConnectionProfile) -> some View {
        NavigationLink(value: ConnectionRoute.edit(profile.id)) {
            ConnectionRow(profile: profile)
        }
        .accessibilityIdentifier("connections.row.\(profile.displayTitle)")
        .contextMenu { rowMenu(profile) }
    }

    @ViewBuilder
    private func rowMenu(_ profile: ConnectionProfile) -> some View {
        Button { onConnect(profile) } label: { Label("Connect", systemImage: "play.fill") }
        Button { onEdit(profile) } label: { Label("Edit", systemImage: "pencil") }
        Menu {
            Button { move(profile, to: nil) } label: { groupChoice("No Group", current: profile.groupID == nil) }
            ForEach(library.groups) { group in
                Button { move(profile, to: group.id) } label: { groupChoice(group.name, current: profile.groupID == group.id) }
            }
        } label: {
            Label("Move to Group", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) { onDelete(profile) } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder
    private func groupChoice(_ name: String, current: Bool) -> some View {
        if current {
            Label(name, systemImage: "checkmark")
        } else {
            Text(name)
        }
    }

    private var addMenu: some View {
        Menu {
            Button { onNewConnection(nil) } label: { Label("New Connection", systemImage: "desktopcomputer") }
            Button {
                namingTarget = nil
                groupName = ""
                isNamingGroup = true
            } label: {
                Label("New Group", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    private func move(_ profile: ConnectionProfile, to groupID: UUID?) {
        guard profile.groupID != groupID else { return }
        _ = library.moveProfile(profile.id, toGroup: groupID, at: Int.max)
    }

    private func commitGroupName() {
        if let id = namingTarget {
            _ = library.renameGroup(id, to: groupName)
        } else {
            library.createGroup(named: groupName)
        }
    }
}

/// A group's section header: one tap collapses or expands it.
private struct GroupHeader: View {
    let group: ProfileGroup
    let count: Int
    let toggle: @MainActor () -> Void

    var body: some View {
        Button {
            toggle()
        } label: {
            // Explicit colours: in a section header `.primary` and `.secondary` resolve against the header's own
            // gray, which drew the name at 3.3:1 and the count at 1.7:1.
            HStack(spacing: 8) {
                Text(group.name)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(verbatim: "\(count)")
                    .font(.subheadline)
                    .foregroundStyle(PortlightTheme.secondaryText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PortlightTheme.secondaryText)
                    .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.name)
        .accessibilityValue(group.isExpanded ? "Expanded, \(count) connections" : "Collapsed, \(count) connections")
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityHint(group.isExpanded ? "Collapses the group." : "Expands the group.")
    }
}
