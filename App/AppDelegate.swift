import AppKit

/// Starts the filter manager, keeps the Dock icon in sync with the "menu bar only" setting and asks
/// for the window when the app is launched by hand or its Dock icon is clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        FilterManager.shared.start()
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in AppSettings.updateActivationPolicy() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                Task { @MainActor in AppSettings.updateActivationPolicy(closing: window) }
            },
        ]
        AppSettings.updateActivationPolicy()
        // In menu-bar mode the window scene is suppressed at launch: show it unless macOS started us at login.
        if AppSettings.shared.menuBarOnly && !launchedAsLoginItem {
            AppSettings.shared.requestWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppSettings.shared.requestWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The open-application event carries `keyAELaunchedAsLogInItem` when a login item started the app.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication),
              let reason = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else { return false }
        return reason.enumCodeValue == 0x6C67_6974 // 'lgit', keyAELaunchedAsLogInItem
    }
}
