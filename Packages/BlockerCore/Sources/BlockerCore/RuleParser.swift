import Foundation

/// Result of parsing a single filter-list line.
public enum ParsedLine: Equatable, Sendable {
    case rule(FilterRule)
    /// Comment, blank line or directive.
    case ignored
    /// Rule that needs a Safari Web Extension (scriptlets, CSS injection, extended CSS).
    case advanced(String)
    /// Rule Safari cannot express, with the reason.
    case unsupported(String)
}

public enum RuleParser {
    /// Cosmetic markers that a content blocker cannot handle, longest first.
    private static let advancedMarkers = ["#@$?#", "#$?#", "#@?#", "#?#", "#@$#", "#$#", "#@%#", "#%#", "##+js(", "#@#+js(", "##^", "#@#^"]

    /// Extended-CSS pseudo classes that Safari's selector engine does not know.
    private static let extendedPseudo = [
        ":has-text(", ":contains(", ":-abp-contains(", ":-abp-has(", ":matches-css", ":matches-attr(",
        ":matches-property(", ":xpath(", ":nth-ancestor(", ":upward(", ":remove(", ":style(", ":min-text-length(",
        ":if(", ":if-not(", ":-abp-properties(", ":watch-attr(", ":others(", ":matches-path(", ":remove-attr(",
        ":remove-class(",
    ]

    private static let unsupportedOptions: Set<String> = [
        "redirect", "redirect-rule", "removeparam", "removeheader", "csp", "replace", "hls", "jsonprune",
        "xmlprune", "header", "permissions", "cookie", "network", "app", "method", "to", "denyallow", "stealth",
        "empty", "mp4", "rewrite", "sitekey", "genericblock", "specifichide", "shide", "webrtc", "object",
        "object-subrequest", "urltransform", "extension", "jsinject", "content", "urlblock", "inline-script",
        "inline-font", "strict1p", "strict3p", "1p-strict", "3p-strict",
    ]

    public static func parse(_ rawLine: String) -> ParsedLine {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return .ignored }
        // A lone `#` line or `# comment` (hosts-style) is a comment.
        if line.hasPrefix("# ") || line == "#" { return .ignored }
        if line.contains("$$") || line.contains("$@$") { return .unsupported("HTML filtering") }

        if let hashIndex = line.firstIndex(of: "#") {
            let tail = line[hashIndex...]
            if advancedMarkers.contains(where: { tail.hasPrefix($0) }) { return .advanced(line) }
            if tail.hasPrefix("##") || tail.hasPrefix("#@#") {
                return parseCosmetic(line, at: hashIndex)
            }
        }
        return parseNetwork(line)
    }

    // MARK: Cosmetic

    private static func parseCosmetic(_ line: String, at hashIndex: String.Index) -> ParsedLine {
        let domainsPart = String(line[..<hashIndex])
        let isException = line[hashIndex...].hasPrefix("#@#")
        let selector = String(line[line.index(hashIndex, offsetBy: isException ? 3 : 2)...])
            .trimmingCharacters(in: .whitespaces)

        if selector.isEmpty { return .unsupported("empty selector") }
        if extendedPseudo.contains(where: { selector.contains($0) }) { return .advanced(line) }
        if selector.contains("{") || selector.contains("}") { return .unsupported("invalid selector") }
        if !selector.allSatisfy(\.isASCII) { return .unsupported("non-ASCII selector") }

        var rule = CosmeticRule(selector: selector)
        rule.isException = isException
        if !domainsPart.isEmpty {
            guard let (permitted, restricted) = parseDomains(domainsPart, separator: ",") else {
                return .unsupported("unsupported domain")
            }
            rule.permittedDomains = permitted
            rule.restrictedDomains = restricted
        }
        return .rule(.cosmetic(rule))
    }

    // MARK: Network

    private static func parseNetwork(_ line: String) -> ParsedLine {
        var text = Substring(line)
        let isException = text.hasPrefix("@@")
        if isException { text = text.dropFirst(2) }

        var pattern = text
        var optionsText: Substring?
        if let dollar = text.lastIndex(of: "$") {
            let candidate = text[text.index(after: dollar)...]
            let looksLikeRegexEnd = text.hasPrefix("/") && (candidate.isEmpty || candidate.hasSuffix("/"))
            if !looksLikeRegexEnd {
                pattern = text[..<dollar]
                optionsText = candidate
            }
        }

        var rule = NetworkRule(pattern: String(pattern))
        rule.isException = isException

        if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            rule.isRegex = true
        } else if pattern.isEmpty || pattern == "*" || pattern == "|" || pattern == "||" {
            // Allowed only together with a $domain option or as an exception modifier.
            rule.pattern = ""
        }

        var positiveTypes = Set<ResourceType>()
        var negativeTypes = Set<ResourceType>()
        var onlySubdocument = true
        var hasDocumentType = false

        if let optionsText {
            var normalized: [String] = []
            for rawOption in optionsText.split(separator: ",") {
                let option = rawOption.trimmingCharacters(in: .whitespaces)
                if option.isEmpty { continue }
                let negated = option.hasPrefix("~")
                let body = negated ? String(option.dropFirst()) : option
                let name: String
                let value: String?
                if let eq = body.firstIndex(of: "=") {
                    name = body[..<eq].lowercased()
                    value = String(body[body.index(after: eq)...])
                } else {
                    name = body.lowercased()
                    value = nil
                }
                if name == "badfilter" { rule.isBadfilter = true; continue }
                normalized.append(option)

                if unsupportedOptions.contains(name) { return .unsupported("$\(name)") }

                if let type = resourceType(for: name) {
                    if name != "subdocument" && name != "frame" { onlySubdocument = false }
                    if negated { negativeTypes.formUnion(type) } else { positiveTypes.formUnion(type) }
                    continue
                }

                switch name {
                case "third-party", "3p":
                    rule.thirdParty = !negated
                case "first-party", "1p":
                    rule.thirdParty = negated
                case "match-case":
                    rule.matchCase = !negated
                case "important":
                    rule.isImportant = true
                case "all":
                    break
                case "popup":
                    positiveTypes.insert(.popup)
                    onlySubdocument = false
                case "document", "doc":
                    hasDocumentType = true
                    onlySubdocument = false
                case "elemhide", "ehide":
                    rule.isElemhide = true
                case "generichide", "ghide":
                    rule.isGenerichide = true
                case "domain", "from":
                    guard let value, let (permitted, restricted) = parseDomains(value, separator: "|") else {
                        return .unsupported("unsupported $domain")
                    }
                    rule.permittedDomains = permitted
                    rule.restrictedDomains = restricted
                default:
                    return .unsupported("$\(name)")
                }
            }
            rule.normalizedOptions = normalized.sorted()
        }

        if hasDocumentType {
            guard isException else { return .unsupported("blocking $document") }
            rule.isDocumentException = true
        }
        if !positiveTypes.isEmpty {
            rule.resourceTypes = positiveTypes.subtracting(negativeTypes)
            rule.subdocumentOnly = onlySubdocument && positiveTypes == [.document]
        } else if !negativeTypes.isEmpty {
            rule.resourceTypes = ResourceType.universe.subtracting(negativeTypes)
        }
        if rule.resourceTypes?.isEmpty == true { return .unsupported("no resource types left") }

        let pageLevel = rule.isDocumentException || rule.isElemhide || rule.isGenerichide
        if !isException && (rule.isElemhide || rule.isGenerichide) { return .ignored }
        if rule.pattern.isEmpty && rule.permittedDomains.isEmpty && !pageLevel {
            return .unsupported("rule matches everything")
        }
        if rule.pattern.count < 3 && !rule.isRegex && rule.permittedDomains.isEmpty && !pageLevel {
            return .unsupported("pattern too short")
        }
        return .rule(.network(rule))
    }

    private static func resourceType(for option: String) -> Set<ResourceType>? {
        switch option {
        case "script": [.script]
        case "image": [.image]
        case "stylesheet", "css": [.styleSheet]
        case "font": [.font]
        case "media": [.media]
        case "xmlhttprequest", "xhr", "websocket", "ping", "other", "fetch": [.raw]
        case "subdocument", "frame": [.document]
        default: nil
        }
    }

    /// Parses `a.com,~b.a.com` (cosmetic) or `a.com|~b.com` ($domain).
    /// Domains Safari cannot express (wildcard TLDs, regexes, non-ASCII) are dropped;
    /// returns `nil` when nothing usable remains.
    static func parseDomains(_ text: String, separator: Character) -> ([String], [String])? {
        var permitted: [String] = []
        var restricted: [String] = []
        var hadPermitted = false
        for raw in text.split(separator: separator) {
            var domain = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() } else { hadPermitted = true }
            guard isValidDomain(domain) else { continue }
            if negated { restricted.append(domain) } else { permitted.append(domain) }
        }
        // Dropping every permitted domain would turn a site-specific rule into a generic one.
        if hadPermitted && permitted.isEmpty { return nil }
        if restricted.isEmpty && permitted.isEmpty { return nil }
        return (permitted, restricted)
    }

    private static let domainCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_")

    static func isValidDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain.allSatisfy(domainCharacters.contains) && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}
