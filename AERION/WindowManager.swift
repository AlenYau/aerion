import AppKit
import SwiftUI

@MainActor
final class WindowManager {
    private let sampler: SamplingManager
    private let preferences: Preferences
    private var dashboard: NSWindow?
    private var systemDisplay: NSWindow?
    private var dashboardShowsSD = false
    private var appliedScale: Double
    private var floating: NSPanel?
    private var settings: NSWindow?

    init(sampler: SamplingManager, preferences: Preferences) {
        self.sampler = sampler
        self.preferences = preferences
        self.appliedScale = preferences.scale
    }

    var hasVisibleMonitor: Bool {
        [dashboard, systemDisplay, floating].compactMap { $0 }.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
    }

    func showDashboard() {
        let window = dashboardWindow()
        setDashboardContent(window, showsSD: false)
        show(window)
    }

    func showSystemDisplay() {
        show(systemWindow())
    }

    func toggleDashboardDisplay() {
        let window = dashboardWindow()
        setDashboardContent(window, showsSD: !dashboardShowsSD)
        show(window)
    }

    func stackDisplays() {
        let upper = dashboardWindow()
        let lower = systemWindow()
        setDashboardContent(upper, showsSD: false)
        guard let screen = NSApp.keyWindow?.screen ?? upper.screen ?? NSScreen.main else {
            show(upper)
            show(lower)
            return
        }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 8
        let base = Dashboard.size
        let factor = min(preferences.scale, visible.width / base.width, (visible.height - gap) / (2 * base.height))
        let size = CGSize(width: (base.width * factor).rounded(.down),
                          height: (base.height * factor).rounded(.down))
        let x = (visible.midX - size.width / 2).rounded()
        let y = (visible.midY - size.height - gap / 2).rounded()
        show(upper)
        show(lower)
        upper.setFrame(NSRect(x: x, y: y + size.height + gap, width: size.width, height: size.height), display: true)
        lower.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func dashboardWindow() -> NSWindow {
        if let dashboard { return dashboard }
        let window = displayWindow(title: "AERION")
        window.contentView = NSHostingView(rootView: Dashboard(sampler: sampler, preferences: preferences))
        dashboard = window
        return window
    }

    private func systemWindow() -> NSWindow {
        if let systemDisplay { return systemDisplay }
        let window = displayWindow(title: "AERION · System Display")
        if let dashboard, dashboard.isVisible, let screen = dashboard.screen {
            let available = screen.visibleFrame
            let x = min(dashboard.frame.maxX + 12, available.maxX - window.frame.width - 8)
            window.setFrameTopLeftPoint(NSPoint(x: max(available.minX, x), y: dashboard.frame.maxY))
        }
        window.contentView = NSHostingView(rootView: SystemDisplay(sampler: sampler, preferences: preferences))
        systemDisplay = window
        return window
    }

    private func setDashboardContent(_ window: NSWindow, showsSD: Bool) {
        guard dashboardShowsSD != showsSD else { return }
        dashboardShowsSD = showsSD
        if showsSD {
            window.contentView = NSHostingView(rootView: SystemDisplay(sampler: sampler, preferences: preferences))
        } else {
            window.contentView = NSHostingView(rootView: Dashboard(sampler: sampler, preferences: preferences))
        }
    }

    private func displayWindow(title: String) -> NSWindow {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: dashboardSize(on: screen)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: screen)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentAspectRatio = Dashboard.size
        window.contentMinSize = CGSize(width: 260, height: 268)
        window.center()
        return window
    }

    func showFloating() {
        if floating == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: scaled(CompactDisplay.floatingSize)),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "AERION · Floating Monitor"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = NSHostingView(rootView: CompactDisplay(sampler: sampler, preferences: preferences,
                                                                      actions: nil))
            panel.level = preferences.floatingOnTop ? .floating : .normal
            if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 18,
                                                   y: screen.visibleFrame.maxY - 18))
            }
            floating = panel
        }
        show(floating)
    }

    func showSettings() {
        preferences.refreshLoginStatus()
        if settings == nil {
            let hosting = NSHostingView(rootView: PreferencesView(preferences: preferences))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AERION Settings"
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            settings = window
        }
        show(settings)
    }

    func applyPreferences() {
        floating?.level = preferences.floatingOnTop ? .floating : .normal
        guard appliedScale != preferences.scale else { return }
        appliedScale = preferences.scale
        resize(dashboard, to: dashboardSize(on: dashboard?.screen ?? NSScreen.main))
        resize(systemDisplay, to: dashboardSize(on: systemDisplay?.screen ?? NSScreen.main))
        resize(floating, to: scaled(CompactDisplay.floatingSize))
    }

    private func show(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func dashboardSize(on screen: NSScreen?) -> CGSize {
        let size = Dashboard.size
        let available = screen?.visibleFrame.size ?? scaled(size)
        let factor = min(preferences.scale, available.width / size.width, available.height / size.height)
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    private func scaled(_ size: CGSize) -> CGSize {
        CGSize(width: size.width * preferences.scale, height: size.height * preferences.scale)
    }

    private func resize(_ window: NSWindow?, to size: CGSize) {
        guard let window, window.contentRect(forFrameRect: window.frame).size != size else { return }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(size)
        window.setFrameTopLeftPoint(topLeft)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
            window.setFrame(frame, display: true)
        }
    }
}
