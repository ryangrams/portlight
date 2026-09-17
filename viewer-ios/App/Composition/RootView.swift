import SwiftUI
import PortlightKit

/// The app's root (UI-SPEC §1): the Connections list in a `NavigationStack`, the connection form pushed through
/// `ConnectionRoute`, and the session as a full-screen cover while a started session isn't idle.
///
/// Selecting a row only pushes its form: no connection starts and no Keychain item is read until Connect.
struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            ConnectionsListView(library: Binding(get: { model.library }, set: { model.applyListEdit($0) }),
                                onConnect: { model.connectFromList($0) },
                                onEdit: { model.path.append(.edit($0.id)) },
                                onDelete: { model.delete($0) },
                                onNewConnection: { model.path.append(.new(groupID: $0)) })
                .safeAreaInset(edge: .top, spacing: 0) { noticeStack }
                .navigationDestination(for: ConnectionRoute.self) { route in
                    ConnectionEditor(route: route, model: model)
                }
        }
        // Dismissal follows the session: disconnect, cancel and a dismissed failure end at idle.
        .fullScreenCover(isPresented: Binding(get: { model.isSessionPresented }, set: { _ in })) {
            SessionScreen(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            model.controller.scenePhaseChanged(SessionScreen.sessionPhase(phase))
        }
        .onChange(of: model.controller.phase) { _, phase in
            model.sessionPhaseChanged(phase)
        }
    }

    /// Launch-load, storage and save notices: visible, dismissible, never blocking the list.
    @ViewBuilder
    private var noticeStack: some View {
        if !model.notices.isEmpty {
            VStack(spacing: 8) {
                ForEach(model.notices, id: \.self) { notice in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(notice)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("connections.notice")
                        Button {
                            model.dismissNotice(notice)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(.leading, 12)
                    .cardSurface(cornerRadius: 14)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

/// The pushed form for one route: a saved connection or a new draft. It owns the draft; Save, Connect and
/// Forget go through `AppModel`.
struct ConnectionEditor: View {
    let model: AppModel
    @State private var draft: ConnectionDraft
    @State private var saveMessage: String?

    init(route: ConnectionRoute, model: AppModel) {
        self.model = model
        switch route {
        case .edit(let id):
            _draft = State(initialValue: model.library.profile(id: id).map { ConnectionDraft(editing: $0) } ?? ConnectionDraft())
        case .new(let groupID):
            _draft = State(initialValue: ConnectionDraft(groupID: groupID))
        }
    }

    /// The saved connection as the library holds it now.
    private var stored: ConnectionProfile? {
        draft.original.flatMap { model.library.profile(id: $0.id) }
    }

    private var fieldError: (field: ConnectionDraft.Field, message: String)? {
        guard let error = model.connectError, error.profileID == draft.original?.id else { return nil }
        return (error.field, error.message)
    }

    var body: some View {
        ConnectionDetailView(draft: $draft, fieldError: fieldError,
                             onConnect: { model.connect(draft: draft) },
                             onSave: { saveMessage = model.save(&draft) },
                             onForgetPassword: forgetPassword)
            .onChange(of: draft.password) { clearError(for: .password) }
            .onChange(of: draft.host) { clearError(for: .host) }
            .onChange(of: stored?.hasSavedPassword) { refreshFromLibrary() }
            .alert("Connection Saved", isPresented: Binding(get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } })) {
                Button("OK", role: .cancel) { saveMessage = nil }
            } message: {
                Text(saveMessage ?? "")
            }
    }

    private var forgetPassword: (@MainActor () -> Void)? {
        guard let id = draft.original?.id else { return nil }
        return { model.forgetPassword(profileID: id) }
    }

    private func clearError(for field: ConnectionDraft.Field) {
        if let error = model.connectError, error.field == field, error.profileID == draft.original?.id {
            model.connectError = nil
        }
    }

    /// The saved-password hint changed (Forget, or a Keychain item found missing): edit the library's copy,
    /// keeping what was typed.
    private func refreshFromLibrary() {
        guard let stored else { return }
        var fresh = ConnectionDraft(editing: stored)
        fresh.name = draft.name
        fresh.host = draft.host
        fresh.port = draft.port
        fresh.password = draft.password
        fresh.rememberPassword = draft.rememberPassword
        fresh.groupID = draft.groupID
        if fresh != draft { draft = fresh }
    }
}
