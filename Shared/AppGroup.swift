import Foundation

/// The App Group container shared by the app and its content-blocker extensions.
/// Its identifier comes from the `OBAppGroup` Info.plist key (`$(APP_GROUP_ID)` in project.yml).
enum AppGroup {
    static let identifier = Bundle.main.object(forInfoDictionaryKey: "OBAppGroup") as? String ?? ""

    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            fatalError("App Group \(identifier) is not configured; check the entitlements and DEVELOPMENT_TEAM")
        }
        return url
    }

    static var rulesDirectory: URL { containerURL.appendingPathComponent("Rules", isDirectory: true) }

    /// `Rules/<blocker>.json`, e.g. `Rules/ads.json`.
    static func rulesFile(for blocker: String) -> URL {
        rulesDirectory.appendingPathComponent("\(blocker).json")
    }

    /// Bundle identifier of the content-blocker extension for `blocker`.
    static func extensionIdentifier(for blocker: String) -> String {
        let appIdentifier = Bundle.main.bundleIdentifier ?? "de.hamou.openblock"
        return "\(appIdentifier).\(blocker)"
    }
}
