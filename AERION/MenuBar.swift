import AppKit
import Observation
import SwiftUI

enum MenuBarStyle: String, CaseIterable {
    case icon, strip

    var title: String {
        switch self {
        case .icon: "Icon"
        case .strip: "FCU Strip"
        }
    }
}

enum StripField: String, CaseIterable {
    case cpu, memory, battery, disk, down, up, thermal

    static let maximum = 3
    static let defaults: [StripField] = [.cpu, .memory, .down]

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "MEM"
        case .battery: "BAT"
        case .disk: "DSK"
        case .down: "NET↓"
        case .up: "NET↑"
        case .thermal: "THM"
        }
    }

    var title: String {
        switch self {
        case .cpu: "CPU Load"
        case .memory: "Memory Usage"
        case .battery: "Battery Level"
        case .disk: "Disk Usage"
        case .down: "Network Receive"
        case .up: "Network Transmit"
        case .thermal: "Thermal Pressure"
        }
    }

    /// Widest value the field can show; keeps each window a fixed width.
    var template: String {
        switch self {
        case .down, .up, .thermal: "CRIT"
        default: "100%"
        }
    }

    func reading(_ metrics: Metrics) -> (text: String, color: Color)? {
        switch self {
        case .cpu:
            return metrics.cpu.map { (Self.percent($0), $0 >= 85 ? ECAM.amber : ECAM.green) }
        case .memory:
            guard let percent = metrics.memory?.percent else { return nil }
            let color = switch metrics.memoryPressure {
            case .critical?: ECAM.red
            case .warning?: ECAM.amber
            default: ECAM.green
            }
            return (Self.percent(percent), color)
        case .battery:
            guard metrics.battery.present != false, let percent = metrics.battery.percent else { return nil }
            let low = metrics.battery.externalPower == false && percent <= 20
            return ("\(percent)%", low ? ECAM.amber : ECAM.green)
        case .disk:
            return metrics.disk.map { (Self.percent($0.percent), $0.percent >= 95 ? ECAM.amber : ECAM.green) }
        case .down:
            return metrics.network.down.map { (Self.rate($0), ECAM.green) }
        case .up:
            return metrics.network.up.map { (Self.rate($0), ECAM.green) }
        case .thermal:
            switch metrics.thermal {
            case .nominal?: return ("NOM", ECAM.green)
            case .fair?: return ("FAIR", ECAM.green)
            case .serious?: return ("SER", ECAM.amber)
            case .critical?: return ("CRIT", ECAM.red)
            case nil: return nil
            }
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(min(100, max(0, value)).rounded()))%"
    }

    /// Four-character rate readout such as 840B, 84K, 1.2M or 12M.
    static func rate(_ bytes: Double) -> String {
        func scaled(_ value: Double, _ unit: String) -> String {
            value < 10 ? String(format: "%.1f%@", value, unit) : String(format: "%.0f%@", min(value, 999), unit)
        }
        if bytes >= 999_500_000 { return scaled(bytes / 1_000_000_000, "G") }
        if bytes >= 999_500 { return scaled(bytes / 1_000_000, "M") }
        if bytes >= 1000 { return scaled(bytes / 1000, "K") }
        return String(format: "%.0fB", bytes)
    }
}

/// Menu bar readout styled after the A320 FCU / RMP windows: label above, digits below.
struct MenuBarStrip: View {
    let metrics: Metrics
    let fields: [StripField]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(fields.enumerated()), id: \.element) { index, field in
                if index > 0 { Rectangle().fill(ECAM.line).frame(width: 1, height: 13) }
                window(field)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(ECAM.background))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ECAM.line, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private func window(_ field: StripField) -> some View {
        let reading = field.reading(metrics)
        return VStack(spacing: -1) {
            Text(field.label)
                .font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(ECAM.cyan)
            ZStack(alignment: .trailing) {
                Text(field.template).hidden()
                Text(reading?.text ?? "---").foregroundStyle(reading?.color ?? ECAM.dim)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
    }
}

@MainActor
final class MenuBar: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let sampler: SamplingManager
    private let preferences: Preferences
    private let windows: WindowManager
    private let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                            accessibilityDescription: "AERION System Monitor")
        image?.isTemplate = true
        return image
    }()
    var onVisibilityChange: (() -> Void)?
    /// The strip shows live data, so it keeps the sampler at the foreground cadence.
    var isVisible: Bool { popover.isShown || preferences.menuBarStyle == .strip }

    init(sampler: SamplingManager, preferences: Preferences, windows: WindowManager) {
        self.sampler = sampler
        self.preferences = preferences
        self.windows = windows
        super.init()
        if let button = item.button {
            button.toolTip = "AERION System Monitor"
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let actions = CompactDisplay.Actions(
            dashboard: { [weak self] in self?.close(); windows.showDashboard() },
            systemDisplay: { [weak self] in self?.close(); windows.showSystemDisplay() },
            floating: { [weak self] in self?.close(); windows.showFloating() },
            settings: { [weak self] in self?.close(); windows.showSettings() },
            quit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: CompactDisplay(
            sampler: sampler, preferences: preferences, actions: actions
        ))
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        applyPreferences()
        observe()
    }

    func applyPreferences() {
        popover.contentSize = CGSize(width: CompactDisplay.menuSize.width * preferences.scale,
                                     height: CompactDisplay.menuSize.height * preferences.scale)
    }

    // MARK: Status item rendering

    private func observe() {
        withObservationTracking { render() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        switch preferences.menuBarStyle {
        case .icon:
            button.image = icon
            button.title = icon == nil ? "A" : ""
        case .strip:
            let renderer = ImageRenderer(content: MenuBarStrip(metrics: sampler.metrics,
                                                               fields: preferences.stripFields))
            renderer.scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            guard let image = renderer.nsImage else { return }
            image.isTemplate = false
            button.image = image
            button.title = ""
        }
    }

    // MARK: Clicks

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    private func toggle() {
        if popover.isShown { close() }
        else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func close() { popover.performClose(nil) }

    private func showMenu() {
        close()
        item.menu = makeMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(entry("Open E/WD Dashboard", key: "1") { [windows] in windows.showDashboard() })
        menu.addItem(entry("Open Floating Monitor", key: "2") { [windows] in windows.showFloating() })
        menu.addItem(entry("Open System Display", key: "3") { [windows] in windows.showSystemDisplay() })
        menu.addItem(.separator())

        let style = NSMenu()
        style.autoenablesItems = false
        for option in MenuBarStyle.allCases {
            let row = entry(option.title) { [preferences] in preferences.menuBarStyle = option }
            row.state = preferences.menuBarStyle == option ? .on : .off
            style.addItem(row)
        }
        menu.addItem(submenu("Menu Bar Style", style))

        let fields = NSMenu()
        fields.autoenablesItems = false
        let selected = preferences.stripFields
        for field in StripField.allCases {
            let isOn = selected.contains(field)
            let row = entry("\(field.label)  ·  \(field.title)") { [preferences] in
                var next = Set(preferences.stripFields)
                if isOn { next.remove(field) } else { next.insert(field) }
                preferences.stripFields = StripField.allCases.filter(next.contains)
            }
            row.state = isOn ? .on : .off
            row.isEnabled = isOn ? selected.count > 1 : selected.count < StripField.maximum
            fields.addItem(row)
        }
        fields.addItem(.separator())
        let hint = NSMenuItem(title: "Choose up to \(StripField.maximum)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        fields.addItem(hint)
        let fieldsItem = submenu("Strip Readouts", fields)
        fieldsItem.isEnabled = preferences.menuBarStyle == .strip
        menu.addItem(fieldsItem)

        menu.addItem(.separator())
        menu.addItem(entry("Settings…", key: ",") { [windows] in windows.showSettings() })
        menu.addItem(entry("Quit AERION", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    private func entry(_ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: #selector(runEntry(_:)), keyEquivalent: key)
        row.target = self
        row.representedObject = action
        return row
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.submenu = menu
        return row
    }

    @objc private func runEntry(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    func popoverDidShow(_ notification: Notification) { onVisibilityChange?() }
    func popoverDidClose(_ notification: Notification) { onVisibilityChange?() }
}
