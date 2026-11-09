import SwiftUI

struct CompactDisplay: View {
    let sampler: SamplingManager
    let preferences: Preferences
    let actions: Actions?

    struct Actions {
        let dashboard: () -> Void
        let systemDisplay: () -> Void
        let floating: () -> Void
        let settings: () -> Void
        let quit: () -> Void
    }

    static let floatingSize = CGSize(width: 328, height: 147)
    static let menuSize = CGSize(width: 328, height: 268)

    var body: some View {
        let metrics = sampler.metrics
        let alert = AlertLogic.evaluate(metrics).first
        let size = actions == nil ? Self.floatingSize : Self.menuSize
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("A E R I O N").foregroundStyle(ECAM.white)
                Spacer()
                Text(actions == nil ? "REMOTE DISPLAY" : "SYSTEM MONITOR").foregroundStyle(ECAM.cyan)
            }
            .instrumentFont(11, weight: .semibold)
            Rectangle().fill(ECAM.line).frame(height: 1)
            meter("CPU", metrics.cpu)
            meter("MEM", metrics.memory?.percent)
            if actions == nil {
                HStack {
                    Text((metrics.battery.percent.map { "BAT \($0)%" } ?? "BAT N/A")
                         + " · " + metrics.battery.chargingText)
                    Spacer()
                    Text(metrics.thermal.map { "THERM " + $0.rawValue } ?? "THERM N/A")
                }
                .foregroundStyle(ECAM.dim)
            }
            if let alert {
                Text(alert.text).foregroundStyle(ECAM.color(alert.level)).lineLimit(1).minimumScaleFactor(0.75)
            } else if actions == nil && preferences.showDetails {
                Text(metrics.network.state.rawValue + "  ·  ↓" + ReadingFormat.rate(metrics.network.down)
                     + "  ↑" + ReadingFormat.rate(metrics.network.up))
                    .foregroundStyle(ECAM.cyan).lineLimit(1).minimumScaleFactor(0.75)
            }
            if let actions {
                Rectangle().fill(ECAM.line).frame(height: 1)
                ForEach(SystemReadings.cells(metrics)) { cell in
                    HStack(spacing: 8) {
                        Text(cell.id).foregroundStyle(ECAM.dim).frame(width: 43, alignment: .leading)
                        Text(cell.primary).foregroundStyle(cell.color)
                        Spacer(minLength: 2)
                        if preferences.showDetails {
                            Text(cell.detail).foregroundStyle(ECAM.cyan).lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("E/WD", action: actions.dashboard)
                    Button("SD", action: actions.systemDisplay)
                    Button("Float", action: actions.floating)
                    Button("Settings", action: actions.settings)
                    Spacer()
                    Button("Quit", action: actions.quit)
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .instrumentFont(10)
        .padding(13)
        .frame(width: size.width, height: size.height)
        .background(ECAM.background)
        .preferredColorScheme(.dark)
        .scaledSurface(size, by: preferences.scale)
    }

    private func meter(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(ECAM.white).frame(width: 30, alignment: .leading)
            GeometryReader { geometry in
                Rectangle().fill(ECAM.line)
                    .overlay(alignment: .leading) {
                        if let value {
                            Rectangle().fill(ECAM.green)
                                .frame(width: geometry.size.width * min(1, max(0, value / 100)))
                        }
                    }
            }
            .frame(height: 4)
            Text(value.map { ReadingFormat.percent($0) + "%" } ?? "N/A")
                .foregroundStyle(value == nil ? ECAM.dim : ECAM.green)
                .frame(width: 58, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.map { ReadingFormat.percent($0) + " percent" } ?? "Unavailable")
    }
}
