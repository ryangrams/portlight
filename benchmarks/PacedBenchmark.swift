import AppKit
import Foundation

// This is an explicitly simulated transport schedule around real encoder calls.
// It mirrors the host's token bucket, max-four-ACK window, and drop-before-encode
// rule, allowing equal input frame times/caps/ACK delay for every color mode.
@main struct PacedBenchmark {
    static func main() throws {
        let width=1920,height=1080,fps=15.0,duration=10.0,rate=500_000.0,ackDelay=0.020
        var rows:[[String:Any]]=[]
        for scenario in ["text_ui","static_ui","gradients","noise","motion"] {
            let first=workload(scenario,0,width,height)
            let images=(0..<12).map { scenario == "static_ui" ? first : workload(scenario,$0,width,height) }
            for mode in ["gray16","color256","rgb565","full"] { for variant in ["baseline","optimized"] {
                let old=BaselineTileEncoder(),new=TileEncoder()
                let packetWindow=variant == "baseline" ? 4 : 32
                var now=0.0,lastTokens=0.0,tokens=rate,nextInput=0,inputIndex=0
                var outbound:[Int]=[],inFlight:[(Double,Int)]=[],framePending=false
                var transmitted=0,completedFrames=0,encodedInputs=0,droppedInputs=0,encodedMS=0.0,cpuMS=0.0
                var initialCompletedAt:Double?=nil
                func pump(_ at:Double) {
                    tokens=min(rate,tokens+(at-lastTokens)*rate);lastTokens=at
                    inFlight.removeAll{$0.0<=at}
                    if framePending && outbound.isEmpty && inFlight.isEmpty { completedFrames+=1;framePending=false;if initialCompletedAt == nil { initialCompletedAt=at } }
                    while !outbound.isEmpty && inFlight.count<packetWindow {
                        let bytes=outbound[0]
                        if variant == "optimized" && !inFlight.isEmpty && inFlight.reduce(0,{$0+$1.1})+bytes > 2*1024*1024 { break }
                        guard tokens>=Double(bytes) || (tokens>0 && Double(bytes)>rate) else { break }
                        outbound.removeFirst();tokens-=Double(bytes);transmitted+=bytes;inFlight.append((at+ackDelay,bytes))
                    }
                }
                while now<duration {
                    pump(now)
                    if Double(nextInput)/fps<=now {
                        inputIndex=nextInput;nextInput+=1
                        if framePending { droppedInputs+=1;continue }
                        let start=cpuTime()
                        let tiles:[EncodedTile],timings:EncodingMetrics
                        if variant == "baseline" { tiles=old.encode(images[inputIndex%images.count],region:CGRect(x:0,y:0,width:1,height:1),color:mode,quality:0.7,motion:false);timings=old.metrics }
                        else { tiles=new.encode(images[inputIndex%images.count],region:CGRect(x:0,y:0,width:1,height:1),color:mode,quality:0.7,motion:false);timings=new.metrics }
                        cpuMS+=(cpuTime()-start)*1000;encodedMS+=timings.totalMilliseconds;encodedInputs+=1
                        now+=timings.totalMilliseconds/1000
                        // Actual packet-header JSON length, excluding TLS/TCP overhead.
                        outbound=tiles.map { tile in
                            let h:[String:Any]=["type":"frame","revision":1,"display":"benchmark","x":tile.x,"y":tile.y,"width":tile.width,"height":tile.height,"canvasWidth":width,"canvasHeight":height,"codec":tile.codec,"sequence":1]
                            return tile.data.count+4+(try! JSONSerialization.data(withJSONObject:h)).count
                        }
                        framePending = !outbound.isEmpty
                        let missed=max(0,Int(floor(now*fps))-nextInput)
                        droppedInputs+=missed;nextInput+=missed
                        pump(now)
                    } else { now=min(duration,now+0.001) }
                }
                let row:[String:Any]=["workload":scenario,"mode":mode,"variant":variant,"maxInFlightPackets":packetWindow,"completedImageUpdates":completedFrames,"completedUpdatesPerSecond":Double(completedFrames)/duration,
                     "sentBytes":transmitted,"meanSentKbps":Double(transmitted)*8/duration/1000,"encodedInputs":encodedInputs,"droppedInputs":droppedInputs,
                     "encoderWallMs":encodedMS,"encoderCpuMs":cpuMS,"initialImageSeconds":initialCompletedAt ?? -1]
                rows.append(row)
                fputs("Paced \(scenario) \(mode) \(variant): \(row["completedUpdatesPerSecond"]!) updates/s\n",stderr)
            } }
        }
        let result:[String:Any]=["schema":1,"kind":"measured encoder with simulated transport schedule","width":width,"height":height,"inputFps":fps,"durationSeconds":duration,"appBandwidthKbps":4000,"simulatedAckRoundTripMs":ackDelay*1000,"baselinePacketWindow":4,"optimizedPacketWindow":32,"optimizedInFlightByteLimit":2097152,"initialBurstBytes":rate,
               "limitations":"Not a real-link or viewer benchmark. Identical precomputed frames, real encoder timings/payloads, deterministic token-bucket/ACK scheduling. Excludes capture, decode, TLS/TCP serialization and network loss. Reported updates are complete changed images; static images legitimately have no updates after the initial frame.","results":rows]
        let path=CommandLine.arguments.dropFirst().first ?? "benchmarks/results/paced-1080p.json"
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
    }
}
