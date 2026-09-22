import AppKit

extension RemoteServer {
    func makePopupMessages() -> PopupMessageController {
        let messages = PopupMessageController(fixture: fixture)
        messages.onChange = { [weak self] in
            guard let self else { return }
            self.activeSession?.send(self.popupMessages.state)
            self.onPopupChange?()
        }
        return messages
    }
}

extension RemoteSession {
    func handlePopupMessage(_ object: [String: Any]) -> Bool {
        switch object["type"] as? String {
        case "popupMessage":
            do { server.popupMessages.show(try PopupMessage(object)) }
            catch { send(["type": "error", "code": "popupMessage", "message": error.localizedDescription]) }
        case "clearPopupMessage": server.popupMessages.clear()
        case "setPopupMessageDisplays":
            do {
                guard let ids = object["displayIDs"] as? [String] else {
                    throw PopupMessageFailure(message: "Select at least one available message screen.")
                }
                if try !server.popupMessages.selectDisplays(ids) { send(server.popupMessages.state) }
            } catch { send(["type": "error", "code": "popupMessage", "message": error.localizedDescription]) }
        case "getPopupMessageState":
            server.popupMessages.expireIfNeeded()
            send(server.popupMessages.state)
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    func appendMessageMenu(to menu: NSMenu) {
        guard let messages = server?.popupMessages else { return }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for display in messages.displays {
            let item = NSMenuItem(title: "\(display.index). \(display.name)", action: #selector(toggleMessageScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display.id
            item.state = messages.selectedIDs.contains(display.id) ? .on : .off
            item.isEnabled = !(messages.selectedIDs.count == 1 && messages.selectedIDs.contains(display.id))
            submenu.addItem(item)
        }
        let screens = NSMenuItem(title: "Message Screens", action: nil, keyEquivalent: "")
        screens.submenu = submenu
        menu.addItem(screens)
        let clear = NSMenuItem(title: "Clear Message", action: #selector(clearMessage), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }
    @objc func clearMessage() { server.popupMessages.clear() }
    @objc func toggleMessageScreen(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { server.popupMessages.toggleDisplay(id) }
    }
}
