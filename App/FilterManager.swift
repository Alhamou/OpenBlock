import BlockerCore
import Foundation
import SafariServices

/// Downloads filter lists, converts them, writes the JSON for each content blocker
/// into the App Group and asks Safari to reload the blockers.
@MainActor
final class FilterManager: ObservableObject {
    static let shared = FilterManager()

    struct BlockerStatus: Codable, Equatable {
        var stats = ConversionStats()
        var error: String?
        var enabledInSafari = false
    }

    struct AdvancedStatus: Codable, Equatable {
        var stats = AdvancedStats()
        var error: String?
        var enabledInSafari = false
    }

    /// What is known about a list's cached copy.
    struct ListInfo: Codable, Equatable {
        var ruleCount: Int
        var downloadedAt: Date
    }

    /// Which lists `update` downloads before rebuilding.
    enum DownloadMode: Int, Comparable {
        /// Rebuild from the cached copies (after editing rules or the allowlist).
        case none
        /// Download only lists that have no cached copy yet (after toggling or adding lists).
        case missing
        /// Download every enabled list (manual or daily update).
        case all

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    @Published var userLists: [FilterList] { didSet { save(userLists, "userLists") } }
    @Published var enabledIDs: Set<String> { didSet { save(enabledIDs, "enabledIDs") } }
    @Published var userRules: String { didSet { defaults.set(userRules, forKey: "userRules") } }
    @Published var allowlist: [String] { didSet { save(allowlist, "allowlist") } }
    /// List changes that have not been applied to Safari yet.
    @Published private(set) var pendingApply: Bool { didSet { defaults.set(pendingApply, forKey: "pendingApply") } }
    /// While paused every blocker gets an empty rule file and the Advanced ruleset is empty.
    @Published private(set) var isPaused: Bool { didSet { defaults.set(isPaused, forKey: "isPaused") } }
    @Published private(set) var lastUpdate: Date? { didSet { defaults.set(lastUpdate, forKey: "lastUpdate") } }
    @Published private(set) var statuses: [BlockerCategory: BlockerStatus] = [:]
    @Published private(set) var advanced = AdvancedStatus()
    @Published private(set) var listInfo: [String: ListInfo] = [:]
    @Published private(set) var userRulesReport = ListInspector.Report()
    @Published private(set) var isUpdating = false
    @Published private(set) var progress = ""
    @Published private(set) var downloadErrors: [String: String] = [:]

    static let advancedExtensionID = AppGroup.extensionIdentifier(for: "advanced")

    /// Lists are re-downloaded when older than this.
    let updateInterval: TimeInterval = 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    /// An update requested while another one was running; it runs right after.
    private var queued: DownloadMode?

    var allLists: [FilterList] { FilterCatalog.builtIn + userLists }

    /// Safari has every content blocker and the Advanced extension enabled.
    var allEnabledInSafari: Bool {
        BlockerCategory.allCases.allSatisfy { statuses[$0]?.enabledInSafari == true } && advanced.enabledInSafari
    }

    private init() {
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
        pendingApply = UserDefaults.standard.bool(forKey: "pendingApply")
        isPaused = UserDefaults.standard.bool(forKey: "isPaused")
        lastUpdate = UserDefaults.standard.object(forKey: "lastUpdate") as? Date
        statuses = Self.load("statuses") ?? [:]
        advanced = Self.load("advanced") ?? AdvancedStatus()
        listInfo = Self.load("listInfo") ?? [:]
        userRulesReport = Self.load("userRulesReport") ?? ListInspector.Report()
        save(Set(FilterCatalog.builtIn.map(\.id)), "knownBuiltInIDs")
    }

    /// Refreshes Safari's state, applies pending list changes or runs the daily update, then keeps
    /// checking every 15 minutes while the app runs. Safe to call more than once.
    func start() {
        guard timer == nil else { return }
        Task {
            await refreshSafariState()
            if pendingApply {
                await update(download: .missing)
            } else if updateIsDue {
                await update(download: .all)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshSafariState()
                if self.updateIsDue { await self.update(download: .all) }
            }
        }
    }

    private var updateIsDue: Bool {
        lastUpdate.map { Date().timeIntervalSince($0) > updateInterval } ?? true
    }

    // MARK: Update pipeline

    /// Downloads (depending on `mode`), converts, writes and reloads. A call made while an update is
    /// running is not dropped: the strongest requested mode runs again as soon as the current one ends.
    func update(download mode: DownloadMode) async {
        if isUpdating {
            queued = max(queued ?? mode, mode)
            return
        }
        isUpdating = true
        defer { isUpdating = false; progress = "" }
        var mode = mode
        while true {
            await runUpdate(download: mode)
            guard let next = queued else { break }
            queued = nil
            mode = next
        }
    }

    private struct BuildOutput: Sendable {
        var results: [BlockerCategory: ConversionResult]
        var advancedRuleset: AdvancedRuleset
        var advancedStats: AdvancedStats
        var listInfo: [String: ListInfo]
        var userRulesReport: ListInspector.Report
    }

    private func runUpdate(download mode: DownloadMode) async {
        let enabled = allLists.filter { enabledIDs.contains($0.id) }
        if mode != .none {
            let lists = mode == .all ? enabled : enabled.filter { !Self.hasCache(for: $0) }
            if !lists.isEmpty {
                progress = "Downloading \(lists.count) filter list\(lists.count == 1 ? "" : "s")…"
                let errors = await Self.download(lists)
                for list in lists { downloadErrors[list.id] = errors[list.id] }
            }
        }

        progress = isPaused ? "Pausing…" : "Converting rules…"
        let lists = allLists
        let enabledSet = self.enabledIDs
        let userRules = self.userRules
        let allowlist = self.allowlist
        // Reading and converting ~20 MB of lists takes seconds; keep it off the main thread.
        let output = await Task.detached(priority: .userInitiated) { () -> BuildOutput in
            var info: [String: ListInfo] = [:]
            var sources: [FilterListSource] = []
            for list in lists {
                let file = Self.cacheFile(for: list)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let count = text.split(whereSeparator: \.isNewline).count { !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[") }
                info[list.id] = ListInfo(ruleCount: count, downloadedAt: modified)
                guard enabledSet.contains(list.id) else { continue }
                // Only built-in lists and the user's own rules may run JavaScript in pages.
                sources.append(FilterListSource(name: list.name, category: list.category, text: text, isTrusted: !list.isUserAdded))
            }
            sources.append(FilterListSource(name: "User rules", category: .custom, text: userRules, isTrusted: true))
            let builder = BlockerBuilder()
            let (ruleset, stats) = builder.buildAdvanced(sources: sources, allowlist: allowlist)
            return BuildOutput(results: builder.build(sources: sources, allowlist: allowlist),
                               advancedRuleset: ruleset, advancedStats: stats, listInfo: info,
                               userRulesReport: ListInspector.inspect(userRules))
        }.value

        listInfo = output.listInfo
        userRulesReport = output.userRulesReport
        save(listInfo, "listInfo")
        save(userRulesReport, "userRulesReport")

        let paused = isPaused
        // The web extension re-reads this file when its modification date changes.
        advanced.error = nil
        advanced.stats = output.advancedStats
        do {
            try FileManager.default.createDirectory(at: AppGroup.rulesDirectory, withIntermediateDirectories: true)
            let ruleset = paused ? AdvancedRuleset() : output.advancedRuleset
            try ruleset.jsonData().write(to: AppGroup.rulesFile(for: "advanced"), options: .atomic)
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
                let result = output.results[category]!
                status.stats = result.stats
                let rules: [SafariRule] = paused ? [] : result.rules
                try rules.jsonData().write(to: AppGroup.rulesFile(for: category.rawValue), options: .atomic)
                // A disabled blocker cannot be reloaded; Safari reads the file when the user enables it.
                if status.enabledInSafari { try await reload(category) }
            } catch {
                status.error = Self.describe(error)
            }
            statuses[category] = status
        }
        if mode == .all { lastUpdate = Date() }
        pendingApply = false
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
                    statuses[category]?.error = Self.describe(error)
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

    /// Safari's content-blocker errors are numeric; say what they mean.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == SFErrorDomain else { return error.localizedDescription }
        switch nsError.code {
        case 1: // SFErrorNoExtensionFound
            return "Safari cannot find this blocker. Enable it under Safari → Settings → Extensions."
        case 2: // SFErrorNoAttachmentFound
            return "The blocker did not return a rule file."
        case 3: // SFErrorLoadingInterrupted
            return "Safari rejected the rule file. Try Update Filters again."
        default:
            return error.localizedDescription
        }
    }

    func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: AppGroup.extensionIdentifier(for: BlockerCategory.ads.rawValue)
        )
    }

    // MARK: Pause

    func setPaused(_ paused: Bool) async {
        guard paused != isPaused else { return }
        isPaused = paused
        await update(download: .none)
    }

    // MARK: Lists

    func setEnabled(_ enabled: Bool, for list: FilterList) {
        if enabled { enabledIDs.insert(list.id) } else { enabledIDs.remove(list.id) }
        pendingApply = true
    }

    func addUserList(name: String, url: URL, category: BlockerCategory) {
        let list = FilterList(id: "user-\(UUID().uuidString)", name: name, summary: url.absoluteString,
                              url: url, category: category, isUserAdded: true)
        userLists.append(list)
        enabledIDs.insert(list.id)
        pendingApply = true
    }

    func removeUserList(_ list: FilterList) {
        userLists.removeAll { $0.id == list.id }
        enabledIDs.remove(list.id)
        listInfo[list.id] = nil
        downloadErrors[list.id] = nil
        try? FileManager.default.removeItem(at: Self.cacheFile(for: list))
        pendingApply = true
    }

    /// Applies pending list changes, downloading only lists that have no cached copy yet.
    func applyPendingChanges() async {
        await update(download: .missing)
    }

    // MARK: Allowlist

    /// Turns what the user typed (`https://www.Example.com/path`, `example.com:8080`) into a bare
    /// domain, or `nil` when it cannot be one. A leading `www.` is dropped so the whole site is allowed.
    nonisolated static func normalizedAllowlistEntry(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        host = host.components(separatedBy: "/").first ?? host
        host = host.components(separatedBy: "@").last ?? host
        host = host.components(separatedBy: ":").first ?? host
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return RuleParser.isValidDomain(host) ? host : nil
    }

    /// Returns `false` when the text is not a domain or is already allowed.
    @discardableResult
    func addAllowlistEntry(_ text: String) async -> Bool {
        guard let domain = Self.normalizedAllowlistEntry(text), !allowlist.contains(domain) else { return false }
        allowlist.append(domain)
        await update(download: .none)
        return true
    }

    func removeAllowlistEntry(_ domain: String) async {
        allowlist.removeAll { $0 == domain }
        await update(download: .none)
    }

    // MARK: Downloads

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

    private nonisolated static func hasCache(for list: FilterList) -> Bool {
        FileManager.default.fileExists(atPath: cacheFile(for: list).path)
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
