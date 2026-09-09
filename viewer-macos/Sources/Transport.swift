import Foundation
import AppKit
import Security
import CryptoKit

final class RemoteTransport: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {
    var onMessage: (([String:Any],Data?)->Void)?
    var onStatus: ((String)->Void)?
    var onDisconnect: (()->Void)?
    var testFingerprint: String?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var hostIdentity = ""
    private var password = ""
    private var generation = UUID()
    private var closing = false
    private var waitingForCertificate = false
    func connect(host:String,port:Int,password:String) {
        disconnect()
        guard !host.isEmpty, (1...65535).contains(port), !host.contains("/"), !host.contains("@") else { onStatus?("Enter a host name or IP address and a valid port."); return }
        var components = URLComponents(); components.scheme = "wss"; components.host = host; components.port = port; components.path = "/remote"
        guard let url = components.url else { onStatus?("Invalid server address."); return }
        self.password = password; hostIdentity = "\(host.lowercased()):\(port)"; closing = false; generation = UUID()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 24*60*60
        session = URLSession(configuration:config,delegate:self,delegateQueue:nil)
        let socket = session!.webSocketTask(with:url); socket.maximumMessageSize = 32*1024*1024; self.socket = socket
        onStatus?("Connecting securely to \(hostIdentity)…")
        socket.resume(); receive(socket,generation)
    }
    func disconnect() {
        closing = true; generation = UUID(); password = ""
        socket?.cancel(with:.goingAway,reason:nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
    func send(_ object:[String:Any]) {
        guard let socket, let text = jsonString(object) else { return }
        socket.send(.string(text)) { [weak self] error in if let error { DispatchQueue.main.async { self?.onStatus?("Send failed: \(error.localizedDescription)") } } }
    }
    private func receive(_ socket:URLSessionWebSocketTask,_ expected:UUID) {
        socket.receive { [weak self,weak socket] result in
            guard let self, let socket, self.generation == expected else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    guard text.utf8.count <= 65536, let data = text.data(using:.utf8), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { self.fail("The computer sent invalid control data."); return }
                    DispatchQueue.main.async { if self.generation == expected { self.onMessage?(object,nil); self.receive(socket,expected) } }
                    return
                case .data(let data):
                    guard data.count >= 4, data.count <= 32*1024*1024 else { self.fail("A display update exceeded the message limit."); return }
                    let count = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    guard count <= 65536, count > 0, count + 4 <= data.count, let object = try? JSONSerialization.jsonObject(with:data.subdata(in:4..<4+count)) as? [String:Any] else { self.fail("The computer sent an invalid display update."); return }
                    let payload = data.subdata(in:4+count..<data.count)
                    // Run on the main queue before reading another frame; bounded decode/UI work provides backpressure.
                    DispatchQueue.main.async { if self.generation == expected { self.onMessage?(object,payload); self.receive(socket,expected) } }
                    return
                @unknown default: self.fail("Unsupported WebSocket message."); return
                }
            case .failure(let error):
                DispatchQueue.main.async { if !self.closing && self.generation == expected { self.onStatus?("Disconnected: \(error.localizedDescription)"); self.onDisconnect?() } }
            }
        }
    }
    private func fail(_ message:String) { DispatchQueue.main.async { self.disconnect(); self.onStatus?(message); self.onDisconnect?() } }
    func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didOpenWithProtocol protocol:String?) {
        guard self.socket === webSocketTask else { return }
        let secret = password; password = ""
        send(["type":"hello","version":1,"password":secret,"codecs":["png","jpeg"]])
        DispatchQueue.main.async { self.onStatus?("Secure connection established. Authenticating…") }
    }
    func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didCloseWith closeCode:URLSessionWebSocketTask.CloseCode,reason:Data?) {
        guard self.socket === webSocketTask else { return }
        DispatchQueue.main.async { if !self.closing { self.onStatus?("The computer closed the connection."); self.onDisconnect?() } }
    }
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        guard self.session === session else { completionHandler(.cancelAuthenticationChallenge,nil); return }
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
        DispatchQueue.main.async {
            guard self.session === session else { completionHandler(.cancelAuthenticationChallenge,nil); return }
            NSApp.activate(ignoringOtherApps:true)
            let alert = NSAlert(); alert.alertStyle = changed ? .critical : .warning
            alert.messageText = changed ? "Computer identity changed" : "Trust this Portlight computer?"
            alert.informativeText = "\(identity)\n\nSHA-256 certificate fingerprint:\n\(fingerprint)\n\nCompare this fingerprint with the computer’s identity before trusting it. Your password has not been sent.\(changed ? "\n\nThe saved certificate differs. A reinstall or an unexpected computer may cause this." : "")"
            alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Trust and Connect")
            if alert.runModal() == .alertSecondButtonReturn {
                UserDefaults.standard.set(fingerprint,forKey:key); completionHandler(.useCredential,URLCredential(trust:trust))
            } else { completionHandler(.cancelAuthenticationChallenge,nil) }
        }
    }
}
