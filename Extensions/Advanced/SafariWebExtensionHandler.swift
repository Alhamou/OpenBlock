import Foundation
import os
import SafariServices

/// Native side of OpenBlock Advanced. The background worker calls
/// `browser.runtime.sendNativeMessage(..., { action: "getRuleset", version })`
/// and gets the advanced ruleset the app wrote to the App Group.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "de.hamou.openblock", category: "Advanced")

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        var reply: [String: Any] = [:]
        switch message?["action"] as? String {
        case "getRuleset":
            reply = rulesetReply(knownVersion: message?["version"] as? String)
        default:
            reply["error"] = "unknown action"
        }

        log.info("\(message?["action"] as? String ?? "?", privacy: .public) → \(reply["unchanged"] != nil ? "unchanged" : reply["error"] as? String ?? "sent ruleset", privacy: .public)")

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// The file's modification date is the version, so an unchanged ruleset is not resent.
    private func rulesetReply(knownVersion: String?) -> [String: Any] {
        let url = AppGroup.rulesFile(for: "advanced")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return ["version": "none", "ruleset": #"{"entries":[],"rules":{},"exceptions":{},"pages":{}}"#]
        }
        let version = String(Int(modified.timeIntervalSince1970 * 1000))
        if version == knownVersion { return ["version": version, "unchanged": true] }
        guard let json = try? String(contentsOf: url, encoding: .utf8) else { return ["error": "unreadable ruleset"] }
        return ["version": version, "ruleset": json]
    }
}
