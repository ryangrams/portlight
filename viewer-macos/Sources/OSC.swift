import Foundation
import Network

struct OSCMessage {
    let address: String
    let arguments: [Any]
    static func parse(_ data: Data) -> OSCMessage? {
        guard data.count <= 65507 else { return nil }
        let bytes = [UInt8](data); var offset = 0
        func string() -> String? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of:0) else { return nil }
            guard let text = String(bytes:bytes[offset..<end],encoding:.utf8) else { return nil }
            offset = (end + 4) & ~3
            guard offset <= bytes.count else { return nil }
            return text
        }
        func word() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = bytes[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; offset += 4; return value
        }
        guard let address = string(), address.hasPrefix("/su/remote/"), let tags = string(), tags.first == ",", tags.count <= 65 else { return nil }
        var args: [Any] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "s": guard let s = string() else { return nil }; args.append(s)
            case "i": guard let n = word() else { return nil }; args.append(Int(Int32(bitPattern:n)))
            case "f": guard let n = word() else { return nil }; let f = Float(bitPattern:n); guard f.isFinite else { return nil }; args.append(Double(f))
            case "T": args.append(1)
            case "F": args.append(0)
            default: return nil
            }
        }
        guard offset == bytes.count else { return nil }
        return OSCMessage(address:address,arguments:args)
    }
    static func encodeString(_ address: String, _ value: String) -> Data {
        func padded(_ string: String) -> Data { var d = Data(string.utf8); d.append(0); while d.count % 4 != 0 { d.append(0) }; return d }
        return padded(address) + padded(",s") + padded(value)
    }
}

final class OSCReceiver {
    var onMessage: ((OSCMessage,NWConnection)->Void)?
    var onStatus: ((String)->Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label:"studio.upgrade.remote.osc")
    private var peers: [UUID:NWConnection] = [:]
    let port: UInt16
    init(port:UInt16 = 19790) { self.port = port }
    func start() {
        do {
            let parameters = NWParameters.udp
            parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
            let listener = try NWListener(using:parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { DispatchQueue.main.async { self?.onStatus?("OSC unavailable: \(error.localizedDescription)") } }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }; let id = UUID()
                // Bound local senders so a flood cannot create unbounded retained connections.
                if self.peers.count >= 16 { connection.cancel(); return }
                self.peers[id] = connection
                connection.stateUpdateHandler = { [weak self] state in if case .cancelled = state { self?.peers.removeValue(forKey:id) } }
                connection.start(queue:self.queue); self.receive(connection)
            }
            listener.start(queue:queue)
        } catch { onStatus?("OSC unavailable: \(error.localizedDescription)") }
    }
    private func receive(_ connection:NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data,_,_,error in
            guard let self, let connection else { return }
            if let data, let message = OSCMessage.parse(data) { DispatchQueue.main.async { self.onMessage?(message,connection) } }
            if error == nil { self.receive(connection) } else { connection.cancel() }
        }
    }
    func reply(_ connection:NWConnection,address:String = "/su/remote/state",value:String) {
        connection.send(content:OSCMessage.encodeString(address,value),completion:.contentProcessed { _ in })
    }
    func stop() { listener?.cancel(); listener = nil; queue.async { for c in self.peers.values { c.cancel() }; self.peers.removeAll() } }
    deinit { listener?.cancel() }
}
