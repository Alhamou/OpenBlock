import BlockerCore
import SwiftUI

/// The status item icon. It also opens the main window when AppKit asks for it (Dock click, launch by hand).
struct MenuBarLabel: View {
    @ObservedObject private var manager = FilterManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onChange(of: settings.windowRequests) { _, _ in openWindow(id: "main") }
            .onAppear { if settings.windowRequests > 0 { openWindow(id: "main") } }
    }

    private var symbol: String {
        if manager.isPaused { return "shield.slash" }
        if !manager.allEnabledInSafari { return "exclamationmark.shield" }
        return "shield.lefthalf.filled"
    }
}

/// The menu under the status item.
struct MenuBarMenu: View {
    @ObservedObject private var manager = FilterManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Text(updateLine)
        Divider()
        Button(manager.isUpdating ? "Updating…" : "Update Filters Now") {
            Task { await manager.update(download: .all) }
        }
        .disabled(manager.isUpdating)
        Toggle("Pause Blocking", isOn: Binding(
            get: { manager.isPaused },
            set: { paused in Task { await manager.setPaused(paused) } }
        ))
        Divider()
        Button("Open OpenBlock…") { openWindow(id: "main") }
        if !manager.allEnabledInSafari {
            Button("Enable in Safari…") { manager.openSafariSettings() }
        }
        Toggle("Launch at Login", isOn: Binding(
            get: { settings.launchAtLogin },
            set: { settings.setLaunchAtLogin($0) }
        ))
        Divider()
        Button("Quit OpenBlock") { NSApp.terminate(nil) }
    }

    private var statusLine: String {
        if manager.isPaused { return "Blocking paused" }
        let on = BlockerCategory.allCases.filter { manager.statuses[$0]?.enabledInSafari == true }.count
        let advanced = manager.advanced.enabledInSafari ? "Advanced on" : "Advanced off"
        return "\(on) of \(BlockerCategory.allCases.count) blockers on · \(advanced)"
    }

    private var updateLine: String {
        if manager.isUpdating { return manager.progress.isEmpty ? "Updating…" : manager.progress }
        guard let date = manager.lastUpdate else { return "Filters not downloaded yet" }
        return "Filters updated \(date.formatted(.relative(presentation: .named)))"
    }
}
