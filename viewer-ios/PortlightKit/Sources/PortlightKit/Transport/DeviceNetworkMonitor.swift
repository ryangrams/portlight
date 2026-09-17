import Foundation
import Network

/// Whether this device can use any network at all: the system-wide path, not the path to one computer.
/// URLSession reports "no usable network" (-1009, an unsatisfied path, ENETDOWN) both when the device is offline and
/// when only the route to one address is missing, such as a VPN-only address while the VPN is off. This tells the two
/// apart. It is `unknown` until the system's first path update.
enum DeviceNetwork: Sendable, Equatable {
    case unknown, available, unavailable
}

/// One process-wide `NWPathMonitor`, started on first use and never stopped. Reads are lock-protected snapshots.
final class DeviceNetworkMonitor: @unchecked Sendable {
    // Invariant for @unchecked Sendable: `latest` and `started` are only touched under `lock`; `monitor` and `queue`
    // are immutable after init.
    static let shared = DeviceNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "studio.upgrade.portlight.device-network")
    private let lock = NSLock()
    private var latest = DeviceNetwork.unknown
    private var started = false

    var status: DeviceNetwork { lock.withLock { latest } }

    /// Idempotent.
    func start() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let status = Self.status(of: path.status)
            self?.lock.withLock { self?.latest = status }
        }
        monitor.start(queue: queue)
    }

    static func status(of status: NWPath.Status) -> DeviceNetwork {
        switch status {
        case .satisfied: return .available
        case .unsatisfied: return .unavailable
        // Usable once a connection brings it up (an on-demand VPN, dormant cellular): not known to be offline.
        case .requiresConnection: return .unknown
        @unknown default: return .unknown
        }
    }
}
