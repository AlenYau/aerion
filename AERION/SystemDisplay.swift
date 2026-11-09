import SwiftUI

enum SDPage: String, CaseIterable {
    case elec = "ELEC", therm = "THERM", net = "NET", stor = "STOR", mem = "MEM", status = "STATUS"
}

struct SystemDisplay: View {
    let sampler: SamplingManager
    let preferences: Preferences
    private let size = Dashboard.size

    var body: some View {
        GeometryReader { geometry in
            let factor = min(geometry.size.width / size.width, geometry.size.height / size.height)
            ZStack(alignment: .topLeading) {
                SDPanel(page: preferences.systemPage, metrics: sampler.metrics)
                HStack(spacing: 6) {
                    ForEach(SDPage.allCases, id: \.self) { page in
                        Button {
                            preferences.systemPage = page
                        } label: {
                            let selected = preferences.systemPage == page
                            Text(page.rawValue)
                                .instrumentFont(12, weight: .semibold)
                                .foregroundStyle(selected ? EWDPalette.green : EWDPalette.white)
                                .frame(width: 69, height: 30)
                                .background(EWDPalette.white.opacity(0.05))
                                .overlay { Rectangle().strokeBorder(selected ? EWDPalette.green : EWDPalette.white.opacity(0.3)) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(preferences.systemPage == page ? .isSelected : [])
                    }
                }
                .position(x: 260, y: 504)
            }
            .frame(width: size.width, height: size.height)
            .scaledSurface(size, by: factor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(EWDPalette.screen)
        .ignoresSafeArea()
    }
}

private struct SDPanel: View {
    let page: SDPage
    let metrics: Metrics

    private let white = EWDPalette.white
    private let green = EWDPalette.green
    private let amber = EWDPalette.amber
    private let cyan = EWDPalette.cyan
    private var muted: Color { white.opacity(0.35) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            EWDPalette.screen
            label(page.rawValue, x: 260, y: 53, size: 23)
            tracks([Track([(212, 69), (308, 69)], white)])
            switch page {
            case .elec: electrical
            case .therm: thermal
            case .net: network
            case .stor: storage
            case .mem: memory
            case .status: status
            }
            footer
        }
    }

    private var electrical: some View {
        let battery = metrics.battery
        let ac = battery.externalPower == true
        let onBattery = battery.externalPower == false
        let charging = battery.charging == true
        let low = AlertLogic.evaluate(metrics).contains { $0.id == "battery" }
        return Group {
            tracks([
                Track([(147, 210), (147, 172), (260, 172), (260, 150)], ac ? green : muted),
                Track([(260, 172), (373, 172), (373, 208)], onBattery || charging ? green : muted, arrow: charging)
            ])
            node("SYSTEM SUPPLY", ac ? "AC POWER" : onBattery ? "BATTERY" : "N/A", x: 260, y: 120, color: ac || onBattery ? green : white)
            node("EXT PWR", ac ? "CONNECTED" : onBattery ? "DISCONNECTED" : "N/A", x: 147, y: 243,
                 color: ac ? green : white)
            node("BAT", battery.percent.map { "\($0) %" } ?? "N/A", x: 373, y: 243,
                 color: low ? amber : battery.percent == nil ? white : green)
            label(battery.chargingText, x: 373, y: 302,
                  color: low ? amber : battery.charging == nil ? white : green, size: 15)
        }
    }

    private var thermal: some View {
        let levels: [Thermal] = [.nominal, .fair, .serious, .critical]
        let active = metrics.thermal.flatMap { levels.firstIndex(of: $0) }
        let colors = [green, green, amber, EWDPalette.red]
        let scaleY: CGFloat = 246
        let markerX = active.map { CGFloat(83 + $0 * 118) }
        return Group {
            tracks([
                Track([(72, scaleY), (448, scaleY)], white)
            ] + (0..<4).map { index in
                let x = CGFloat(83 + index * 118)
                return Track([(x, scaleY - 9), (x, scaleY + 10)], active == index ? colors[index] : white)
            })
            node("THERMAL PRESSURE", metrics.thermal?.rawValue ?? "N/A", x: 260, y: 120,
                 width: 188, color: active.map { colors[$0] } ?? white)
            if let active, let markerX {
                tracks([Track([(260, 153), (260, 193), (markerX, 193), (markerX, scaleY - 13)],
                              colors[active], arrow: true)])
            }
            ForEach(levels.indices, id: \.self) { index in
                let x = CGFloat(83 + index * 118)
                label(levels[index].rawValue, x: x, y: 277, color: active == index ? colors[index] : white, size: 12)
            }
            label("macOS THERMAL STATE", x: 260, y: 325, color: cyan, size: 12)
        }
    }

    private var network: some View {
        let net = metrics.network
        let connected = [.wifi, .ethernet, .online].contains(net.state)
        let color = connected ? green : net.state == .unknown ? muted : amber
        return Group {
            tracks([
                Track([(260, 152), (260, 188)], color),
                Track([(219, 254), (219, 294), (148, 294), (148, 316)], color, arrow: connected),
                Track([(372, 316), (372, 294), (301, 294), (301, 254)], color, arrow: connected)
            ])
            node("NETWORK PATH", net.state.rawValue, x: 260, y: 120, width: 168, color: color)
            node("MEASURED INTERFACE", net.interface ?? "N/A", x: 260, y: 221, color: net.interface == nil ? white : green)
            node("RX  /  DOWN", ReadingFormat.rate(net.down), x: 148, y: 349, color: net.down == nil ? white : green)
            node("TX  /  UP", ReadingFormat.rate(net.up), x: 372, y: 349, color: net.up == nil ? white : green)
        }
    }

    private var storage: some View {
        let disk = metrics.disk
        let used = CGFloat(disk?.percent ?? 0) / 100
        let color = AlertLogic.evaluate(metrics).contains { $0.id == "disk" } ? amber : green
        let volumes = metrics.localVolumes ?? []
        return Group {
            label("HOME VOLUME", x: 260, y: 106, size: 13)
            label(metrics.volumeName ?? "N/A", x: 260, y: 129, color: disk == nil ? white : green, size: 17)
            tracks([
                Track([(73, 148), (447, 148), (447, 166), (73, 166), (73, 148)], white),
                Track([(74, 157), (74 + 372 * used, 157)], color, width: 13),
                Track([(132, 168), (132, 180), (132, 191)], white),
                Track([(388, 168), (388, 191)], white),
                Track([(50, 243), (470, 243)], white)
            ])
            label("USED", x: 132, y: 205, size: 12)
            label("AVAILABLE", x: 388, y: 205, size: 12)
            label(disk.map { ReadingFormat.disk($0.used) } ?? "N/A", x: 132, y: 225, color: disk == nil ? white : color)
            label(disk.map { ReadingFormat.disk($0.available) } ?? "N/A", x: 388, y: 225, color: disk == nil ? white : green)
            label(disk.map { "TOTAL " + ReadingFormat.disk($0.total) } ?? "TOTAL N/A",
                  x: 260, y: 218, color: cyan, size: 11)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("LOCAL MOUNTED VOLUMES")
                    Spacer()
                    Text("AVAILABLE").foregroundStyle(cyan)
                }
                .foregroundStyle(white)
                if volumes.isEmpty {
                    Text(metrics.localVolumes == nil ? "N/A" : "NO VISIBLE LOCAL VOLUMES").foregroundStyle(white)
                }
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach(Array(volumes.enumerated()), id: \.offset) { _, volume in
                            HStack {
                                Text(volume.name).foregroundStyle(green).lineLimit(1)
                                if let format = volume.format { Text(format).foregroundStyle(cyan).lineLimit(1) }
                                Spacer()
                                reading(volume.available.map(ReadingFormat.disk) ?? "N/A",
                                        color: volume.available == nil ? white : green).fixedSize()
                            }
                        }
                    }
                }
            }
            .instrumentFont(12, weight: .medium)
            .frame(width: 410, height: 157, alignment: .topLeading)
            .position(x: 260, y: 336)
        }
    }

    private var memory: some View {
        let pressure = metrics.memoryPressure
        let stateColor = pressure == .critical ? EWDPalette.red : pressure == .warning ? amber : pressure == .normal ? green : white
        let state = pressure == .critical ? "CRITICAL" : pressure == .warning ? "HIGH" : pressure == .normal ? "NORMAL" : "N/A"
        return Group {
            tracks([
                Track([(260, 152), (260, 181)], stateColor),
                Track([(260, 245), (260, 273), (143, 273), (143, 306)], white),
                Track([(260, 273), (377, 273), (377, 306)], white)
            ])
            node("MEM PRESSURE", state, x: 260, y: 120, width: 172, color: stateColor)
            node("RAM USED EST / TOTAL", metrics.memory.map {
                ReadingFormat.memory($0.used) + " / " + ReadingFormat.memory($0.total) + " GiB"
            } ?? "N/A", x: 260, y: 213, width: 224, color: metrics.memory == nil ? white : green)
            node("COMPRESSED IN RAM", memorySize(metrics.compressedBytes), x: 143, y: 338, width: 172,
                 color: metrics.compressedBytes == nil ? white : green)
            node("SWAP USED", memorySize(metrics.swap?.used), x: 377, y: 338, width: 172,
                 color: metrics.swap == nil ? white : green)
            label(metrics.swap.map { "SWAP ALLOC  " + memorySize($0.total) } ?? "SWAP ALLOC  N/A",
                  x: 377, y: 393, color: cyan, size: 11)
        }
    }

    private var status: some View {
        let alerts = AlertLogic.evaluate(metrics)
        let ready = metrics.cpu != nil && metrics.memory != nil && metrics.disk != nil
            && metrics.thermal != nil && metrics.network.state != .unknown
        let state = alerts.first.map { $0.level == .critical ? "WARNING" : $0.level == .caution ? "CAUTION" : "ADVISORY" }
        return Group {
            tracks([
                Track([(260, 152), (260, 180), (145, 180), (145, 202)], white),
                Track([(260, 180), (375, 180), (375, 202)], white),
                Track([(54, 286), (466, 286)], white)
            ])
            node("SYSTEM STATE", state ?? (ready ? "NORMAL" : "DATA PENDING"), x: 260, y: 120,
                 width: 184, color: alerts.first.map { ECAM.color($0.level) } ?? (ready ? green : white))
            node("CPU LOAD", metrics.cpu.map { ReadingFormat.percent($0) + " %" } ?? "N/A",
                 x: 145, y: 234, color: metrics.cpu == nil ? white : green)
            node("UPTIME", uptime, x: 375, y: 234, width: 164, color: metrics.uptimeSeconds == nil ? white : green)
            VStack(alignment: .leading, spacing: 6) {
                Text("ACTIVE MESSAGES").foregroundStyle(white)
                if alerts.isEmpty {
                    Text(ready ? "NO ACTIVE ALERTS" : "AWAITING SYSTEM DATA").foregroundStyle(ready ? green : white)
                }
                ForEach(alerts) { alert in
                    Text(alert.text).foregroundStyle(ECAM.color(alert.level))
                }
            }
            .instrumentFont(12, weight: .medium)
            .frame(width: 408, height: 119, alignment: .topLeading)
            .position(x: 260, y: 358)
        }
    }

    private var footer: some View {
        Group {
            tracks([Track([(34, 430), (486, 430)], white)])
            label("PWR", x: 62, y: 452, size: 11)
            label(metrics.battery.externalPower.map { $0 ? "AC" : "BAT" } ?? "N/A",
                  x: 99, y: 452, color: metrics.battery.externalPower == nil ? white : green, size: 12)
            label("THERM", x: 190, y: 452, size: 11)
            label(metrics.thermal?.rawValue ?? "N/A", x: 248, y: 452, color: thermalColor, size: 12)
            label("UP", x: 348, y: 452, size: 11)
            label(uptime, x: 424, y: 452, color: metrics.uptimeSeconds == nil ? white : green, size: 12)
        }
    }

    private var thermalColor: Color {
        switch metrics.thermal {
        case .critical: EWDPalette.red
        case .serious: amber
        case .nominal, .fair: green
        case nil: white
        }
    }

    private var uptime: String {
        guard let seconds = metrics.uptimeSeconds else { return "N/A" }
        let days = seconds / 86_400
        let clock = String(format: "%02d:%02d:%02d", seconds / 3600 % 24, seconds / 60 % 60, seconds % 60)
        return days > 0 ? "\(days)D " + clock : clock
    }

    private func memorySize(_ bytes: UInt64?) -> String {
        guard let bytes else { return "N/A" }
        if bytes < 1_073_741_824 {
            return String(format: "%.0f MiB", Double(bytes) / 1_048_576)
        }
        return ReadingFormat.memory(bytes) + " GiB"
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, color: Color = EWDPalette.white,
                       size: CGFloat = 15) -> some View {
        reading(text, color: color).instrumentFont(size, weight: .medium)
            .lineLimit(1).minimumScaleFactor(0.7)
            .position(x: x, y: y)
    }

    private func reading(_ text: String, color: Color) -> Text {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let unit = parts.last,
              ["%", "GB", "TB", "MiB", "GiB", "B/s", "kB/s", "MB/s"].contains(String(unit)) else {
            return Text(text).foregroundColor(color)
        }
        let number = text.dropLast(unit.count + 1)
        return Text(String(number)).foregroundColor(color) + Text(" " + unit).foregroundColor(cyan)
    }

    private func node(_ name: String, _ value: String, x: CGFloat, y: CGFloat, width: CGFloat = 148,
                      color: Color) -> some View {
        VStack(spacing: 6) {
            Text(name).instrumentFont(11, weight: .medium).foregroundStyle(white)
            reading(value, color: color).instrumentFont(16, weight: .medium)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .padding(.horizontal, 7)
        .frame(width: width, height: 64)
        .background(EWDPalette.screen)
        .overlay { Rectangle().strokeBorder(color.opacity(0.8), lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .position(x: x, y: y)
    }

    private struct Track {
        let points: [CGPoint]
        let color: Color
        let width: CGFloat
        let arrow: Bool

        init(_ coordinates: [(CGFloat, CGFloat)], _ color: Color, width: CGFloat = 1.25, arrow: Bool = false) {
            points = coordinates.map { CGPoint(x: $0.0, y: $0.1) }
            self.color = color
            self.width = width
            self.arrow = arrow
        }
    }

    private func tracks(_ tracks: [Track]) -> some View {
        Canvas { context, _ in
            for track in tracks {
                let path = Path { path in
                    path.addLines(track.points)
                    if track.arrow, let tip = track.points.last {
                        let prior = track.points[track.points.count - 2]
                        let angle = atan2(tip.y - prior.y, tip.x - prior.x)
                        path.move(to: CGPoint(x: tip.x - 8 * cos(angle - 0.5), y: tip.y - 8 * sin(angle - 0.5)))
                        path.addLine(to: tip)
                        path.addLine(to: CGPoint(x: tip.x - 8 * cos(angle + 0.5), y: tip.y - 8 * sin(angle + 0.5)))
                    }
                }
                context.stroke(path, with: .color(track.color), lineWidth: track.width)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
