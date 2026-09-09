import Foundation
import AppKit
import Security
import CryptoKit

final class RemoteTransport: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {
    var onMessage: (([String:Any],Data?)->Void)?
    var onStatus: ((String)->Void)?
    var onDisconnect: (()->Void)?
    var testFingerprint: String?
    // All connection state belongs to the main queue, including URLSession delegates.
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var hostIdentity = ""
    private var password = ""
    private var generation = UUID()
    private var closing = false
    func connect(host:String,port:Int,password:String) {
        disconnect()
        guard !host.isEmpty, (1...65535).contains(port), !host.contains("/"), !host.contains("@") else { rejectAddress("Enter a host name or IP address and a valid port."); return }
        var components = URLComponents(); components.scheme = "wss"; components.host = host; components.port = port; components.path = "/remote"
        guard let url = components.url else { rejectAddress("Invalid computer address."); return }
        self.password = password; hostIdentity = "\(host.lowercased()):\(port)"; closing = false; generation = UUID()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 24*60*60
        session = URLSession(configuration:config,delegate:self,delegateQueue:.main)
        let socket = session!.webSocketTask(with:url); socket.maximumMessageSize = 32*1024*1024; self.socket = socket
        onStatus?("Connecting securely to \(hostIdentity)…")
        socket.resume(); receive(socket,generation)
    }
    private func rejectAddress(_ message:String) {
        let stopped = generation; onStatus?(message)
        if generation == stopped { onDisconnect?() }
    }
    func disconnect() {
        closing = true; generation = UUID(); password = ""
        socket?.cancel(with:.goingAway,reason:nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
    private func isCurrent(_ socket:URLSessionWebSocketTask,_ expected:UUID) -> Bool {
        !closing && self.socket === socket && generation == expected
    }
    private func isCurrent(_ session:URLSession,_ expected:UUID) -> Bool {
        !closing && self.session === session && generation == expected
    }
    private func enqueue(_ socket:URLSessionWebSocketTask,_ expected:UUID,_ action:@escaping(RemoteTransport)->Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(socket,expected) else { return }; action(self)
        }
    }
    func send(_ object:[String:Any]) {
        guard let socket, !closing, let text = jsonString(object) else { return }
        let expected = generation
        socket.send(.string(text)) { [weak self] error in
            if let error { self?.enqueue(socket,expected) { $0.onStatus?("Send failed: \(error.localizedDescription)") } }
        }
    }
    private func receive(_ socket:URLSessionWebSocketTask,_ expected:UUID) {
        guard isCurrent(socket,expected) else { return }
        socket.receive { [weak self] result in
            // One pending callback/frame at a time bounds decoding and UI work.
            self?.enqueue(socket,expected) { $0.received(result,from:socket,expected:expected) }
        }
    }
    private func received(_ result:Result<URLSessionWebSocketTask.Message,Error>,from socket:URLSessionWebSocketTask,expected:UUID) {
        guard isCurrent(socket,expected) else { return }
        switch result {
        case .success(let message):
            switch message {
            case .string(let text):
                guard text.utf8.count <= 65536, let data = text.data(using:.utf8), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { fail("The computer sent invalid control data.",socket:socket,expected:expected); return }
                onMessage?(object,nil)
            case .data(let data):
                guard data.count >= 4, data.count <= 32*1024*1024 else { fail("A display update exceeded the message limit.",socket:socket,expected:expected); return }
                let count = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard count <= 65536, count > 0, count + 4 <= data.count, let object = try? JSONSerialization.jsonObject(with:data.subdata(in:4..<4+count)) as? [String:Any] else { fail("The computer sent an invalid display update.",socket:socket,expected:expected); return }
                onMessage?(object,data.subdata(in:4+count..<data.count))
            @unknown default: fail("Unsupported WebSocket message.",socket:socket,expected:expected); return
            }
            // onMessage can disconnect or replace the connection.
            if isCurrent(socket,expected) { receive(socket,expected) }
        case .failure(let error): fail("Disconnected: \(error.localizedDescription)",socket:socket,expected:expected)
        }
    }
    private func fail(_ message:String,socket:URLSessionWebSocketTask,expected:UUID) {
        enqueue(socket,expected) { transport in
            transport.disconnect(); let stopped = transport.generation
            transport.onStatus?(message)
            if transport.generation == stopped { transport.onDisconnect?() }
        }
    }
    func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didOpenWithProtocol protocol:String?) {
        guard self.session === session, self.socket === webSocketTask else { return }
        enqueue(webSocketTask,generation) { transport in
            let secret = transport.password; transport.password = ""
            transport.send(["type":"hello","version":1,"password":secret,"codecs":["png","jpeg"]])
            transport.onStatus?("Secure connection established. Authenticating…")
        }
    }
    func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didCloseWith closeCode:URLSessionWebSocketTask.CloseCode,reason:Data?) {
        guard self.session === session, self.socket === webSocketTask else { return }
        fail("The computer closed the connection.",socket:webSocketTask,expected:generation)
    }
    private func finishTrust(_ accepted:Bool,session:URLSession,expected:UUID,persist:()->Void) -> Bool {
        // runModal processes events: cancellation/reconnect can happen while the prompt is open.
        guard accepted, isCurrent(session,expected) else { return false }
        persist(); return true
    }
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        let expected = generation
        guard isCurrent(session,expected) else { completionHandler(.cancelAuthenticationChallenge,nil); return }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificate.first else { completionHandler(.performDefaultHandling,nil); return }
        let fingerprint = SHA256.hash(data:SecCertificateCopyData(leaf) as Data).map { String(format:"%02X",$0) }.joined(separator:":")
        if let testFingerprint {
            if testFingerprint.uppercased() == fingerprint { completionHandler(.useCredential,URLCredential(trust:trust)) } else { completionHandler(.cancelAuthenticationChallenge,nil) }; return
        }
        let identity = hostIdentity
        let key = "SU.Remote.TrustedCertificate." + identity
        if UserDefaults.standard.string(forKey:key) == fingerprint { completionHandler(.useCredential,URLCredential(trust:trust)); return }
        let changed = UserDefaults.standard.string(forKey:key) != nil
        NSApp.activate(ignoringOtherApps:true)
        let alert = NSAlert(); alert.alertStyle = changed ? .critical : .warning
        alert.messageText = changed ? "Computer identity changed" : "Trust this Portlight computer?"
        alert.informativeText = "\(identity)\n\nSHA-256 certificate fingerprint:\n\(fingerprint)\n\nCompare this fingerprint with the computer’s identity before trusting it. Your password has not been sent.\(changed ? "\n\nThe saved certificate differs. A reinstall or an unexpected computer may cause this." : "")"
        alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Trust and Connect")
        let accepted = alert.runModal() == .alertSecondButtonReturn
        if finishTrust(accepted,session:session,expected:expected,persist:{ UserDefaults.standard.set(fingerprint,forKey:key) }) {
            completionHandler(.useCredential,URLCredential(trust:trust))
        } else { completionHandler(.cancelAuthenticationChallenge,nil) }
    }
    static func runCallbackRegression(completion:@escaping([String:Bool])->Void) {
        let transport = RemoteTransport()
        func fixture() -> (URLSession,URLSessionWebSocketTask,UUID) {
            transport.disconnect()
            let session = URLSession(configuration:.ephemeral), socket = session.webSocketTask(with:URL(string:"wss://127.0.0.1:1/remote")!)
            transport.session = session; transport.socket = socket; transport.closing = false; transport.password = "fixture-secret"
            return (session,socket,transport.generation)
        }
        var statusCount = 0, disconnectCount = 0, messageCount = 0
        transport.onStatus = { _ in statusCount += 1 }; transport.onDisconnect = { disconnectCount += 1 }; transport.onMessage = { _,_ in messageCount += 1 }
        let (oldSession,oldSocket,oldGeneration) = fixture()
        transport.urlSession(oldSession,webSocketTask:oldSocket,didOpenWithProtocol:nil)
        transport.urlSession(oldSession,webSocketTask:oldSocket,didCloseWith:.normalClosure,reason:nil)
        transport.fail("Stale failure",socket:oldSocket,expected:oldGeneration)
        transport.enqueue(oldSocket,oldGeneration) { $0.onStatus?("Stale send failure") }
        transport.enqueue(oldSocket,oldGeneration) { $0.received(.success(.string("{\"type\":\"welcome\"}")),from:oldSocket,expected:oldGeneration) }
        let (newSession,newSocket,newGeneration) = fixture()
        var persisted = false
        let accepted = transport.finishTrust(true,session:oldSession,expected:oldGeneration,persist:{ persisted = true })
        DispatchQueue.main.async {
            var checks = ["stale_transport_callbacks_ignored":statusCount == 0 && disconnectCount == 0 && messageCount == 0 && transport.password == "fixture-secret" && transport.isCurrent(newSocket,newGeneration),"stale_certificate_approval_rejected":!accepted && !persisted]
            transport.urlSession(newSession,webSocketTask:newSocket,didCloseWith:.normalClosure,reason:nil)
            DispatchQueue.main.async {
                checks["current_transport_close_delivered_once"] = statusCount == 1 && disconnectCount == 1 && transport.socket == nil
                transport.disconnect(); completion(checks)
            }
        }
    }
}
