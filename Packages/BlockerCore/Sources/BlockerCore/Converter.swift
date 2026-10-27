import Foundation

public struct ConversionStats: Equatable, Sendable, Codable {
    public var sourceRules = 0
    public var safariRules = 0
    public var advancedRules = 0
    public var unsupportedRules = 0
    public var badfiltered = 0
    public var truncated = 0

    public init() {}
}

public struct ConversionResult: Sendable {
    public var rules: [SafariRule]
    public var advanced: [String]
    public var stats: ConversionStats
}

/// Converts filter rules into an ordered Safari content-blocker rule list.
public struct Converter: Sendable {
    /// Safari's per-content-blocker limit (Safari 15+).
    public static let safariRuleLimit = 150_000

    public var maxRules: Int
    /// Generic element-hiding selectors per `css-display-none` rule.
    public var cssBatchSize: Int

    public init(maxRules: Int = Converter.safariRuleLimit, cssBatchSize: Int = 250) {
        self.maxRules = maxRules
        self.cssBatchSize = cssBatchSize
    }

    public func convert(text: String) -> ConversionResult {
        convert(lines: text.split(whereSeparator: \.isNewline).map(String.init))
    }

    public func convert(lines: [String]) -> ConversionResult {
        var stats = ConversionStats()
        var rules: [FilterRule] = []
        var advanced: [String] = []
        for line in Preprocessor.process(lines).lines {
            switch RuleParser.parse(line.text) {
            case .rule(let rule): rules.append(rule)
            case .advanced(let text): advanced.append(text)
            case .unsupported: stats.unsupportedRules += 1
            case .ignored: break
            }
        }
        var result = convert(rules: rules)
        result.advanced = advanced
        result.stats.advancedRules = advanced.count
        result.stats.unsupportedRules += stats.unsupportedRules
        return result
    }

    public func convert(rules input: [FilterRule]) -> ConversionResult {
        var stats = ConversionStats()
        stats.sourceRules = input.count

        // $badfilter disables the rule with the same text and options.
        var badfilters = Set<String>()
        for case .network(let rule) in input where rule.isBadfilter { badfilters.insert(rule.badfilterKey) }

        var genericHide: [CosmeticRule] = []
        var specificHide: [CosmeticRule] = []
        var cosmeticExceptions: [CosmeticRule] = []
        var stages = Stages()

        for rule in input {
            switch rule {
            case .cosmetic(let cosmetic):
                if cosmetic.isException {
                    cosmeticExceptions.append(cosmetic)
                } else if cosmetic.isGeneric {
                    genericHide.append(cosmetic)
                } else {
                    specificHide.append(cosmetic)
                }
            case .network(let network):
                if network.isBadfilter { continue }
                if badfilters.contains(network.badfilterKey) {
                    stats.badfiltered += 1
                    continue
                }
                if !route(network, into: &stages) { stats.unsupportedRules += 1 }
            }
        }

        let (generic, specific) = cosmeticRules(
            generic: genericHide, specific: specificHide, exceptions: cosmeticExceptions
        )
        stages.genericCSS = generic
        stages.specificCSS = specific

        let (ordered, truncated) = stages.ordered(limit: maxRules)
        stats.truncated = truncated
        stats.safariRules = ordered.count
        return ConversionResult(rules: ordered, advanced: [], stats: stats)
    }

    // MARK: Network rules

    /// Returns `false` when Safari cannot express the rule.
    private func route(_ rule: NetworkRule, into stages: inout Stages) -> Bool {
        if rule.isException && (rule.isDocumentException || rule.isElemhide || rule.isGenerichide) {
            guard let trigger = pageTrigger(for: rule) else { return false }
            let safari = SafariRule(trigger: trigger, action: .init(type: .ignorePreviousRules))
            if rule.isDocumentException {
                stages.documentExceptions.append(safari)
            } else if rule.isElemhide {
                stages.elemhideExceptions.append(safari)
            } else {
                stages.generichideExceptions.append(safari)
            }
            return true
        }

        guard let urlFilter = URLFilter.regex(for: rule) else { return false }
        var trigger = SafariRule.Trigger(urlFilter: urlFilter)
        if rule.matchCase { trigger.urlFilterIsCaseSensitive = true }
        if let types = rule.resourceTypes { trigger.resourceType = types.sorted().map(\.rawValue) }
        if rule.subdocumentOnly { trigger.loadContext = ["child-frame"] }
        if let thirdParty = rule.thirdParty { trigger.loadType = [thirdParty ? "third-party" : "first-party"] }
        applyDomains(permitted: rule.permittedDomains, restricted: rule.restrictedDomains, to: &trigger)

        let safari = SafariRule(trigger: trigger, action: .init(type: rule.isException ? .ignorePreviousRules : .block))
        switch (rule.isException, rule.isImportant) {
        case (false, false): stages.block.append(safari)
        case (true, false): stages.exceptions.append(safari)
        case (false, true): stages.importantBlock.append(safari)
        case (true, true): stages.documentExceptions.append(safari)
        }
        return true
    }

    /// Trigger for `$document` / `$elemhide` / `$generichide` exceptions: every request on the matching pages.
    private func pageTrigger(for rule: NetworkRule) -> SafariRule.Trigger? {
        var trigger = SafariRule.Trigger(urlFilter: URLFilter.matchAll)
        if rule.pattern.isEmpty {
            guard !rule.permittedDomains.isEmpty else { return nil }
            trigger.ifDomain = rule.permittedDomains.map { "*" + $0 }
        } else if let host = URLFilter.hostname(fromPattern: rule.pattern) {
            trigger.ifDomain = ["*" + host]
        } else {
            return nil
        }
        return trigger
    }

    /// Safari cannot mix `if-domain` and `unless-domain`; a permitted list wins.
    private func applyDomains(permitted: [String], restricted: [String], to trigger: inout SafariRule.Trigger) {
        if !permitted.isEmpty {
            trigger.ifDomain = permitted.map { "*" + $0 }
        } else if !restricted.isEmpty {
            trigger.unlessDomain = restricted.map { "*" + $0 }
        }
    }

    // MARK: Cosmetic rules

    private func cosmeticRules(
        generic: [CosmeticRule], specific: [CosmeticRule], exceptions: [CosmeticRule]
    ) -> (generic: [SafariRule], specific: [SafariRule]) {
        // Selector -> domains where hiding is disabled; an empty set means disabled everywhere.
        var disabled: [String: Set<String>] = [:]
        for exception in exceptions {
            if exception.permittedDomains.isEmpty {
                disabled[exception.selector] = []
            } else if disabled[exception.selector] != [] {
                disabled[exception.selector, default: []].formUnion(exception.permittedDomains)
            }
        }

        var batched: [String] = []
        var seen = Set<String>()
        var genericRules: [SafariRule] = []
        for rule in generic where seen.insert(rule.selector).inserted {
            var unless = Set(rule.restrictedDomains)
            if let off = disabled[rule.selector] {
                if off.isEmpty { continue }
                unless.formUnion(off)
            }
            if unless.isEmpty {
                batched.append(rule.selector)
            } else {
                var trigger = SafariRule.Trigger(urlFilter: URLFilter.matchAll)
                trigger.unlessDomain = unless.sorted().map { "*" + $0 }
                genericRules.append(SafariRule(trigger: trigger, action: .init(type: .cssDisplayNone, selector: rule.selector)))
            }
        }
        for start in stride(from: 0, to: batched.count, by: cssBatchSize) {
            let selector = batched[start..<min(start + cssBatchSize, batched.count)].joined(separator: ", ")
            genericRules.insert(
                SafariRule(trigger: .init(urlFilter: URLFilter.matchAll), action: .init(type: .cssDisplayNone, selector: selector)),
                at: start / cssBatchSize
            )
        }

        // Group site-specific selectors by identical domain sets.
        var groups: [[String]: [String]] = [:]
        var groupOrder: [[String]] = []
        for rule in specific {
            var domains = rule.permittedDomains
            if let off = disabled[rule.selector] {
                if off.isEmpty { continue }
                domains.removeAll { off.contains($0) }
                if domains.isEmpty { continue }
            }
            let key = Array(Set(domains)).sorted()
            if groups[key] == nil { groupOrder.append(key) }
            if groups[key, default: []].contains(rule.selector) == false { groups[key, default: []].append(rule.selector) }
        }
        var specificRules: [SafariRule] = []
        for key in groupOrder {
            let selectors = groups[key]!
            for start in stride(from: 0, to: selectors.count, by: cssBatchSize) {
                var trigger = SafariRule.Trigger(urlFilter: URLFilter.matchAll)
                trigger.ifDomain = key.map { "*" + $0 }
                let selector = selectors[start..<min(start + cssBatchSize, selectors.count)].joined(separator: ", ")
                specificRules.append(SafariRule(trigger: trigger, action: .init(type: .cssDisplayNone, selector: selector)))
            }
        }
        return (genericRules, specificRules)
    }
}

/// Safari evaluates rules top to bottom and `ignore-previous-rules` cancels everything above it,
/// so the order of these stages implements AdGuard's precedence.
private struct Stages {
    var genericCSS: [SafariRule] = []
    var generichideExceptions: [SafariRule] = []
    var specificCSS: [SafariRule] = []
    var elemhideExceptions: [SafariRule] = []
    var block: [SafariRule] = []
    var exceptions: [SafariRule] = []
    var importantBlock: [SafariRule] = []
    var documentExceptions: [SafariRule] = []

    /// Concatenates the stages, dropping duplicates and, if over `limit`,
    /// trimming blocking rules (never exceptions) from the least important stages first.
    func ordered(limit: Int) -> (rules: [SafariRule], truncated: Int) {
        var stages = [genericCSS, generichideExceptions, specificCSS, elemhideExceptions,
                      block, exceptions, importantBlock, documentExceptions].map(Self.deduplicated)
        var overflow = stages.reduce(0) { $0 + $1.count } - limit
        let truncated = max(overflow, 0)
        // Indices of blocking stages, cheapest to lose first.
        for index in [0, 2, 4, 6] where overflow > 0 {
            let cut = min(overflow, stages[index].count)
            stages[index].removeLast(cut)
            overflow -= cut
        }
        return (Array(stages.joined().prefix(limit)), truncated)
    }

    private static func deduplicated(_ rules: [SafariRule]) -> [SafariRule] {
        var seen = Set<SafariRule>()
        return rules.filter { seen.insert($0).inserted }
    }
}
