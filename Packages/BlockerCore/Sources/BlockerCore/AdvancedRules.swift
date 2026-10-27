import Foundation

/// Rules that content blockers cannot express and the OpenBlock Advanced web extension applies
/// inside the page: CSS injection (`#$#`), extended CSS (`#?#`, `#$?#`, `##` with `:has-text()` …),
/// scriptlets (`#%#//scriptlet(...)`, `##+js(...)`) and raw JavaScript (`#%#code`).
///
/// The extension looks rules up by hostname and its parent domains: `rules` maps a domain to indices
/// into `entries` (each rule is stored once even when it lists many domains); the `""` key holds
/// generic rules.
public struct AdvancedRuleset: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Plain CSS rule injected as a user stylesheet: `selector { declarations }`.
        case css
        /// ExtendedCss rule, `selector { declarations }` or an action rule such as `sel:remove()`.
        case ext
        case scriptlet
        /// Raw JavaScript, only accepted from trusted sources.
        case js
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var t: Kind
        /// CSS/JS text; the scriptlet name for scriptlets.
        public var c: String
        /// Scriptlet arguments.
        public var a: [String]?
        /// Domains (and their subdomains) where a domain-indexed rule does not apply.
        public var x: [String]?
    }

    /// Page-level switches from `$document`, `$elemhide`, `$generichide`, `$jsinject` exceptions and the allowlist.
    public enum PageFlag: String, Codable, Sendable, Comparable {
        case all, elemhide, generichide, jsinject

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var version = 1
    public var entries: [Entry] = []
    public var rules: [String: [Int]] = [:]
    public var exceptions: [String: [Entry]] = [:]
    public var pages: [String: [PageFlag]] = [:]

    public var ruleCount: Int { entries.count }

    /// Rules indexed under `domain`, resolved.
    public func rules(for domain: String) -> [Entry]? { rules[domain]?.map { entries[$0] } }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(self)
    }
}

public struct AdvancedStats: Equatable, Sendable, Codable {
    public var rules = 0
    public var exceptions = 0
    public var unsupported = 0
    public var untrustedRejected = 0

    public init() {}
}

public enum AdvancedCompiler {
    public struct Line: Sendable {
        public var text: String
        /// Lists that may run arbitrary JavaScript (`#%#code`, `trusted-*` scriptlets).
        public var trusted: Bool

        public init(text: String, trusted: Bool) {
            self.text = text
            self.trusted = trusted
        }
    }

    public static func compile(_ lines: [Line], allowlist: [String] = []) -> (AdvancedRuleset, AdvancedStats) {
        var ruleset = AdvancedRuleset()
        var stats = AdvancedStats()
        var seenRules = Set<String>()
        var pages: [String: Set<AdvancedRuleset.PageFlag>] = [:]

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("@@") {
                if let (hosts, flags) = pageException(text) {
                    for host in hosts { pages[host, default: []].formUnion(flags) }
                }
                continue
            }
            guard let parsed = parse(text) else { continue }
            switch parsed {
            case .unsupported:
                stats.unsupported += 1
            case .rule(var entry, let isException, let permitted, let restricted):
                if !line.trusted && isTrustedOnly(entry) {
                    stats.untrustedRejected += 1
                    continue
                }
                guard seenRules.insert(text).inserted else { continue }
                if isException {
                    stats.exceptions += 1
                    for key in permitted.isEmpty ? [""] : permitted {
                        ruleset.exceptions[key, default: []].append(entry)
                    }
                } else {
                    stats.rules += 1
                    if !restricted.isEmpty { entry.x = restricted }
                    ruleset.entries.append(entry)
                    for key in permitted.isEmpty ? [""] : permitted {
                        ruleset.rules[key, default: []].append(ruleset.entries.count - 1)
                    }
                }
            }
        }

        for domain in allowlist.map({ $0.lowercased() }) where RuleParser.isValidDomain(domain) {
            pages[domain, default: []].insert(.all)
        }
        ruleset.pages = pages.mapValues { $0.sorted() }
        return (ruleset, stats)
    }

    private static func isTrustedOnly(_ entry: AdvancedRuleset.Entry) -> Bool {
        entry.t == .js || (entry.t == .scriptlet && entry.c.hasPrefix("trusted-"))
    }

    // MARK: Parsing

    enum Parsed: Equatable {
        case rule(AdvancedRuleset.Entry, isException: Bool, permitted: [String], restricted: [String])
        case unsupported
    }

    /// Marker → (kind, isException). Longer markers first so `#@$?#` is not read as `#@#`.
    private static let markers: [(String, AdvancedRuleset.Kind, Bool)] = [
        ("#@$?#", .ext, true), ("#$?#", .ext, false),
        ("#@?#", .ext, true), ("#?#", .ext, false),
        ("#@$#", .css, true), ("#$#", .css, false),
        ("#@%#", .js, true), ("#%#", .js, false),
        ("#@#+js(", .scriptlet, true), ("##+js(", .scriptlet, false),
        ("#@#", .ext, true), ("##", .ext, false),
    ]

    /// Returns `nil` for lines that are not advanced cosmetic rules.
    static func parse(_ text: String) -> Parsed? {
        guard let hashIndex = text.firstIndex(of: "#") else { return nil }
        let tail = text[hashIndex...]
        guard let (marker, kind, isException) = markers.first(where: { tail.hasPrefix($0.0) }) else { return nil }
        if tail.hasPrefix("##^") || tail.hasPrefix("#@#^") { return .unsupported }

        let body = String(tail.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        var permitted: [String] = []
        var restricted: [String] = []
        let domainsText = String(text[..<hashIndex])
        if !domainsText.isEmpty {
            guard let domains = RuleParser.parseDomains(domainsText, separator: ",") else { return .unsupported }
            (permitted, restricted) = domains
        }

        let entry: AdvancedRuleset.Entry?
        switch (marker, kind) {
        case (_, .scriptlet):
            entry = uboScriptlet(body)
        case (_, .js):
            if body.hasPrefix("//scriptlet(") {
                entry = adguardScriptlet(body)
            } else {
                entry = body.isEmpty ? nil : .init(t: .js, c: body)
            }
        case (_, .css):
            entry = cssInjection(body).map { .init(t: .css, c: $0) }
        case ("##", _), ("#@#", _):
            // Plain selectors belong to the content blockers; only extended ones come here.
            guard RuleParser.parse(text) == .advanced(text) else { return nil }
            entry = extendedHiding(body).map { .init(t: .ext, c: $0) }
        case ("#$?#", _), ("#@$?#", _):
            entry = cssInjection(body).map { .init(t: .ext, c: $0) }
        default: // #?#
            entry = extendedHiding(body).map { .init(t: .ext, c: $0) }
        }
        guard let entry else { return .unsupported }
        return .rule(entry, isException: isException, permitted: permitted, restricted: restricted)
    }

    /// `selector { declarations }`. Rejects `url()` and at-rules, which could load remote content.
    static func cssInjection(_ body: String) -> String? {
        guard let open = body.firstIndex(of: "{"), body.hasSuffix("}"), open != body.startIndex else {
            return body.contains(":remove()") ? body : nil
        }
        let lowered = body.lowercased()
        if lowered.contains("url(") || lowered.contains("@import") || lowered.contains("expression(") || body.hasPrefix("@") {
            return nil
        }
        return body
    }

    /// An extended selector that hides matches; uBO's `:style()` and `:remove()` become ExtendedCss rules.
    static func extendedHiding(_ selector: String) -> String? {
        if selector.isEmpty || selector.contains("{") { return nil }
        if selector.hasSuffix(":remove()") { return selector }
        if let range = selector.range(of: ":style(", options: .backwards), selector.hasSuffix(")") {
            let declarations = selector[range.upperBound..<selector.index(before: selector.endIndex)]
            return cssInjection("\(selector[..<range.lowerBound]) { \(declarations) }")
        }
        return "\(selector) { display: none !important; }"
    }

    /// `//scriptlet('name', 'arg', "arg")`
    static func adguardScriptlet(_ body: String) -> AdvancedRuleset.Entry? {
        guard body.hasSuffix(")") else { return nil }
        let inner = body.dropFirst("//scriptlet(".count).dropLast()
        var args: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in inner {
            if let open = quote {
                if escaped { current.append(character); escaped = false }
                else if character == "\\" { escaped = true }
                else if character == open { args.append(current); current = ""; quote = nil }
                else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character != "," && !character.isWhitespace {
                return nil
            }
        }
        if quote != nil { return nil }
        // An exception with no arguments (`#@%#//scriptlet()`) disables every scriptlet.
        guard let name = args.first else { return .init(t: .scriptlet, c: "", a: []) }
        return .init(t: .scriptlet, c: name, a: Array(args.dropFirst()))
    }

    /// `+js(name, arg1, arg2)` with `\,` escaping commas.
    static func uboScriptlet(_ body: String) -> AdvancedRuleset.Entry? {
        guard body.hasSuffix(")") else { return nil }
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in body.dropLast() {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "," { parts.append(current); current = "" }
            else { current.append(character) }
        }
        parts.append(current)
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = trimmed.first, !name.isEmpty else { return .init(t: .scriptlet, c: "", a: []) }
        let normalized = name.hasSuffix(".js") ? name : name + ".js"
        return .init(t: .scriptlet, c: normalized.hasPrefix("ubo-") ? normalized : "ubo-" + normalized,
                     a: Array(trimmed.dropFirst()))
    }

    /// `@@||example.com^$document,elemhide` → hosts and the page flags they switch off.
    static func pageException(_ text: String) -> ([String], Set<AdvancedRuleset.PageFlag>)? {
        guard let dollar = text.lastIndex(of: "$") else { return nil }
        let pattern = String(text[text.index(text.startIndex, offsetBy: 2)..<dollar])
        var flags = Set<AdvancedRuleset.PageFlag>()
        var hosts: [String] = []
        for option in text[text.index(after: dollar)...].split(separator: ",") {
            let lower = option.lowercased()
            switch lower {
            case "document", "doc", "all": flags.insert(.all)
            case "elemhide", "ehide": flags.insert(.elemhide)
            case "generichide", "ghide": flags.insert(.generichide)
            case "jsinject", "content": flags.insert(.jsinject)
            default:
                if lower.hasPrefix("domain="),
                   let (permitted, _) = RuleParser.parseDomains(String(option.dropFirst(7)), separator: "|") {
                    hosts = permitted
                }
            }
        }
        if flags.isEmpty { return nil }
        if !pattern.isEmpty {
            guard let host = URLFilter.hostname(fromPattern: pattern) else { return nil }
            hosts = [host]
        }
        return hosts.isEmpty ? nil : (hosts, flags)
    }
}
