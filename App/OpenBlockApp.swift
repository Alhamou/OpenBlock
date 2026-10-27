import SwiftUI

@main
struct OpenBlockApp: App {
    @StateObject private var manager = FilterManager()

    var body: some Scene {
        Window("OpenBlock", id: "main") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 760, minHeight: 520)
                .task { manager.start() }
                // Coming back from Safari's settings: pick up blockers the user just enabled.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await manager.refreshSafariState() }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Update Filters") { Task { await manager.update(download: true) } }
                    .keyboardShortcut("u")
            }
        }
    }
}
