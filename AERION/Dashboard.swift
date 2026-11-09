import SwiftUI

struct Dashboard: View {
    let sampler: SamplingManager
    let preferences: Preferences
    static let size = CGSize(width: 520, height: 536)

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Self.size.width, geometry.size.height / Self.size.height)
            EWDDisplay(metrics: sampler.metrics, showDetails: preferences.showDetails)
                .scaledSurface(Self.size, by: scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(EWDPalette.screen)
        .ignoresSafeArea()
    }
}

private struct EWDDisplay: View {
    let metrics: Metrics
    let showDetails: Bool
    private let mainScale = EWDScale(radius: 78, start: 148, sweep: 222)
    private let secondaryScale = EWDScale(radius: 57, start: 163, sweep: 197)

    var body: some View {
        ZStack(alignment: .topLeading) {
            EWDPalette.screen
            EWDGauge(title: "CPU LOAD", accessibilityTitle: "CPU load", value: metrics.cpu,
                     scale: mainScale, digits: 1, limit: 0.9...1, limitColor: EWDPalette.amber)
                .position(x: 151, y: 126)
            EWDGauge(title: "MEM USAGE", accessibilityTitle: "Estimated physical memory usage",
                     value: metrics.memory?.percent, scale: mainScale, digits: 1,
                     limit: 0.9...1, limitColor: EWDPalette.amber)
                .position(x: 369, y: 126)
            axis("UTIL", unit: "%").position(x: 260, y: 127)
            EWDGauge(title: "BAT REM", accessibilityTitle: "Battery remaining",
                     value: metrics.battery.percent.map(Double.init), scale: secondaryScale, digits: 0,
                     limit: 0...0.05, limitColor: EWDPalette.red)
                .position(x: 151, y: 237)
            EWDGauge(title: "DISK USED", accessibilityTitle: "Disk used", value: metrics.disk?.percent,
                     scale: secondaryScale, digits: 0, limit: 0.99...1, limitColor: EWDPalette.red)
                .position(x: 369, y: 237)
            axis("CAP", unit: "%").position(x: 260, y: 238)
            if showDetails {
                AuxiliaryReadings(metrics: metrics).position(x: 260, y: 321)
            }
            EWDMemo(metrics: metrics).position(x: 260, y: 453)
        }
        .frame(width: Dashboard.size.width, height: Dashboard.size.height)
    }

    private func axis(_ label: String, unit: String) -> some View {
        VStack(spacing: 0) {
            Text(label).instrumentFont(14, weight: .medium).foregroundStyle(EWDPalette.white)
            Text(unit).instrumentFont(12).foregroundStyle(EWDPalette.cyan)
        }
        .accessibilityHidden(true)
    }
}

private struct AuxiliaryReadings: View {
    let metrics: Metrics

    var body: some View {
        VStack(spacing: 6) {
            row(label: "MEM USED / TOTAL", unit: "GiB",
                left: metrics.memory.map { ReadingFormat.memory($0.used) + " EST" },
                right: metrics.memory.map { ReadingFormat.memory($0.total) },
                spokenLabels: ("Estimated memory used", "Total physical memory"))
            row(label: "DISK USED / FREE", unit: "GB / TB",
                left: metrics.disk.map { ReadingFormat.disk($0.used) },
                right: metrics.disk.map { ReadingFormat.disk($0.available) },
                spokenLabels: ("Disk used", "Disk free"))
            row(label: "NET RX / TX", unit: "B/s",
                left: metrics.network.down.map { ReadingFormat.rate($0) },
                right: metrics.network.up.map { ReadingFormat.rate($0) },
                spokenLabels: ("Network receive rate", "Network transmit rate"))
        }
    }

    private func row(label: String, unit: String, left: String?, right: String?,
                     spokenLabels: (String, String)) -> some View {
        HStack(spacing: 5) {
            reading(left, alignment: .trailing)
            slash(rises: true)
            VStack(spacing: 0) {
                Text(label).instrumentFont(12, weight: .medium).foregroundStyle(EWDPalette.white)
                Text(unit).instrumentFont(10).foregroundStyle(EWDPalette.cyan)
            }
            .frame(width: 137)
            slash(rises: false)
            reading(right, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenLabels.0), \(left ?? "unavailable"); \(spokenLabels.1), \(right ?? "unavailable")"
            + (unit == "GiB" ? ", gibibytes" : ""))
    }

    private func reading(_ value: String?, alignment: Alignment) -> some View {
        Text(value ?? "N/A")
            .instrumentFont(15, weight: .medium)
            .foregroundStyle(value == nil ? EWDPalette.white : EWDPalette.green)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: 100, alignment: alignment)
    }

    private func slash(rises: Bool) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rises ? 7 : 0))
            path.addLine(to: CGPoint(x: 18, y: rises ? 0 : 7))
        }
        .stroke(EWDPalette.white, lineWidth: 0.9)
        .frame(width: 18, height: 7)
    }
}

struct EWDMemo {
    struct Line {
        let text: String
        let color: Color
    }

    let metrics: Metrics

    var columns: [[Line]] {
        let alerts = AlertLogic.evaluate(metrics)
        let battery = metrics.battery
        let batteryText = battery.percent.map { "BATTERY \($0)%" }
            ?? (battery.present == false ? "NO BATTERY" : "BATTERY N/A")
        let networkText = switch metrics.network.state {
        case .wifi: "WI-FI CONNECTED"
        case .ethernet: "ETHERNET CONNECTED"
        case .online: "NET CONNECTED"
        case .offline: "NET OFFLINE"
        case .requiresConnection: "NET ON DEMAND"
        case .unknown: "NET N/A"
        }
        let memoryText = metrics.memoryPressure == .normal ? "MEM PRESSURE NORMAL" : "MEM PRESSURE N/A"
        return [
            [
                line(batteryText, id: "battery", warning: "BATTERY LOW", alerts: alerts),
                line(networkText, id: "network", warning: "NET OFFLINE", alerts: alerts),
                line("THERM " + (metrics.thermal?.rawValue ?? "N/A"), id: "thermal",
                     warning: "THERM " + (metrics.thermal?.rawValue ?? "N/A"), alerts: alerts)
            ],
            [
                line(memoryText, id: "memory", alerts: alerts),
                line(metrics.disk.map { "DISK \(Int($0.percent.rounded()))% USED" } ?? "DISK N/A",
                     id: "disk", warning: "DISK SPACE LOW", alerts: alerts),
                line(battery.supplyText),
                line(battery.chargingText)
            ]
        ]
    }

    private func line(_ text: String, id: String? = nil, warning: String? = nil, alerts: [Alert] = []) -> Line {
        if let alert = alerts.first(where: { $0.id == id }) {
            let color = switch alert.level {
            case .critical: EWDPalette.red
            case .caution: EWDPalette.amber
            case .advisory: EWDPalette.cyan
            }
            return Line(text: warning ?? alert.text, color: color)
        }
        return Line(text: text, color: text.contains("N/A") ? EWDPalette.white : EWDPalette.green)
    }
}

extension EWDMemo: View {
    var body: some View {
        let lines = columns
        VStack(spacing: 0) {
            Rectangle().fill(EWDPalette.white).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                column(lines[0])
                Rectangle().fill(EWDPalette.white).frame(width: 1, height: 88).padding(.top, 7)
                column(lines[1])
            }
        }
        .frame(width: 472, height: 116, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System memo")
    }

    private func column(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index].text)
                    .instrumentFont(13, weight: .medium)
                    .foregroundStyle(lines[index].color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

#Preview("AERION E/WD") {
    EWDDisplay(metrics: MockMetricsProvider.preview, showDetails: true)
}
