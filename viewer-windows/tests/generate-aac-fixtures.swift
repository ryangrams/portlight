import Foundation
@main struct Fixture {
  static func main() throws {
    var fixtures:[[String:Any]]=[]
    for bitrate in [48000,96000,160000,320000] {
      guard let encoder=AACEncoder(bitrate:bitrate) else {fatalError("AAC encoder unavailable")}
      var packets:[String]=[]
      for block in 0..<12 {
        var values=[Int16](repeating:0,count:1024*encoder.channels)
        for i in 0..<1024 {for channel in 0..<encoder.channels { values[i*encoder.channels+channel]=Int16(sin(Double(block*1024+i)*2*Double.pi*Double(440+channel*220)/48000)*4000) }}
        if let packet=encoder.encode(values.withUnsafeBytes{Data($0)}){packets.append(packet.base64EncodedString())}
      }
      guard let decoder=AACDecoder(channels:encoder.channels,cookie:encoder.cookie) else{fatalError("AAC decoder unavailable")}
      var samples=0
      for encoded in packets {if let pcm=decoder.decode(Data(base64Encoded:encoded)!){samples+=Int(pcm.frameLength)}}
      guard samples>=8192 else{fatalError("Fixture round trip failed")}
      fixtures.append(["bitrate":bitrate,"channels":encoder.channels,"cookie":encoder.cookie.base64EncodedString(),"packets":packets,"decodedSamplesOnMac":samples])
    }
    let data=try JSONSerialization.data(withJSONObject:fixtures,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  }
}
