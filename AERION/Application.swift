import AppKit
import IOKit.ps

@main
struct AERIONApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let sampler = SamplingManager(provider: {
        #if DEBUG
        if CommandLine.arguments.contains("--mock-metrics-boundary") {
            var reading = MockMetricsProvider.preview
            reading.cpu = 0
            reading.memory = Capacity(used: 8_589_934_592, total: 8_589_934_592)
            reading.battery = Metrics().battery
            reading.disk = Capacity(used: 4_000_000_000_000, total: 8_000_000_000_000)
            reading.network.down = 999_999_000
            reading.memoryPressure = .warning
            return MockMetricsProvider(reading)
        }
        if CommandLine.arguments.contains("--mock-metrics") { return MockMetricsProvider() }
        #endif
        return SystemMetricsProvider()
    }())
    private var windows: WindowManager!
    private var menuBar: MenuBar!
    private var sleeping = false
    private var powerSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windows = WindowManager(sampler: sampler, preferences: preferences)
        menuBar = MenuBar(sampler: sampler, preferences: preferences, windows: windows)
        menuBar.onVisibilityChange = { [weak self] in self?.updateSampling() }
        preferences.onChange = { [weak self] in
            guard let self else { return }
            windows.applyPreferences()
            menuBar.applyPreferences()
            updateSampling()
        }
        installMenus()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        showDashboard()
        updateSampling()
        observePowerSource()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
    }

    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                delegate.sampler.powerSourceDidChange()
            }
        }, context)?.takeRetainedValue()
        if let powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        preferences.refreshLoginStatus()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showDashboard()
        return false
    }

    @objc private func visibilityChanged() {
        // Window-close notifications arrive before AppKit updates window visibility.
        DispatchQueue.main.async { [weak self] in self?.updateSampling() }
    }

    @objc private func willSleep() { sleeping = true; updateSampling() }
    @objc private func didWake() { sleeping = false; updateSampling() }

    private func updateSampling() {
        sampler.configure(interval: preferences.interval,
                          visible: windows.hasVisibleMonitor || menuBar.isVisible, sleeping: sleeping)
    }

    @objc private func showDashboard() { windows.showDashboard() }
    @objc private func showSystemDisplay() { windows.showSystemDisplay() }
    @objc private func stackDisplays() { windows.stackDisplays() }
    @objc private func toggleDashboardDisplay() { windows.toggleDashboardDisplay() }
    @objc private func showFloating() { windows.showFloating() }
    @objc private func showSettings() { windows.showSettings() }

    private func installMenus() {
        let bar = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu(title: "AERION")
        applicationItem.submenu = application
        bar.addItem(applicationItem)
        application.addItem(menuItem("About AERION", #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                     target: NSApp))
        application.addItem(.separator())
        application.addItem(menuItem("Settings…", #selector(showSettings), key: ",", target: self))
        application.addItem(.separator())
        application.addItem(menuItem("Hide AERION", #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        application.addItem(menuItem("Quit AERION", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        windowItem.submenu = window
        bar.addItem(windowItem)
        window.addItem(menuItem("Dashboard", #selector(showDashboard), key: "1", target: self))
        window.addItem(menuItem("Floating Monitor", #selector(showFloating), key: "2", target: self))
        window.addItem(menuItem("System Display", #selector(showSystemDisplay), key: "3", target: self))
        window.addItem(menuItem("Stack ECAM Displays", #selector(stackDisplays), key: "4", target: self))
        window.addItem(menuItem("Switch E/WD and SD", #selector(toggleDashboardDisplay), key: "5", target: self))
        window.addItem(.separator())
        window.addItem(menuItem("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))
        window.addItem(menuItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        NSApp.mainMenu = bar
        NSApp.windowsMenu = window
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
