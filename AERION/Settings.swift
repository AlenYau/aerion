import Foundation
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    static let updateIntervals: [TimeInterval] = [0.5, 2, 5]

    var interval: TimeInterval { didSet { defaults.set(interval, forKey: "interval"); onChange?() } }
    var floatingOnTop: Bool { didSet { defaults.set(floatingOnTop, forKey: "floatingOnTop"); onChange?() } }
    var scale: Double { didSet { defaults.set(scale, forKey: "scale"); onChange?() } }
    var systemPage: SDPage { didSet { defaults.set(systemPage.rawValue, forKey: "systemPage") } }
    var showDetails: Bool { didSet { defaults.set(showDetails, forKey: "showDetails") } }

    private(set) var loginStatus = SMAppService.Status.notRegistered
    private(set) var loginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedInterval = defaults.double(forKey: "interval")
        let interval = savedInterval == 1 ? Self.updateIntervals[0] : savedInterval
        self.interval = Self.updateIntervals.contains(interval) ? interval : 2
        if savedInterval == 1 { defaults.set(interval, forKey: "interval") }
        let scale = defaults.double(forKey: "scale")
        self.scale = [0.85, 1, 1.15].contains(scale) ? scale : 1
        self.floatingOnTop = defaults.object(forKey: "floatingOnTop") as? Bool ?? true
        self.systemPage = defaults.string(forKey: "systemPage").flatMap(SDPage.init(rawValue:)) ?? .elec
        self.showDetails = defaults.object(forKey: "showDetails") as? Bool ?? true
    }

    var loginRegistered: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }
}

struct PreferencesView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Picker("Update interval", selection: $preferences.interval) {
                ForEach(Preferences.updateIntervals, id: \.self) { interval in
                    Text(interval.formatted() + " s").tag(interval)
                }
            }
            .pickerStyle(.segmented)
            Picker("Display scale", selection: $preferences.scale) {
                Text("85%").tag(0.85)
                Text("100%").tag(1.0)
                Text("115%").tag(1.15)
            }
            .pickerStyle(.segmented)
            Toggle("Show auxiliary readings", isOn: $preferences.showDetails)
            Toggle("Keep floating monitor above windows", isOn: $preferences.floatingOnTop)
            Toggle("Launch at login", isOn: Binding(get: { preferences.loginRegistered },
                                                     set: { preferences.setLaunchAtLogin($0) }))
            if preferences.loginStatus == .requiresApproval {
                Button("Approve in System Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            if let error = preferences.loginError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 455)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear { preferences.refreshLoginStatus() }
    }
}
