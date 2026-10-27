import SwiftUI

@main
struct OpenBlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var manager = FilterManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        Window("OpenBlock", id: "main") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(settings)
                .frame(minWidth: 760, minHeight: 520)
                // Coming back from Safari's settings: pick up blockers the user just enabled.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await manager.refreshSafariState() }
                }
        }
        // In menu-bar mode the window stays closed at launch; AppDelegate opens it unless macOS
        // started the app at login.
        .defaultLaunchBehavior(settings.menuBarOnly ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Update Filters") { Task { await manager.update(download: .all) } }
                    .keyboardShortcut("u")
            }
        }

        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}
