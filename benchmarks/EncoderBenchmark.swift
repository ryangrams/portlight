import AppKit
import Foundation
import Darwin

@main struct EncoderBenchmark {
    static func main() throws {
        let args=CommandLine.arguments
        func argument(_ name:String,_ fallback:String)->String { guard let i=args.lastIndex(of:name),i+1<args.count else { return fallback };return args[i+1] }
        let width=Int(argument("--width","1920"))!,height=Int(argument("--height","1080"))!,frameCount=Int(argument("--frames","12"))!,repeats=Int(argument("--repeats","3"))!
        let output=argument("--output","benchmarks/results/encoder.json")
        var rows:[[String:Any]]=[]
        for scenario in ["text_ui","static_ui","gradients","noise","motion"] {
            let first=workload(scenario,0,width,height)
            let images=(0..<frameCount).map { scenario == "static_ui" ? first : workload(scenario,$0,width,height) }
            for mode in ["gray16","color256","rgb565","full"] {
                for variant in ["baseline","optimized"] {
                    var samples:[Sample]=[],cpus:[Double]=[],pngTypes=Set<String>(),allPayloads=0
                    for _ in 0..<repeats {
                        let old=BaselineTileEncoder(),new=TileEncoder()
                        // Warm framework initialization before measurement, but retain a cold display encoder.
                        _=TileEncoder().encode(first,region:CGRect(x:0,y:0,width:1,height:1),color:mode,quality:0.7,motion:false)
                        let cpuStart=cpuTime()
                        for image in images {
                            let tiles:[EncodedTile],metrics:EncodingMetrics
                            if variant == "baseline" { tiles=old.encode(image,region:CGRect(x:0,y:0,width:1,height:1),color:mode,quality:0.7,motion:false);metrics=old.metrics }
                            else { tiles=new.encode(image,region:CGRect(x:0,y:0,width:1,height:1),color:mode,quality:0.7,motion:false);metrics=new.metrics }
                            let bytes=tiles.reduce(0){$0+$1.data.count}
                            samples.append(Sample(metrics:metrics,bytes:bytes,tiles:tiles.count));allPayloads+=bytes
                            for tile in tiles where tile.codec == "png" && tile.data.count > 25 { pngTypes.insert("depth\(tile.data[24])-type\(tile.data[25])") }
                        }
                        cpus.append((cpuTime()-cpuStart)*1000/Double(frameCount))
                    }
                    let means=Double(samples.count)
                    let row:[String:Any]=["workload":scenario,"mode":mode,"variant":variant,"frames":samples.count,
                      "medianMs":median(samples.map{$0.metrics.totalMilliseconds}),"p95Ms":percentile(samples.map{$0.metrics.totalMilliseconds},0.95),
                      "meanRasterMs":samples.reduce(0){$0+$1.metrics.rasterMilliseconds}/means,"meanQuantizeMs":samples.reduce(0){$0+$1.metrics.quantizeMilliseconds}/means,
                      "meanDiffMs":samples.reduce(0){$0+$1.metrics.diffMilliseconds}/means,"meanCodecMs":samples.reduce(0){$0+$1.metrics.codecMilliseconds}/means,
                      "cpuMsPerFrame":median(cpus),"payloadBytes":allPayloads/repeats,"meanBytesPerInputFrame":Double(allPayloads)/means,
                      "meanTilesPerInputFrame":samples.reduce(0.0){$0+Double($1.tiles)}/means,"pngFormats":pngTypes.sorted()]
                    rows.append(row)
                    fputs("\(scenario) \(mode) \(variant): \(row["medianMs"]!)ms \(row["meanBytesPerInputFrame"]!)B/frame\n",stderr)
                }
            }
        }
        var cpu=[CChar](repeating:0,count:256);var size=cpu.count
        sysctlbyname("machdep.cpu.brand_string",&cpu,&size,nil,0)
        let result:[String:Any]=["schema":1,"machine":String(cString:cpu),"os":ProcessInfo.processInfo.operatingSystemVersionString,"width":width,"height":height,"framesPerRun":frameCount,"repeats":repeats,"policy":"desktop","jpegQuality":0.7,"note":"Same precomputed source frames for all modes. Encoder CPU/wall time excludes workload generation, capture, network, viewer decode. Payload includes PNG/JPEG only.","results":rows]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
    }
}
