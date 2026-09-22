import AppKit

final class ViewerPopupSession {
    static func addLauncher(to identity: NSStackView, button: NSButton) {
        button.toolTip = "Send message"; button.setAccessibilityLabel("Send message")
        button.translatesAutoresizingMaskIntoConstraints = false
        identity.addSubview(button)
        NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: identity.trailingAnchor), button.centerYAnchor.constraint(equalTo: identity.centerYAnchor), button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28)])
        for view in identity.arrangedSubviews { view.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -6).isActive = true }
    }

    private var capability: [String: Any]?
    private var connected = false
    private var state: (active: Bool, duration: Int)?
    private var displays: [ViewerPopupDisplay] = []
    private var selectedDisplays = Set<String>()
    private var composer: PopupComposerController?
    private let send: ([String: Any]) -> Void

    init(send: @escaping ([String: Any]) -> Void) { self.send = send }

    func welcome(_ object: [String: Any]) {
        connected = true
        capability = (object["capabilities"] as? [String: Any])?["popupMessages"] as? [String: Any]
        composer?.configure(connected: connected, capability: capability)
    }

    func disconnect() {
        connected = false; capability = nil; state = nil; displays = []; selectedDisplays = []
        composer?.setDisplays([], selected: [])
        composer?.configure(connected: false, capability: nil)
        composer?.close()
    }

    func show(appearance: NSAppearance?, defaults: UserDefaults?) {
        if composer == nil {
            let panel = PopupComposerController(defaults: defaults)
            panel.onSend = { [weak self] message in self?.sendMessage(message) }
            panel.onClear = { [weak self] in self?.sendMessage(["type": "clearPopupMessage"]) }
            panel.onTargetDisplays = { [weak self] ids in
                guard self?.capability?["targetDisplays"] as? Bool == true else { return }
                self?.sendMessage(["type": "setPopupMessageDisplays", "displayIDs": ids])
            }
            composer = panel
        }
        composer?.configure(connected: connected, capability: capability)
        composer?.setDisplays(displays, selected: selectedDisplays)
        if let state { composer?.receivedState(active: state.active, duration: state.duration) }
        composer?.window?.appearance = appearance
        composer?.showWindow(nil)
    }

    private func sendMessage(_ message: [String: Any]) {
        guard connected, capability != nil else { return }
        send(message)
    }

    func receive(_ object: [String: Any]) -> Bool {
        if object["type"] as? String == "popupMessageState" {
            guard connected, capability != nil, let active = object["active"] as? Bool,
                  let duration = ViewerPopupText.integer(object["durationSeconds"]),
                  let expiry = object["expiresAt"] as? Double, expiry.isFinite, expiry >= 0,
                  let selected = object["displayIDs"] as? [String], selected.count <= 32 else { return true }
            if capability?["targetDisplays"] as? Bool == true {
                guard let rows = object["availableDisplays"] as? [[String: Any]], rows.count <= 32 else { return true }
                var parsed: [ViewerPopupDisplay] = []
                for (offset, row) in rows.enumerated() {
                    guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 256, !parsed.contains(where: { $0.id == id }),
                          let name = row["name"] as? String else { return true }
                    let number = (row["index"] as? Int).flatMap { (1...32).contains($0) ? $0 : nil } ?? offset + 1
                    parsed.append(ViewerPopupDisplay(id: id, name: String(name.prefix(128)), index: number))
                }
                let chosen = Set(selected)
                guard chosen.isSubset(of: Set(parsed.map(\.id))), !chosen.isEmpty || parsed.isEmpty else { return true }
                displays = parsed; selectedDisplays = chosen
                composer?.setDisplays(displays, selected: selectedDisplays)
            }
            state = (active, duration)
            composer?.receivedState(active: active, duration: duration)
            return true
        }
        if object["type"] as? String == "error", object["code"] as? String == "popupMessage" {
            composer?.setDisplays(displays, selected: selectedDisplays)
            composer?.setStatus(object["message"] as? String ?? "The Host could not display the message.", error: true)
            return true
        }
        return false
    }
}
