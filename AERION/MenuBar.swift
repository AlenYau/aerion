import AppKit
import SwiftUI

@MainActor
final class MenuBar: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let preferences: Preferences
    var onVisibilityChange: (() -> Void)?
    var isVisible: Bool { popover.isShown }

    init(sampler: SamplingManager, preferences: Preferences, windows: WindowManager) {
        self.preferences = preferences
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                accessibilityDescription: "AERION System Monitor")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "A" }
            button.toolTip = "AERION System Monitor"
            button.target = self
            button.action = #selector(toggle)
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
    }

    func applyPreferences() {
        popover.contentSize = CGSize(width: CompactDisplay.menuSize.width * preferences.scale,
                                     height: CompactDisplay.menuSize.height * preferences.scale)
    }

    @objc private func toggle() {
        if popover.isShown { close() }
        else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func close() { popover.performClose(nil) }

    func popoverDidShow(_ notification: Notification) { onVisibilityChange?() }
    func popoverDidClose(_ notification: Notification) { onVisibilityChange?() }
}
