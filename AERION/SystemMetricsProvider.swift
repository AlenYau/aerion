import Darwin
import Foundation
import IOKit.ps
import Network
import os

// Sampling state is confined to the serial sampling queue. Network.framework publishes
// its path on a separate queue through latestPath.
final class SystemMetricsProvider: MetricsProvider, @unchecked Sendable {
    private let host = mach_host_self()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "aerion.network-path", qos: .utility)
    private let latestPath = OSAllocatedUnfairLock<NWPath?>(initialState: nil)
    private let pressure = OSAllocatedUnfairLock<MemoryPressure?>(initialState: nil)
    private let pressureSource = DispatchSource.makeMemoryPressureSource(
        eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility)
    )
    private var previousCPU: CPUTicks?
    private var previousNetwork: InterfaceCounters?
    private var lastDiskRead: TimeInterval?
    private var disk: Capacity?
    private var volumeName: String?
    private var localVolumes: [StorageVolume]?
    private var swap: Capacity?
    private var lastSwapRead: TimeInterval?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        pathMonitor.pathUpdateHandler = { [latestPath] path in latestPath.withLock { $0 = path } }
        pathMonitor.start(queue: pathQueue)
        pressureSource.setEventHandler { [weak self] in
            guard let self, let state = MemoryPressure(event: pressureSource.data) else { return }
            pressure.withLock { $0 = state }
        }
        pressureSource.activate()
    }

    deinit {
        pressureSource.cancel()
        pathMonitor.cancel()
        mach_port_deallocate(mach_task_self_, host)
    }

    func resetBaselines() {
        previousCPU = nil
        previousNetwork = nil
        lastDiskRead = nil
        lastSwapRead = nil
    }

    func sample() -> Metrics {
        let uptime = ProcessInfo.processInfo.systemUptime
        if lastDiskRead.map({ uptime - $0 >= 15 }) ?? true {
            readStorage()
            lastDiskRead = uptime
        }
        if lastSwapRead.map({ uptime - $0 >= 2 }) ?? true {
            swap = readSwap()
            lastSwapRead = uptime
        }
        let memory = readMemory()
        return Metrics(cpu: readCPU(), memory: memory?.capacity, battery: readBattery(),
                       disk: disk, network: readNetwork(), thermal: readThermal(),
                       memoryPressure: pressure.withLock { $0 }, compressedBytes: memory?.compressed,
                       swap: swap, volumeName: volumeName, localVolumes: localVolumes,
                       uptimeSeconds: Int(uptime))
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            previousCPU = nil
            return nil
        }
        let ticks = info.cpu_ticks
        let current = CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
        defer { previousCPU = current }
        return previousCPU.flatMap { current.load(since: $0) }
    }

    private func readMemory() -> (capacity: Capacity, compressed: UInt64)? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, total > 0 else { return nil }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let pageSize = UInt64(vm_kernel_page_size)
        return (Capacity(used: min(pages * pageSize, total), total: total),
                UInt64(info.compressor_page_count) * pageSize)
    }

    private func readBattery() -> Battery {
        let unknown = Battery(percent: nil, charging: nil, externalPower: nil, present: nil)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() else { return unknown }
        let power = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let externalPower: Bool?
        switch power {
        case kIOPSACPowerValue: externalPower = true
        case kIOPSBatteryPowerValue: externalPower = false
        default: externalPower = nil
        }
        var descriptionsComplete = true
        for source in sources as [AnyObject] {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else {
                descriptionsComplete = false
                continue
            }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool != false else { continue }
            var percent: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               current >= 0, maximum > 0 {
                percent = Int((100 * min(1, Double(current) / Double(maximum))).rounded())
            }
            return Battery(percent: percent, charging: description[kIOPSIsChargingKey] as? Bool,
                           externalPower: externalPower, present: true)
        }
        return Battery(percent: nil, charging: nil, externalPower: externalPower,
                       present: descriptionsComplete ? false : nil)
    }

    private func readStorage() {
        let homeURL = URL(fileURLWithPath: home.path, isDirectory: true)
        let values = try? homeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])
        volumeName = values?.volumeName
        if let total = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacity,
           total > 0, available >= 0, available <= total {
            disk = Capacity(used: UInt64(total - available), total: UInt64(total))
        } else {
            disk = nil
        }

        // Identify local volumes before requesting capacity, which can block on remote mounts.
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]
        localVolumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey],
                                                              options: [.skipHiddenVolumes])?.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true else { return nil }
            let volume = try? url.resourceValues(forKeys: keys)
            let available = volume?.volumeAvailableCapacity.flatMap { UInt64(exactly: $0) }
            return StorageVolume(name: volume?.volumeName ?? url.lastPathComponent,
                                 format: volume?.volumeLocalizedFormatDescription, available: available)
        }
    }

    private func readSwap() -> Capacity? {
        var info = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &info, &size, nil, 0) == 0,
              size == MemoryLayout<xsw_usage>.size, info.xsu_used <= info.xsu_total else { return nil }
        return Capacity(used: info.xsu_used, total: info.xsu_total)
    }

    private func readNetwork() -> NetworkReading {
        guard let path = latestPath.withLock({ $0 }) else { return NetworkReading() }
        guard path.status == .satisfied else {
            previousNetwork = nil
            switch path.status {
            case .requiresConnection: return NetworkReading(state: .requiresConnection)
            case .unsatisfied: return NetworkReading(state: .offline)
            default: return NetworkReading()
            }
        }
        let state: LinkState
        if path.usesInterfaceType(.wifi) { state = .wifi }
        else if path.usesInterfaceType(.wiredEthernet) { state = .ethernet }
        else { state = .online }

        let interface = path.availableInterfaces.first { path.usesInterfaceType($0.type) }
        let counters = interface.flatMap { readCounters(for: $0.name) }
        let rates = previousNetwork.flatMap { previous in counters?.rates(since: previous) }
        previousNetwork = counters
        return NetworkReading(state: state, interface: interface?.name, down: rates?.down, up: rates?.up)
    }

    private func readCounters(for name: String) -> InterfaceCounters? {
        let index = name.withCString { if_nametoindex($0) }
        guard index != 0 else { return nil }
        var query: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        let queryCount = UInt32(query.count)
        var length = 0
        guard sysctl(&query, queryCount, nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }
        var data = Data(count: length)
        return data.withUnsafeMutableBytes { buffer -> InterfaceCounters? in
            guard sysctl(&query, queryCount, buffer.baseAddress, &length, nil, 0) == 0,
                  length <= buffer.count else { return nil }
            var offset = 0
            while length - offset >= 4 {
                let messageLength = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength >= 4, messageLength <= length - offset else { return nil }
                if buffer[offset + 3] == UInt8(RTM_IFINFO2),
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_index == index {
                        return InterfaceCounters(name: name, received: message.ifm_data.ifi_ibytes,
                                                 sent: message.ifm_data.ifi_obytes,
                                                 uptime: ProcessInfo.processInfo.systemUptime)
                    }
                }
                offset += messageLength
            }
            return nil
        }
    }

    private func readThermal() -> Thermal? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: nil
        }
    }
}
