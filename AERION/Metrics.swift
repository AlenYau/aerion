import Dispatch
import Foundation

struct Capacity: Equatable, Sendable {
    let used: UInt64
    let total: UInt64
    var available: UInt64 { total - used }
    var percent: Double { Double(used) / Double(total) * 100 }
}

struct Battery: Equatable, Sendable {
    let percent: Int?
    let charging: Bool?
    let externalPower: Bool?
    let present: Bool?
}

enum LinkState: String, Equatable, Sendable {
    case unknown = "N/A", offline = "OFFLINE", requiresConnection = "ON DEMAND"
    case wifi = "WI-FI", ethernet = "ETHERNET", online = "ONLINE"
}

struct NetworkReading: Equatable, Sendable {
    var state: LinkState = .unknown
    var interface: String?
    var down: Double?
    var up: Double?
}

enum Thermal: String, Equatable, Sendable {
    case nominal = "NOMINAL", fair = "FAIR", serious = "SERIOUS", critical = "CRITICAL"
}

enum MemoryPressure: Equatable, Sendable {
    case normal, warning, critical

    init?(event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) { self = .critical }
        else if event.contains(.warning) { self = .warning }
        else if event.contains(.normal) { self = .normal }
        else { return nil }
    }
}

struct StorageVolume: Equatable, Sendable {
    let name: String
    let format: String?
    let available: UInt64?
}

struct Metrics: Equatable, Sendable {
    var cpu: Double?
    var memory: Capacity?
    var battery = Battery(percent: nil, charging: nil, externalPower: nil, present: nil)
    var disk: Capacity?
    var network = NetworkReading()
    var thermal: Thermal?
    var memoryPressure: MemoryPressure?
    var compressedBytes: UInt64?
    var swap: Capacity?
    var volumeName: String?
    var localVolumes: [StorageVolume]?
    var uptimeSeconds: Int?
}

protocol MetricsProvider: AnyObject, Sendable {
    // Calls are serialized by the sampling queue.
    func sample() -> Metrics
    func resetBaselines()
}

final class MockMetricsProvider: MetricsProvider {
    let reading: Metrics
    init(_ reading: Metrics = MockMetricsProvider.preview) { self.reading = reading }
    func sample() -> Metrics { reading }
    func resetBaselines() {}

    static let preview = Metrics(
        cpu: 27.4,
        memory: Capacity(used: 5_154_000_000, total: 8_589_934_592),
        battery: Battery(percent: 82, charging: false, externalPower: false, present: true),
        disk: Capacity(used: 156_000_000_000, total: 245_000_000_000),
        network: NetworkReading(state: .wifi, interface: "en0", down: 84_000, up: 6_200),
        thermal: .nominal, memoryPressure: .normal
    )
}

enum AlertLevel: Int {
    case advisory, caution, critical
}

struct Alert: Equatable, Identifiable {
    let id: String
    let text: String
    let level: AlertLevel
}

enum AlertLogic {
    static func evaluate(_ metrics: Metrics) -> [Alert] {
        var alerts: [Alert] = []
        if metrics.thermal == .critical {
            alerts.append(Alert(id: "thermal", text: "THERM · CRITICAL SYSTEM PRESSURE", level: .critical))
        } else if metrics.thermal == .serious {
            alerts.append(Alert(id: "thermal", text: "THERM · ELEVATED SYSTEM PRESSURE", level: .caution))
        }
        if metrics.memoryPressure == .critical {
            alerts.append(Alert(id: "memory", text: "MEM PRESSURE CRITICAL", level: .critical))
        } else if metrics.memoryPressure == .warning {
            alerts.append(Alert(id: "memory", text: "MEM PRESSURE HIGH", level: .caution))
        }
        if metrics.battery.externalPower == false,
           let percent = metrics.battery.percent, percent <= 20 {
            alerts.append(Alert(id: "battery", text: "BAT · LOW CHARGE  /  \(percent)%", level: .caution))
        }
        if let disk = metrics.disk, disk.available <= 5_000_000_000, disk.percent >= 95 {
            alerts.append(Alert(id: "disk", text: "DISK · LOW AVAILABLE CAPACITY", level: .caution))
        }
        if metrics.network.state == .offline {
            alerts.append(Alert(id: "network", text: "NET · NO AVAILABLE PATH", level: .advisory))
        }
        // Preserve insertion order among alerts with equal severity.
        return alerts.sorted { $0.level.rawValue > $1.level.rawValue }
    }
}

struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func load(since previous: Self) -> Double? {
        let busy = UInt64(user &- previous.user) + UInt64(system &- previous.system)
            + UInt64(nice &- previous.nice)
        let total = busy + UInt64(idle &- previous.idle)
        return total == 0 ? nil : 100 * Double(busy) / Double(total)
    }
}

struct InterfaceCounters {
    let name: String
    let received: UInt64
    let sent: UInt64
    let uptime: TimeInterval

    func rates(since previous: Self) -> (down: Double, up: Double)? {
        let elapsed = uptime - previous.uptime
        guard name == previous.name, elapsed > 0, received >= previous.received,
              sent >= previous.sent else { return nil }
        return (Double(received - previous.received) / elapsed, Double(sent - previous.sent) / elapsed)
    }
}
