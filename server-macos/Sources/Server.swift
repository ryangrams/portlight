import Foundation
import Network
import Security
import AppKit
import ScreenCaptureKit

func binaryMessage(_ header: [String:Any], payload: Data) -> Data {
    let json = try! JSONSerialization.data(withJSONObject:header,options:[.sortedKeys])
    var size = UInt32(json.count).bigEndian
    var result = Data(bytes:&size,count:4); result.append(json); result.append(payload); return result
}
func muLaw(_ value: Int16) -> UInt8 {
    var sample = Int(value); let sign = sample < 0 ? 0x80 : 0
    if sample < 0 { sample = -sample }
    sample = min(32635,sample) + 0x84
    var exponent = 7; var mask = 0x4000
    while exponent > 0 && sample & mask == 0 { exponent-=1; mask >>= 1 }
    let mantissa = (sample >> (exponent+3)) & 0x0f
    return UInt8(truncatingIfNeeded: ~(sign | exponent<<4 | mantissa))
}

struct Subscription {
    var revision = -1
    var ids: [String] = []
    var preset = "fhd"
    var color = "full"
    var quality = "auto"
    var fps = 15
    var bandwidth = 4000
    var paused = false
    var audio = false
    var viewOnly = false
    var regions: [String:CGRect] = [:]
}

final class RemoteServer {
    let security: ServerSecurity
    let fixture: Bool
    let fixtureDense: Bool
    let packetWindow: Int
    var listener: NWListener?
    var sessions: [UUID:RemoteSession] = [:]
    weak var activeSession: RemoteSession?
    var displays: [DisplayInfo] = []
    var onStatus: ((String) -> Void)?
    var onConnection: (() -> Void)?
    var failedAttempts: [Date] = []
    private var topologyTimer: Timer?
    init(security: ServerSecurity, fixture: Bool, fixtureDense: Bool = false, packetWindow: Int = 32) { self.security=security; self.fixture=fixture; self.fixtureDense=fixture && fixtureDense; self.packetWindow=fixture ? max(1,min(32,packetWindow)) : 32 }
    func start(port: UInt16) throws {
        guard listener == nil else { return }
        try security.loadIdentity()
        guard let identity = security.identity else { throw ServerFailure(message:"TLS identity unavailable.") }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions,identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv12)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions,false)
        let params = NWParameters(tls:tls,tcp:NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        if fixture { params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any) }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 65536
        params.defaultProtocolStack.applicationProtocols.insert(websocket,at:0)
        let listener = try NWListener(using:params,on:NWEndpoint.Port(rawValue:port)!)
        self.listener=listener
        displays=availableDisplays(fixture:fixture)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            if self.fixture { fputs("Incoming connection\n",stderr) }
            self.failedAttempts.removeAll { Date().timeIntervalSince($0) > 60 }
            guard self.sessions.count < 8, self.failedAttempts.count < 10 else { connection.cancel(); return }
            let session = RemoteSession(server:self,connection:connection)
            self.sessions[session.id]=session; session.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state { case .ready: self?.onStatus?("Listening on port \(port)")
            case .failed(let error): self?.onStatus?("Server error: \(error.localizedDescription)"); self?.stop()
            default: break }
        }
        listener.start(queue:.main)
        topologyTimer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.refreshDisplays() }
    }
    func refreshDisplays() {
        let updated=availableDisplays(fixture:fixture)
        if updated.map({"\($0.id):\($0.width)x\($0.height):\($0.bounds)"}) != displays.map({"\($0.id):\($0.width)x\($0.height):\($0.bounds)"}) {
            displays=updated
            for session in Array(sessions.values) where session.authenticated { session.topologyChanged() }
        }
    }
    func stop() {
        topologyTimer?.invalidate(); topologyTimer=nil
        listener?.cancel(); listener=nil
        for session in Array(sessions.values) { session.close() }
        activeSession=nil; onStatus?("Stopped"); onConnection?()
    }
}

final class RemoteSession {
    let id=UUID()
    unowned let server: RemoteServer
    let connection: NWConnection
    private(set) var authenticated=false
    private(set) var subscription=Subscription()
    private var streams: [String:CaptureStream] = [:]
    private var encoders: [String:TileEncoder] = [:]
    private let encodeQueue=DispatchQueue(label:"com.studioupgrade.suremote.encode",qos:.userInitiated)
    private var processing=Set<String>()
    private var outbound: [(Data,Int)] = []
    private var inFlight: [Int:(Int,Date)] = [:]
    private var displaySequences: [String:Set<Int>] = [:]
    private var sequence=0
    private var pendingBytes=0
    private var networkBytes=0
    private var controlBytes=0
    private var tokens=Double(512*1024)
    private var lastTokenTime=Date()
    private var timer: Timer?
    private var authenticationTimer: Timer?
    private var fixtureFrame=0
    private var frameCounter=0
    private var skippedFrames=0
    private var encodedInputs=0
    private var encodingTotals=EncodingMetrics()
    private var bytesSent=0
    private var lastStats=Date()
    private var lastCursorTime=Date.distantPast
    private var lastCursorKey=""
    private var closed=false
    private var input=InputController()
    private var buttonMask=0
    private var wheelRemainderX=0.0
    private var wheelRemainderY=0.0
    private var heldModifiers=Set<String>()
    private var audioBytes=Data()
    private var startingTask: Task<Void,Never>?
    init(server: RemoteServer, connection: NWConnection) { self.server=server; self.connection=connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if self?.server.fixture == true { fputs("State: \(state)\n",stderr) }
            switch state {
            case .failed(let error):
                if self?.server.fixture == true { fputs("Connection failed: \(error)\n",stderr) }
                self?.close()
            case .cancelled: self?.close()
            default:break }
        }
        connection.start(queue:.main)
        authenticationTimer=Timer.scheduledTimer(withTimeInterval:120,repeats:false) { [weak self] _ in if self?.authenticated == false { self?.close() } }
        timer=Timer.scheduledTimer(withTimeInterval:0.025,repeats:true) { [weak self] _ in self?.tick() }
        receive()
    }
    func close() {
        guard !closed else { return }; closed=true
        authenticationTimer?.invalidate(); timer?.invalidate(); startingTask?.cancel()
        input.releaseAll(); stopCapture()
        connection.cancel(); server.sessions.removeValue(forKey:id)
        if server.activeSession === self { server.activeSession=nil }
        server.onConnection?()
    }
    private func receive() {
        connection.receiveMessage { [weak self] data,context,_,error in
            guard let self, !self.closed else { return }
            if let error { if self.server.fixture { fputs("Receive failed: \(error)\n",stderr) };self.close(); return }
            if let meta=context?.protocolMetadata(definition:NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, meta.opcode == .close { self.close(); return }
            if let data, !data.isEmpty {
                guard data.count <= 65536, let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { self.error("message","Invalid control message"); self.close(); return }
                self.handle(object)
            }
            self.receive()
        }
    }
    func send(_ object: [String:Any], completion: (() -> Void)? = nil) {
        guard !closed, let data=try? JSONSerialization.data(withJSONObject:object) else { return }
        guard controlBytes + data.count <= 1024*1024 else { close();return }
        controlBytes+=data.count
        let meta=NWProtocolWebSocket.Metadata(opcode:.text)
        let context=NWConnection.ContentContext(identifier:"control",metadata:[meta])
        connection.send(content:data,contentContext:context,isComplete:true,completion:.contentProcessed { [weak self] error in
            self?.controlBytes-=data.count
            if error != nil { self?.close() }; completion?()
        })
    }
    private func error(_ code: String,_ message: String) { send(["type":"error","code":code,"message":message]) }
    private func welcome(type: String = "welcome") {
        send(["type":type,"version":1,"serverName":server.fixture ? "Portlight Test Host" : (Host.current().localizedName ?? "Mac"),"sessionId":id.uuidString,
              "displays":server.displays.map { d -> [String:Any] in var o=d.json; o["primary"] = d.index == 1; return o },
              "capabilities":["codecs":["png","jpeg"],"audio":server.fixture ? [] : ["mulaw"],"colorModes":["gray16","color256","rgb565","full"],"maxViewers":1]])
    }
    func topologyChanged() {
        startingTask?.cancel(); stopCapture(); input.releaseAll(); subscription.ids=[]; outbound=[]; pendingBytes=0; welcome(type:"displays")
        error("topology","Displays changed. Select displays again.")
    }
    private func handle(_ object: [String:Any]) {
        guard let type=object["type"] as? String else { error("message","Missing message type"); return }
        if !authenticated {
            guard type == "hello", object["version"] as? Int == 1, let password=object["password"] as? String, server.security.verify(password) else {
                server.failedAttempts.append(Date())
                send(["type":"error","code":"authentication","message":"Incorrect password or incompatible protocol"]) { [weak self] in self?.close() }; return
            }
            guard server.activeSession == nil else { send(["type":"error","code":"busy","message":"Another viewer is connected. Disconnect it before connecting here."]) { [weak self] in self?.close() }; return }
            authenticated=true; authenticationTimer?.invalidate(); server.activeSession=self; welcome(); server.onConnection?(); return
        }
        switch type {
        case "subscribe": applySubscription(object)
        case "frameAck":
            if let seq=object["sequence"] as? Int, let old=inFlight.removeValue(forKey:seq) {
                pendingBytes-=old.0
                for id in Array(displaySequences.keys) { displaySequences[id]?.remove(seq) }
            }; drain()
        case "ping": send(["type":"pong","time":object["time"] ?? 0])
        case "pointer","wheel","key","text": handleInput(type,object)
        default: error("message","Unknown message type")
        }
    }
    private func applySubscription(_ o: [String:Any]) {
        guard let revision=o["revision"] as? Int, revision >= 0, revision > subscription.revision,
              let ids=o["displays"] as? [String], ids.count <= 16, Set(ids).count == ids.count,
              ids.allSatisfy({ wanted in server.displays.contains{$0.id == wanted} }),
              let w=o["maxWidth"] as? Int, let h=o["maxHeight"] as? Int,
              let preset=resolutionSizes.first(where:{$0.value.0 == w && $0.value.1 == h})?.key,
              let color=o["color"] as? String,["full","gray16","color256","rgb565"].contains(color),
              let quality=o["quality"] as? String,["auto","desktop","motion"].contains(quality),
              let fps=o["fps"] as? Int,(1...60).contains(fps),
              let bandwidth=o["bandwidthKbps"] as? Int,bandwidth == 0 || (100...100000).contains(bandwidth) else {
            error("subscription","Invalid displays, revision, resolution, color, quality, frame rate or bandwidth"); return
        }
        var regions: [String:CGRect]=[:]
        if o["regions"] != nil && !(o["regions"] is [String:[String:Double]]) { error("subscription","Invalid visible region map");return }
        if let raw=o["regions"] as? [String:[String:Double]] {
            for (key,v) in raw {
                guard ids.contains(key),let x=v["x"],let y=v["y"],let rw=v["width"],let rh=v["height"],
                      [x,y,rw,rh].allSatisfy({$0.isFinite}),x >= 0,y >= 0,rw >= 0,rh >= 0,(rw == 0) == (rh == 0),x+rw <= 1.0001,y+rh <= 1.0001 else { error("subscription","Invalid visible region"); return }
                regions[key]=CGRect(x:x,y:y,width:rw,height:rh)
            }
        }
        let selected=ids.compactMap { wanted in server.displays.first{$0.id == wanted} }
        let actualPreset=commonResolution(preset,displays:selected)
        let next=Subscription(revision:revision,ids:ids,preset:actualPreset,color:color,quality:quality,fps:fps,bandwidth:bandwidth,
                              paused:o["paused"] as? Bool ?? false,audio:(o["audio"] as? Bool ?? false) && !server.fixture,
                              viewOnly:o["viewOnly"] as? Bool ?? false,regions:regions)
        startingTask?.cancel(); stopCapture(); input.releaseAll(); buttonMask=0; heldModifiers=[]
        subscription=next; lastCursorKey=""; outbound=[]; pendingBytes=inFlight.values.reduce(0){$0+$1.0}; encoders=[:]; processing=[]; displaySequences=[:]; audioBytes=Data()
        tokens=Double(max(65536,bandwidth*125)); lastTokenTime=Date()
        var response: [String:Any]=["type":"subscribed","revision":revision,"displays":selected.map { d -> [String:Any] in
            let s=scaledSize(d,preset:actualPreset); return ["id":d.id,"width":s.0,"height":s.1] },"paused":next.paused,"audio":next.audio,"resolution":actualPreset]
        if actualPreset != preset { response["notice"]="Resolution limited to \(actualPreset.uppercased()) by the selected displays." }
        send(response) { [weak self] in self?.startCapture(revision:revision) }
    }
    private func stopCapture() {
        let old=Array(streams.values); streams=[:]
        Task { for stream in old { await stream.stop() } }
    }
    private func startCapture(revision: Int) {
        guard subscription.revision == revision, !closed, !server.fixture else { return }
        let settings=subscription
        guard !settings.ids.isEmpty || settings.audio, !settings.paused || settings.audio else { return }
        startingTask=Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                let captureIDs = settings.ids.isEmpty && settings.audio ? Array(self.server.displays.prefix(1).map(\.id)) : settings.ids
                for (i,id) in captureIDs.enumerated() {
                    guard !Task.isCancelled,self.subscription.revision == revision,!self.closed else { return }
                    if settings.paused && i > 0 { break }
                    if settings.regions[id]?.isEmpty == true && !(settings.audio && i == 0) { continue }
                    guard let display=self.server.displays.first(where:{$0.id == id}),let sc=content.displays.first(where:{$0.displayID == display.cgID}) else { continue }
                    let audioOnly = settings.paused || settings.ids.isEmpty || settings.regions[id]?.isEmpty == true
                    let size=audioOnly ? (2,2) : scaledSize(display,preset:settings.preset)
                    let stream=try CaptureStream(display:display,scDisplay:sc,size:size,fps:audioOnly ? 1 : settings.fps,audio:settings.audio && i == 0)
                    stream.onImage = { [weak self] image in DispatchQueue.main.async { self?.acceptImage(image,display:display,revision:revision) } }
                    stream.onAudio = { [weak self] data in DispatchQueue.main.async { self?.acceptAudio(data,revision:revision) } }
                    stream.onError = { [weak self] message in DispatchQueue.main.async { self?.error("capture",message) } }
                    self.streams[id]=stream
                    try await stream.start()
                    if Task.isCancelled || self.subscription.revision != revision { await stream.stop(); return }
                }
            } catch { if self.subscription.revision == revision { self.error("capture","Screen capture failed. Allow Portlight Host in Screen & System Audio Recording, then reconnect. \(error.localizedDescription)") } }
        }
    }
    private func acceptImage(_ image: CGImage,display: DisplayInfo,revision: Int) {
        guard !closed,subscription.revision == revision,!subscription.paused,subscription.ids.contains(display.id),subscription.regions[display.id]?.isEmpty != true else { return }
        guard !processing.contains(display.id),displaySequences[display.id]?.isEmpty != false,pendingBytes < 16*1024*1024 else { skippedFrames+=1;return }
        processing.insert(display.id)
        let encoder=encoders[display.id] ?? TileEncoder(); encoders[display.id]=encoder
        let settings=subscription
        let region=settings.regions[display.id] ?? CGRect(x:0,y:0,width:1,height:1)
        let motion=settings.quality == "motion"
        let quality=settings.bandwidth > 0 && settings.bandwidth < 1500 ? 0.4 : 0.7
        encodeQueue.async { [weak self] in
            let tiles=encoder.encode(image,region:region,color:settings.color,quality:quality,motion:motion,auto:settings.quality == "auto")
            let timings=encoder.metrics
            DispatchQueue.main.async {
                guard let self,self.subscription.revision == revision,self.subscription.ids.contains(display.id),!self.subscription.paused,!self.closed else { return }
                self.processing.remove(display.id)
                self.encodedInputs+=1
                self.encodingTotals.totalMilliseconds+=timings.totalMilliseconds
                self.encodingTotals.rasterMilliseconds+=timings.rasterMilliseconds
                self.encodingTotals.quantizeMilliseconds+=timings.quantizeMilliseconds
                self.encodingTotals.diffMilliseconds+=timings.diffMilliseconds
                self.encodingTotals.codecMilliseconds+=timings.codecMilliseconds
                if !tiles.isEmpty { self.frameCounter+=1 }
                for tile in tiles {
                    self.sequence+=1
                    let data=binaryMessage(["type":"frame","revision":revision,"display":display.id,"x":tile.x,"y":tile.y,"width":tile.width,"height":tile.height,
                                            "canvasWidth":image.width,"canvasHeight":image.height,"codec":tile.codec,"sequence":self.sequence],payload:tile.data)
                    guard data.count <= 32*1024*1024,self.pendingBytes+data.count <= 32*1024*1024,self.outbound.count < 256 else { encoder.reset(); break }
                    self.outbound.append((data,self.sequence)); self.pendingBytes+=data.count
                    self.displaySequences[display.id,default:[]].insert(self.sequence)
                }
                self.drain()
            }
        }
    }
    private func acceptAudio(_ pcm: Data,revision: Int) {
        guard !closed,subscription.revision == revision,subscription.audio else { return }
        let ulaw=pcm.withUnsafeBytes { raw -> Data in let samples=raw.bindMemory(to:Int16.self); return Data(samples.map(muLaw)) }
        audioBytes.append(ulaw)
        if audioBytes.count > 4800 { audioBytes=audioBytes.suffix(4800) }
        while audioBytes.count >= 480 {
            let samples=audioBytes.prefix(480); audioBytes.removeFirst(480)
            sequence+=1
            let packet=binaryMessage(["type":"audio","revision":revision,"codec":"mulaw","sampleRate":24000,"channels":1,"sequence":sequence,"samples":480],payload:Data(samples))
            if pendingBytes < 512*1024, networkBytes < 256*1024, tokens >= Double(packet.count) { tokens-=Double(packet.count); transmit(packet,sequence:nil) }
        }
    }
    private func drain() {
        guard !closed else { return }
        while !outbound.isEmpty,inFlight.count < server.packetWindow {
            let next=outbound[0]
            let inFlightBytes=inFlight.values.reduce(0) { $0+$1.0 }
            guard inFlight.isEmpty || inFlightBytes+next.0.count <= 2*1024*1024 else { break }
            guard subscription.bandwidth == 0 || tokens >= Double(next.0.count) || (tokens > 0 && next.0.count > max(65536,subscription.bandwidth*125)) else { break }
            outbound.removeFirst(); tokens-=Double(next.0.count)
            inFlight[next.1]=(next.0.count,Date()); transmit(next.0,sequence:next.1)
        }
    }
    private func transmit(_ data: Data, sequence: Int?) {
        let metadata=NWProtocolWebSocket.Metadata(opcode:.binary)
        networkBytes+=data.count
        connection.send(content:data,contentContext:NWConnection.ContentContext(identifier:"media",metadata:[metadata]),isComplete:true,completion:.contentProcessed { [weak self] error in
            self?.networkBytes-=data.count
            if error != nil { self?.close() }
        })
        bytesSent+=data.count
    }
    private func tick() {
        guard authenticated,!closed else { return }
        let now=Date(); let elapsed=now.timeIntervalSince(lastTokenTime); lastTokenTime=now
        let rate=Double(subscription.bandwidth == 0 ? 100000 : subscription.bandwidth)*125
        tokens=min(max(65536,rate),tokens+elapsed*rate); drain()
        if inFlight.values.contains(where:{now.timeIntervalSince($0.1)>15}) { error("timeout","Viewer stopped acknowledging image updates"); close(); return }
        if server.fixture,!subscription.paused,!subscription.ids.isEmpty,now.timeIntervalSince(lastFixture) >= 1.0/Double(subscription.fps) {
            lastFixture=now; fixtureFrame+=1
            for id in subscription.ids {
                guard let d=server.displays.first(where:{$0.id == id}) else { continue }
                let s=scaledSize(d,preset:subscription.preset)
                if let image=fixtureImage(display:d,width:s.0,height:s.1,frame:fixtureFrame,denseMotion:server.fixtureDense) { acceptImage(image,display:d,revision:subscription.revision) }
            }
        }
        if !server.fixture,!subscription.paused,now.timeIntervalSince(lastCursorTime) >= 0.05 {
            lastCursorTime=now
            if let point=CGEvent(source:nil)?.location,let d=server.displays.first(where:{$0.bounds.contains(point)}),subscription.ids.contains(d.id),subscription.regions[d.id]?.isEmpty != true {
                let key="\(d.id):\(Int(point.x)):\(Int(point.y))"
                if key != lastCursorKey {
                    lastCursorKey=key
                    send(["type":"cursor","display":d.id,"x":(point.x-d.bounds.minX)/d.bounds.width,"y":(point.y-d.bounds.minY)/d.bounds.height])
                }
            }
        }
        if now.timeIntervalSince(lastStats) >= 1 {
            let count=Double(max(1,encodedInputs))
            send(["type":"stats","bytesSent":bytesSent,"fps":frameCounter,"streamingDisplays":subscription.paused ? [] : subscription.ids,"audio":subscription.audio,"quality":subscription.quality,"resolution":subscription.preset,
                  "encodedInputs":encodedInputs,"framesSkippedBackpressure":skippedFrames,"pendingImageBytes":pendingBytes,"inFlightFrames":inFlight.count,
                  "meanEncodeMs":encodingTotals.totalMilliseconds/count,"meanRasterMs":encodingTotals.rasterMilliseconds/count,"meanQuantizeMs":encodingTotals.quantizeMilliseconds/count,"meanDiffMs":encodingTotals.diffMilliseconds/count,"meanCodecMs":encodingTotals.codecMilliseconds/count])
            frameCounter=0;skippedFrames=0;encodedInputs=0;encodingTotals=EncodingMetrics();lastStats=now

        }
    }
    private var lastFixture=Date.distantPast
    private func handleInput(_ type: String,_ o: [String:Any]) {
        guard !subscription.paused,!subscription.viewOnly,!subscription.ids.isEmpty,!server.fixture else { return }
        if type == "key" { if let key=o["key"] as? Int,let down=o["down"] as? Bool { inputKeysym(key,down:down) };return }
        if type == "text" { if let text=o["text"] as? String,text.utf8.count <= 4096 { input.text(text) };return }
        guard let id=o["display"] as? String,subscription.ids.contains(id),let d=server.displays.first(where:{$0.id == id}),
              let x=o["x"] as? Double,let y=o["y"] as? Double,x.isFinite,y.isFinite,(0...1).contains(x),(0...1).contains(y) else { return }
        if type == "wheel" {
            guard let dx=o["dx"] as? Double,let dy=o["dy"] as? Double,dx.isFinite,dy.isFinite else { return }
            wheelRemainderX += max(-100,min(100,dx))*12
            wheelRemainderY += max(-100,min(100,dy))*12
            let pixelsX=Int(wheelRemainderX),pixelsY=Int(wheelRemainderY)
            wheelRemainderX-=Double(pixelsX);wheelRemainderY-=Double(pixelsY)
            if pixelsX != 0 || pixelsY != 0 { input.mouse(display:d,x:x,y:y,action:"wheel",button:0,modifiers:Array(heldModifiers),wheelX:pixelsX,wheelY:pixelsY) }
        } else {
            guard let mask=o["buttons"] as? Int,(0...7).contains(mask) else { return }
            input.mouse(display:d,x:x,y:y,action:"move",button:0,modifiers:Array(heldModifiers))
            for b in 0...2 where (mask & (1<<b)) != (buttonMask & (1<<b)) { input.mouse(display:d,x:x,y:y,action:mask & (1<<b) != 0 ? "down":"up",button:b,modifiers:Array(heldModifiers)) }
            buttonMask=mask
        }
    }
    private func inputKeysym(_ key: Int,down: Bool) {
        let special: [Int:String]=[0xff0d:"Enter",0xff1b:"Escape",0xff08:"Backspace",0xff09:"Tab",0xff51:"ArrowLeft",0xff52:"ArrowUp",0xff53:"ArrowRight",0xff54:"ArrowDown",0xffff:"Delete",0xff50:"Home",0xff57:"End",0xff55:"PageUp",0xff56:"PageDown",0xff63:"Insert",0xffe1:"ShiftLeft",0xffe2:"ShiftRight",0xffe3:"ControlLeft",0xffe4:"ControlRight",0xffe9:"AltLeft",0xffea:"AltRight",0xffeb:"MetaLeft",0xffec:"MetaRight",0xffe5:"CapsLock"]
        let mods: [Int:String]=[0xffe1:"shift",0xffe2:"shift",0xffe3:"control",0xffe4:"control",0xffe9:"alt",0xffea:"alt",0xffeb:"meta",0xffec:"meta"]
        if let modifier=mods[key] { if down { heldModifiers.insert(modifier) } else { heldModifiers.remove(modifier) } }
        if let code=special[key] { input.key(code:code,down:down,modifiers:Array(heldModifiers));return }
        if (0xffbe...0xffd1).contains(key) { input.key(code:"F\(key-0xffbe+1)",down:down,modifiers:Array(heldModifiers));return }
        let scalar=key & 0xff000000 == 0x01000000 ? key & 0x00ffffff : key
        guard let unicode=UnicodeScalar(scalar) else { return }
        let char=String(unicode)
        let lower=char.lowercased()
        var code: String?
        if lower.count == 1,let byte=lower.utf8.first,(97...122).contains(byte) { code="Key"+lower.uppercased() }
        else if (48...57).contains(scalar) { code="Digit"+char }
        else { code=[" ":"Space","-":"Minus","=":"Equal","[":"BracketLeft","]":"BracketRight","\\":"Backslash",";":"Semicolon","'":"Quote",",":"Comma",".":"Period","/":"Slash","`":"Backquote"][char] }
        if let code { var modifiers=heldModifiers;if char != lower { modifiers.insert("shift") };input.key(code:code,down:down,modifiers:Array(modifiers)) }
        else if down { input.text(char) }
    }
}
