import SwiftUI

enum ECAM {
    static let background = Color(red: 0.024, green: 0.044, blue: 0.055)
    static let panel = Color(red: 0.038, green: 0.067, blue: 0.080)
    static let line = Color(red: 0.13, green: 0.23, blue: 0.27)
    static let dim = Color(red: 0.53, green: 0.65, blue: 0.69)
    static let white = Color(red: 0.87, green: 0.93, blue: 0.94)
    static let cyan = Color(red: 0.40, green: 0.82, blue: 0.89)
    static let green = Color(red: 0.43, green: 0.96, blue: 0.66)
    static let amber = Color(red: 1, green: 0.75, blue: 0.36)
    static let red = Color(red: 1, green: 0.38, blue: 0.40)

    static func color(_ level: AlertLevel) -> Color {
        switch level {
        case .advisory: cyan
        case .caution: amber
        case .critical: red
        }
    }
}

extension View {
    func instrumentFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
            .monospacedDigit()
    }
}

enum ReadingFormat {
    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "N/A"
    }

    static func memory(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824)
    }

    static func disk(_ bytes: UInt64) -> String {
        let size = Double(bytes) / 1_000_000_000
        return size >= 1000 ? String(format: "%.2f TB", size / 1000) : String(format: "%.1f GB", size)
    }

    static func rate(_ bytes: Double?) -> String {
        guard let bytes else { return "N/A" }
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1000 { return String(format: "%.1f kB/s", bytes / 1000) }
        return String(format: "%.0f B/s", bytes)
    }
}

extension Battery {
    var supplyText: String {
        switch externalPower {
        case true?: "AC CONNECTED"
        case false?: "ON BATTERY"
        case nil: "POWER N/A"
        }
    }

    var chargingText: String {
        if present == false { return "NO BATTERY" }
        switch charging {
        case true?: return "CHARGING"
        case false?: return externalPower == false ? "DISCHARGING" : "NOT CHARGING"
        case nil: return "CHARGE N/A"
        }
    }
}

struct SystemCell: Identifiable {
    let id: String
    let primary: String
    let detail: String
    var color = ECAM.green
}

enum SystemReadings {
    static func cells(_ metrics: Metrics) -> [SystemCell] {
        let battery = metrics.battery
        let batteryCell = SystemCell(id: "BAT", primary: battery.percent.map { "\($0)%" } ?? "N/A",
                                     detail: "\(battery.supplyText)  ·  \(battery.chargingText)",
                                     color: battery.externalPower == false && (battery.percent ?? 100) <= 20
                                     ? ECAM.amber : battery.percent == nil ? ECAM.dim : ECAM.green)
        let disk = metrics.disk
        let diskCell = SystemCell(id: "DISK", primary: disk.map { "\(Int($0.percent.rounded()))% USED" } ?? "N/A",
                                  detail: disk.map { "\(ReadingFormat.disk($0.used)) USED · \(ReadingFormat.disk($0.available)) FREE" } ?? "CAPACITY UNAVAILABLE",
                                  color: disk.map { $0.available <= 5_000_000_000 && $0.percent >= 95 ? ECAM.amber : ECAM.green }
                                  ?? ECAM.dim)
        let net = metrics.network
        let link = SystemCell(id: "NET", primary: net.state.rawValue,
                              detail: "↓\(ReadingFormat.rate(net.down))  ↑\(ReadingFormat.rate(net.up))",
                              color: [.offline, .unknown, .requiresConnection].contains(net.state) ? ECAM.dim : ECAM.green)
        let thermal = metrics.thermal
        let therm = SystemCell(id: "THERM", primary: thermal?.rawValue ?? "N/A", detail: "SYSTEM PRESSURE",
                               color: thermal == .critical ? ECAM.red : thermal == .serious ? ECAM.amber
                               : thermal == nil ? ECAM.dim : ECAM.green)
        return [batteryCell, diskCell, link, therm]
    }
}

extension View {
    func scaledSurface(_ size: CGSize, by scale: Double) -> some View {
        scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
            .clipped()
    }
}


enum EWDPalette {
    static let screen = Color(red: 0.021, green: 0.027, blue: 0.068)
    static let white = Color(red: 0.86, green: 0.87, blue: 0.89)
    static let green = Color(red: 0.30, green: 0.96, blue: 0.33)
    static let cyan = Color(red: 0.28, green: 0.79, blue: 0.94)
    static let amber = Color(red: 1, green: 0.70, blue: 0.24)
    static let red = Color(red: 1, green: 0.28, blue: 0.24)
}

struct EWDScale {
    let radius: CGFloat
    let start: Double
    let sweep: Double

    func point(_ fraction: Double, inset: CGFloat = 0, center: CGPoint = .zero) -> CGPoint {
        let angle = (start + fraction * sweep) * .pi / 180
        return CGPoint(x: center.x + (radius - inset) * cos(angle),
                       y: center.y + (radius - inset) * sin(angle))
    }

    func arc(_ range: ClosedRange<Double>, center: CGPoint) -> Path {
        Path { path in
            path.addArc(center: center, radius: radius,
                        startAngle: .degrees(start + range.lowerBound * sweep),
                        endAngle: .degrees(start + range.upperBound * sweep), clockwise: false)
        }
    }
}

private struct EWDNeedle: Shape {
    let scale: EWDScale
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return Path { path in
            let position = min(1, max(0, fraction))
            path.move(to: scale.point(position, inset: scale.radius * 0.82, center: center))
            path.addLine(to: scale.point(position, inset: 1, center: center))
        }
    }
}

struct EWDGauge: View {
    let title: String
    let accessibilityTitle: String
    let value: Double?
    let scale: EWDScale
    let digits: Int
    let limit: ClosedRange<Double>
    let limitColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reading: String {
        value.map { String(format: "%.*f", digits, $0) } ?? "N/A"
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.stroke(scale.arc(0...1, center: center), with: .color(EWDPalette.white), lineWidth: 1.15)
                context.stroke(scale.arc(limit, center: center), with: .color(limitColor), lineWidth: 2.8)
                for mark in 0...10 {
                    let fraction = Double(mark) / 10
                    let major = mark.isMultiple(of: 5)
                    let tick = Path { path in
                        path.move(to: scale.point(fraction, center: center))
                        path.addLine(to: scale.point(fraction, inset: major ? 9 : 5, center: center))
                    }
                    context.stroke(tick, with: .color(EWDPalette.white), lineWidth: 1)
                    if major {
                        let label = Text("\(mark * 10)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(EWDPalette.white)
                        let inset: CGFloat = digits == 0 && mark != 5 ? -14 : 17
                        var anchor = scale.point(fraction, inset: inset, center: center)
                        if mark == 5 { anchor.x += 13 }
                        else if digits != 0 { anchor.y += mark == 0 ? -9 : 9 }
                        context.draw(label, at: anchor)
                    }
                }
            }
            if let value {
                EWDNeedle(scale: scale, fraction: value / 100)
                    .stroke(EWDPalette.green, lineWidth: 1.35)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.42), value: value)
            }
            Text(reading)
                .instrumentFont(digits == 0 ? 17 : 19, weight: .medium)
                .foregroundStyle(value == nil ? EWDPalette.white : EWDPalette.green)
                .frame(width: digits == 0 ? 55 : 65, height: 25)
                .background(EWDPalette.screen)
                .overlay { Rectangle().strokeBorder(EWDPalette.white, lineWidth: 0.9) }
                .offset(y: 7)
            Text(title)
                .instrumentFont(13, weight: .medium)
                .foregroundStyle(EWDPalette.white)
                .offset(y: -scale.radius - 13)
        }
        .frame(width: 188, height: 188)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(value == nil ? "Unavailable" : "\(reading) percent")
    }
}
