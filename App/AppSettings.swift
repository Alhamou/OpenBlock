import AppKit
import ServiceManagement
import SwiftUI

/// App-level preferences: menu bar versus Dock, launch at login, and the bridge AppKit uses to
/// ask SwiftUI for the main window.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// The Dock icon shows only while the OpenBlock window is open; otherwise the app lives in the menu bar.
    @Published var menuBarOnly: Bool {
        didSet {
            UserDefaults.standard.set(menuBarOnly, forKey: "menuBarOnly")
            Self.updateActivationPolicy()
        }
    }
    @Published private(set) var launchAtLogin = false
    /// Why launch at login is not active yet, if anything is in the way.
    @Published private(set) var launchAtLoginNote: String?
    /// Bumped when AppKit wants the main window (Dock click, launch by hand); the menu bar label opens it.
    @Published private(set) var windowRequests = 0

    private init() {
        menuBarOnly = UserDefaults.standard.object(forKey: "menuBarOnly") as? Bool ?? true
        refreshLaunchAtLogin()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        var failure: String?
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = error.localizedDescription
        }
        refreshLaunchAtLogin()
        if let failure { launchAtLoginNote = failure }
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNote = status == .requiresApproval
            ? "Approve OpenBlock under System Settings → General → Login Items." : nil
    }

    func requestWindow() {
        windowRequests += 1
    }

    /// `.regular` (Dock icon, app menu) while a window is open or the user wants the Dock icon;
    /// `.accessory` (menu bar only) otherwise.
    static func updateActivationPolicy(closing: NSWindow? = nil) {
        let windowOpen = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        let policy: NSApplication.ActivationPolicy = (!shared.menuBarOnly || windowOpen) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            // Activating right after the policy change leaves the app menu missing until the next click.
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
