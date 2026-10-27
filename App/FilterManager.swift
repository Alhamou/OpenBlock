import BlockerCore
import Foundation
import SafariServices

/// Downloads filter lists, converts them, writes the JSON for each content blocker
/// into the App Group and asks Safari to reload the blockers.
@MainActor
final class FilterManager: ObservableObject {
    struct BlockerStatus: Codable, Equatable {
        var stats = ConversionStats()
        var error: String?
        var enabledInSafari = false
    }

    @Published var userLists: [FilterList] { didSet { save(userLists, "userLists") } }
    @Published var enabledIDs: Set<String> { didSet { save(enabledIDs, "enabledIDs") } }
    @Published var userRules: String { didSet { defaults.set(userRules, forKey: "userRules") } }
    @Published var allowlist: [String] { didSet { save(allowlist, "allowlist") } }
    @Published private(set) var lastUpdate: Date? { didSet { defaults.set(lastUpdate, forKey: "lastUpdate") } }
    @Published private(set) var statuses: [BlockerCategory: BlockerStatus] = [:]
    @Published private(set) var advanced = AdvancedStatus()
    @Published private(set) var isUpdating = false
    @Published private(set) var progress = ""
    @Published private(set) var downloadErrors: [String: String] = [:]

    struct AdvancedStatus: Codable, Equatable {
        var stats = AdvancedStats()
        var error: String?
        var enabledInSafari = false
    }

    static let advancedExtensionID = AppGroup.extensionIdentifier(for: "advanced")

    /// Lists are re-downloaded when older than this.
    let updateInterval: TimeInterval = 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    var allLists: [FilterList] { FilterCatalog.builtIn + userLists }

    init() {
        userLists = Self.load("userLists") ?? []
        var enabled: Set<String> = Self.load("enabledIDs") ?? Set(FilterCatalog.builtIn.filter(\.enabledByDefault).map(\.id))
        // Built-in lists added in a later version start in their default state for existing users.
        // Before this was tracked, everything except the lists added since then was already known.
        let known: Set<String> = Self.load("knownBuiltInIDs")
            ?? Set(FilterCatalog.builtIn.map(\.id)).subtracting(["openblock-error-trackers"])
        for list in FilterCatalog.builtIn where list.enabledByDefault && !known.contains(list.id) {
            enabled.insert(list.id)
        }
        enabledIDs = enabled
        userRules = UserDefaults.standard.string(forKey: "userRules") ?? ""
        allowlist = Self.load("allowlist") ?? []
        lastUpdate = UserDefaults.standard.object(forKey: "lastUpdate") as? Date
        statuses = Self.load("statuses") ?? [:]
        advanced = Self.load("advanced") ?? AdvancedStatus()
        save(Set(FilterCatalog.builtIn.map(\.id)), "knownBuiltInIDs")
    }

    /// Updates on launch when stale, then checks hourly while the app runs.
    func start() {
        Task { await refreshSafariState() }
        if lastUpdate.map({ Date().timeIntervalSince($0) > updateInterval }) ?? true {
            Task { await update(download: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let last = self.lastUpdate, Date().timeIntervalSince(last) > self.updateInterval else { return }
                await self.update(download: true)
            }
        }
    }

    // MARK: Update pipeline

    /// - Parameter download: `false` rebuilds from cached lists (after editing rules or toggling lists).
    func update(download: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false; progress = "" }

        let enabled = allLists.filter { enabledIDs.contains($0.id) }
        if download {
            progress = "Downloading \(enabled.count) filter lists…"
            downloadErrors = await Self.download(enabled)
        }

        progress = "Converting rules…"
        var sources = enabled.compactMap { list -> FilterListSource? in
            guard let text = try? String(contentsOf: Self.cacheFile(for: list), encoding: .utf8) else { return nil }
            // Only built-in lists and the user's own rules may run JavaScript in pages.
            return FilterListSource(name: list.name, category: list.category, text: text, isTrusted: !list.isUserAdded)
        }
        sources.append(FilterListSource(name: "User rules", category: .custom, text: userRules, isTrusted: true))
        let allowlist = self.allowlist

        let (results, advancedResult) = await Task.detached(priority: .userInitiated) {
            let builder = BlockerBuilder()
            return (builder.build(sources: sources, allowlist: allowlist),
                    builder.buildAdvanced(sources: sources, allowlist: allowlist))
        }.value

        // The web extension re-reads this file when its modification date changes.
        advanced.error = nil
        advanced.stats = advancedResult.1
        do {
            try FileManager.default.createDirectory(at: AppGroup.rulesDirectory, withIntermediateDirectories: true)
            try advancedResult.0.jsonData().write(to: AppGroup.rulesFile(for: "advanced"), options: .atomic)
        } catch {
            advanced.error = error.localizedDescription
        }
        save(advanced, "advanced")

        progress = "Reloading Safari content blockers…"
        await refreshSafariState(reloadNewlyEnabled: false)
        for category in BlockerCategory.allCases {
            var status = statuses[category] ?? BlockerStatus()
            status.error = nil
            do {
                let result = results[category]!
                status.stats = result.stats
                try FileManager.default.createDirectory(at: AppGroup.rulesDirectory, withIntermediateDirectories: true)
                try result.rules.jsonData().write(to: AppGroup.rulesFile(for: category.rawValue), options: .atomic)
                // A disabled blocker cannot be reloaded; Safari reads the file when the user enables it.
                if status.enabledInSafari { try await reload(category) }
            } catch {
                status.error = error.localizedDescription
            }
            statuses[category] = status
        }
        if download { lastUpdate = Date() }
        save(statuses, "statuses")
    }

    /// Re-reads which blockers are enabled in Safari. A blocker that was just switched on
    /// is reloaded so it picks up the latest rules.
    func refreshSafariState(reloadNewlyEnabled: Bool = true) async {
        await refreshAdvancedState()
        for category in BlockerCategory.allCases {
            let identifier = AppGroup.extensionIdentifier(for: category.rawValue)
            let enabled = (try? await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: identifier))?.isEnabled ?? false
            let wasEnabled = statuses[category]?.enabledInSafari ?? false
            statuses[category, default: BlockerStatus()].enabledInSafari = enabled
            if reloadNewlyEnabled && enabled && !wasEnabled {
                do {
                    try await reload(category)
                    statuses[category]?.error = nil
                } catch {
                    statuses[category]?.error = error.localizedDescription
                }
            }
        }
    }

    func refreshAdvancedState() async {
        let state = try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: Self.advancedExtensionID)
        advanced.enabledInSafari = state?.isEnabled ?? false
    }

    private func reload(_ category: BlockerCategory) async throws {
        try await SFContentBlockerManager.reloadContentBlocker(
            withIdentifier: AppGroup.extensionIdentifier(for: category.rawValue)
        )
    }

    func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: AppGroup.extensionIdentifier(for: BlockerCategory.ads.rawValue)
        )
    }

    // MARK: Lists

    func addUserList(name: String, url: URL, category: BlockerCategory) {
        let list = FilterList(id: "user-\(UUID().uuidString)", name: name, summary: url.absoluteString,
                              url: url, category: category, isUserAdded: true)
        userLists.append(list)
        enabledIDs.insert(list.id)
    }

    func removeUserList(_ list: FilterList) {
        userLists.removeAll { $0.id == list.id }
        enabledIDs.remove(list.id)
        try? FileManager.default.removeItem(at: Self.cacheFile(for: list))
    }

    func ruleCount(for list: FilterList) -> Int? {
        guard let text = try? String(contentsOf: Self.cacheFile(for: list), encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).count { !$0.hasPrefix("!") }
    }

    /// Returns errors by list ID; successful downloads replace the cached copy.
    private static func download(_ lists: [FilterList]) async -> [String: String] {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        return await withTaskGroup(of: (String, String?).self) { group in
            for list in lists {
                group.addTask {
                    do {
                        // Built-in lists ship inside the app bundle.
                        if list.url.isFileURL {
                            try Data(contentsOf: list.url).write(to: cacheFile(for: list), options: .atomic)
                            return (list.id, nil)
                        }
                        var request = URLRequest(url: list.url, timeoutInterval: 60)
                        request.cachePolicy = .reloadIgnoringLocalCacheData
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            return (list.id, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                        }
                        try data.write(to: cacheFile(for: list), options: .atomic)
                        return (list.id, nil)
                    } catch {
                        return (list.id, error.localizedDescription)
                    }
                }
            }
            var errors: [String: String] = [:]
            for await (id, error) in group { if let error { errors[id] = error } }
            return errors
        }
    }

    private nonisolated static var cacheDirectory: URL {
        AppGroup.containerURL.appendingPathComponent("Lists", isDirectory: true)
    }

    private nonisolated static func cacheFile(for list: FilterList) -> URL {
        cacheDirectory.appendingPathComponent("\(list.id).txt")
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
