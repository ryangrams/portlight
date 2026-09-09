import Foundation
import AppKit

struct RemoteMonitor: Codable, Equatable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    var number: Int = 0
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var label: String { "\(number > 0 ? String(number) + " · " : "")\(name)" }
    var size: CGSize { CGSize(width: frameWidth > 0 ? frameWidth : width, height: frameHeight > 0 ? frameHeight : height) }
}

enum Resolution: String, CaseIterable, Codable {
    case native, hd, fhd, qhd, uhd
    var label: String {
        switch self { case .native: return "Native"; case .hd: return "HD · 720p"; case .fhd: return "FHD · 1080p"; case .qhd: return "QHD · 1440p"; case .uhd: return "UHD · 2160p" }
    }
    var dimensions: CGSize {
        switch self { case .native: return .zero; case .hd: return CGSize(width:1280,height:720); case .fhd: return CGSize(width:1920,height:1080); case .qhd: return CGSize(width:2560,height:1440); case .uhd: return CGSize(width:3840,height:2160) }
    }
    func supports(_ monitor: RemoteMonitor) -> Bool {
        if self == .native { return true }
        return max(monitor.width,monitor.height) >= Int(dimensions.width) && min(monitor.width,monitor.height) >= Int(dimensions.height)
    }
    func outputSize(_ monitor: RemoteMonitor) -> CGSize {
        if self == .native { return Resolution.uhd.outputSize(monitor) }
        let box = monitor.width >= monitor.height ? dimensions : CGSize(width:dimensions.height,height:dimensions.width)
        let scale = min(1, min(box.width / Double(monitor.width), box.height / Double(monitor.height)))
        return CGSize(width:max(1,Int(Double(monitor.width) * scale)),height:max(1,Int(Double(monitor.height) * scale)))
    }
}

struct ViewPreset: Codable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var monitors: [String]
    var resolution: String
    var color: String
    var quality: String
    var bandwidthKbps: Int
    var fps: Int
    var zoom: Double
    var follow: Bool
    var viewOnly: Bool
    var fullScreen: Bool
    var zeroTierNetwork: String?
    var zeroTierManaged: [String]?
}

final class PresetStore {
    private let key = "SU.Remote.Presets.v1"
    var presets: [ViewPreset] {
        get { guard let data = UserDefaults.standard.data(forKey:key) else { return [] }; return (try? JSONDecoder().decode([ViewPreset].self,from:data)) ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data,forKey:key) } }
    }
    func save(_ preset: ViewPreset) { var list = presets; if let i = list.firstIndex(where:{$0.id == preset.id}) { list[i] = preset } else { list.append(preset) }; presets = list }
}

func validPort(_ text: String) -> Int? { guard let value = Int(text), (1...65535).contains(value) else { return nil }; return value }
func jsonString(_ value: Any) -> String? { guard let data = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else { return nil }; return String(data:data,encoding:.utf8) }
func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(upper,max(lower,value)) }

let maxViewerCanvasPixels:Double = 33_177_600
func validCanvasDimensions(width:Int,height:Int) -> Bool {
    width > 0 && height > 0 && max(width,height) <= 3840 && min(width,height) <= 2160 && Double(width)*Double(height) <= 8_294_400
}
