import Foundation
import os

/// Safari calls this when it (re)loads the content blocker. It returns the JSON the app
/// generated for this blocker; Safari compiles it and enforces it inside WebKit.
/// One source file serves all four blocker targets; `OBBlocker` in Info.plist selects the file.
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "de.hamou.openblock", category: "ContentBlocker")

    func beginRequest(with context: NSExtensionContext) {
        let blocker = Bundle.main.object(forInfoDictionaryKey: "OBBlocker") as? String ?? "ads"
        let generated = AppGroup.rulesFile(for: blocker)
        let url = FileManager.default.isReadableFile(atPath: generated.path)
            ? generated
            : Bundle.main.url(forResource: "placeholder", withExtension: "json")!
        log.info("Serving \(blocker, privacy: .public) rules from \(url.lastPathComponent, privacy: .public)")

        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(contentsOf: url)!]
        context.completeRequest(returningItems: [item]) { [log] expired in
            log.info("Request for \(blocker, privacy: .public) completed (expired: \(expired))")
        }
    }
}
