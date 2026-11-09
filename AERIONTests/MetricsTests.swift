import XCTest
@testable import AERION

final class MetricsTests: XCTestCase {
    func testCPUUsesIntervalDeltasIncludingNiceTime() {
        let a = CPUTicks(user: 20, system: 10, idle: 60, nice: 10)
        let b = CPUTicks(user: 25, system: 13, idle: 70, nice: 12)
        XCTAssertEqual(b.load(since: a), 50)
        XCTAssertNil(a.load(since: a))
    }

    func testBatteryLabelsSeparatePowerSourceFromCharging() {
        let connected = Battery(percent: 29, charging: false, externalPower: true, present: true)
        XCTAssertEqual(connected.supplyText, "AC CONNECTED")
        XCTAssertEqual(connected.chargingText, "NOT CHARGING")

        let charging = Battery(percent: 29, charging: true, externalPower: true, present: true)
        XCTAssertEqual(charging.chargingText, "CHARGING")

        let disconnected = Battery(percent: 29, charging: false, externalPower: false, present: true)
        XCTAssertEqual(disconnected.supplyText, "ON BATTERY")
        XCTAssertEqual(disconnected.chargingText, "DISCHARGING")
    }

    func testCPUTickRollover() {
        let a = CPUTicks(user: .max - 1, system: 0, idle: 50, nice: 0)
        let b = CPUTicks(user: 2, system: 0, idle: 54, nice: 0)
        XCTAssertEqual(b.load(since: a), 50)
    }

    func testNetworkRateAndBaselineChanges() throws {
        let a = InterfaceCounters(name: "en0", received: 100, sent: 30, uptime: 10)
        let b = InterfaceCounters(name: "en0", received: 500, sent: 70, uptime: 12)
        let rates = try XCTUnwrap(b.rates(since: a))
        XCTAssertEqual(rates.down, 200)
        XCTAssertEqual(rates.up, 20)
        XCTAssertNil(a.rates(since: b))
        XCTAssertNil(a.rates(since: a))
        XCTAssertNil(InterfaceCounters(name: "en1", received: 500, sent: 70, uptime: 12).rates(since: a))
        XCTAssertNil(InterfaceCounters(name: "en0", received: 1, sent: 2, uptime: 12).rates(since: a))
    }

    func testUnknownReadingsAndMockNormalReadingsDoNotRaiseAlerts() {
        XCTAssertTrue(AlertLogic.evaluate(Metrics()).isEmpty)
        XCTAssertTrue(AlertLogic.evaluate(MockMetricsProvider().sample()).isEmpty)
    }

    func testAlertPriorityAndACSuppression() {
        var reading = MockMetricsProvider.preview
        reading.thermal = .critical
        reading.battery = Battery(percent: 20, charging: false, externalPower: false, present: true)
        reading.disk = Capacity(used: 98_000_000_000, total: 100_000_000_000)
        reading.network.state = .offline
        XCTAssertEqual(AlertLogic.evaluate(reading).map(\.id), ["thermal", "battery", "disk", "network"])
        XCTAssertEqual(AlertLogic.evaluate(reading).map(\.level), [.critical, .caution, .caution, .advisory])
        reading.battery = Battery(percent: 20, charging: false, externalPower: true, present: true)
        XCTAssertEqual(AlertLogic.evaluate(reading).map(\.id), ["thermal", "disk", "network"])
    }

    @MainActor
    func testPreferencesPersistAcrossInstances() {
        let name = "AERIONTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = Preferences(defaults: defaults)
        XCTAssertEqual(first.interval, 2)
        first.systemPage = .mem
        first.interval = 0.5
        first.scale = 1.15
        first.showDetails = false
        first.floatingOnTop = false
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.interval, 0.5)
        XCTAssertEqual(reloaded.systemPage, .mem)
        defaults.set(1, forKey: "interval")
        XCTAssertEqual(Preferences(defaults: defaults).interval, 0.5)
        XCTAssertEqual(defaults.double(forKey: "interval"), 0.5)
        XCTAssertEqual(reloaded.scale, 1.15)
        XCTAssertFalse(reloaded.showDetails)
        XCTAssertFalse(reloaded.floatingOnTop)
    }

    func testLiveProviderReturnsValidMachineReadings() throws {
        let provider = SystemMetricsProvider()
        XCTAssertNil(provider.sample().cpu)
        Thread.sleep(forTimeInterval: 0.35)
        let reading = provider.sample()
        XCTAssertTrue((0...100).contains(try XCTUnwrap(reading.cpu)))
        XCTAssertEqual(try XCTUnwrap(reading.memory).total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(try XCTUnwrap(reading.disk).total, 0)
        XCTAssertNotNil(reading.thermal)
        XCTAssertNotNil(reading.compressedBytes)
        XCTAssertGreaterThan(try XCTUnwrap(reading.uptimeSeconds), 0)
    }
}

extension MetricsTests {
    @MainActor
    func testMemoryPressureEventsAndMemoRecovery() {
        var reading = MockMetricsProvider.preview
        reading.memoryPressure = MemoryPressure(event: [])
        XCTAssertNil(reading.memoryPressure)
        XCTAssertEqual(EWDMemo(metrics: reading).columns[1][0].text, "MEM PRESSURE N/A")

        reading.memoryPressure = MemoryPressure(event: .warning)
        XCTAssertEqual(AlertLogic.evaluate(reading).first?.level, .caution)
        XCTAssertEqual(EWDMemo(metrics: reading).columns[1][0].text, "MEM PRESSURE HIGH")

        reading.memoryPressure = MemoryPressure(event: [.normal, .critical])
        XCTAssertEqual(AlertLogic.evaluate(reading).first?.level, .critical)
        XCTAssertEqual(EWDMemo(metrics: reading).columns[1][0].text, "MEM PRESSURE CRITICAL")

        reading.memoryPressure = MemoryPressure(event: .normal)
        XCTAssertTrue(AlertLogic.evaluate(reading).isEmpty)
        XCTAssertEqual(EWDMemo(metrics: reading).columns[1][0].text, "MEM PRESSURE NORMAL")
    }

    func testScalePositionsForMinimumMidpointAndMaximum() {
        let scale = EWDScale(radius: 50, start: 180, sweep: 180)
        XCTAssertEqual(scale.point(0).x, -50, accuracy: 0.0001)
        XCTAssertEqual(scale.point(0.5).y, -50, accuracy: 0.0001)
        XCTAssertEqual(scale.point(1).x, 50, accuracy: 0.0001)
    }
}
