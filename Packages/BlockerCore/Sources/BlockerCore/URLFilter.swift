import Foundation

/// Translates AdBlock URL patterns into the regex subset accepted by WebKit's content-blocker compiler.
///
/// WebKit supports: `.` `*` `+` `?` `[...]` `[^...]` `(...)`, `^` at the start and `$` at the end.
/// It rejects alternation `|`, counted repetition `{n}`, shorthand classes such as `\d`, and look-around.
enum URLFilter {
    /// `||` — scheme followed by any number of subdomains.
    static let domainStart = #"^[a-z][a-z0-9.+-]*://([a-z0-9_-]+\.)*"#
    /// `^` in the middle of a pattern: a single separator character.
    static let separator = #"[^a-zA-Z0-9_.%-]"#
    /// `^` at the end of a pattern: a separator or the end of the URL.
    static let trailingSeparator = #"([^a-zA-Z0-9_.%-].*)?$"#
    static let matchAll = ".*"

    private static let specials: Set<Character> = [".", "+", "?", "{", "}", "(", ")", "[", "]", "\\", "$", "|"]

    static func regex(for rule: NetworkRule) -> String? {
        rule.isRegex ? fromRegex(rule.pattern) : fromPattern(rule.pattern)
    }

    static func fromPattern(_ pattern: String) -> String? {
        if pattern.isEmpty { return matchAll }
        guard pattern.allSatisfy(\.isASCII) else { return nil }

        var body = Substring(pattern)
        var out = ""
        if body.hasPrefix("||") {
            out = domainStart
            body = body.dropFirst(2)
        } else if body.hasPrefix("|") {
            out = "^"
            body = body.dropFirst()
        }
        var anchoredEnd = false
        if body.hasSuffix("|") {
            anchoredEnd = true
            body = body.dropLast()
        }

        let characters = Array(body)
        for (index, character) in characters.enumerated() {
            switch character {
            case "*":
                if !out.hasSuffix(".*") { out += ".*" }
            case "^":
                if index == characters.count - 1 {
                    out += trailingSeparator
                    return out
                }
                out += separator
            case "|":
                return nil
            default:
                if specials.contains(character) { out += "\\" }
                out.append(character)
            }
        }
        if anchoredEnd { out += "$" }
        // A leading/trailing `.*` adds nothing to a substring match and slows compilation.
        if out.hasPrefix(".*") { out.removeFirst(2) }
        if out.hasSuffix(".*") && !out.hasSuffix("\\.*") { out.removeLast(2) }
        return out.isEmpty ? matchAll : out
    }

    /// Accepts `/regex/` rules only when WebKit can compile them.
    static func fromRegex(_ pattern: String) -> String? {
        var body = String(pattern.dropFirst().dropLast())
        body = body.replacingOccurrences(of: "\\/", with: "/")
        guard body.allSatisfy(\.isASCII), !body.isEmpty else { return nil }

        let unsupported = ["{", "(?", "\\d", "\\D", "\\w", "\\W", "\\s", "\\S", "\\b", "\\B", "\\u", "\\x"]
        if unsupported.contains(where: body.contains) { return nil }

        // Reject unescaped `|`, and `^`/`$` anchors in the middle.
        var escaped = false
        var inClass = false
        let characters = Array(body)
        for (index, character) in characters.enumerated() {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "[": inClass = true
            case "]": inClass = false
            case "|" where !inClass: return nil
            case "^" where !inClass && index != 0: return nil
            case "$" where !inClass && index != characters.count - 1: return nil
            default: break
            }
        }
        return body
    }

    /// `||example.com^` style patterns that name exactly one host, used for page-level exceptions.
    static func hostname(fromPattern pattern: String) -> String? {
        var body = Substring(pattern)
        guard body.hasPrefix("||") else { return nil }
        body = body.dropFirst(2)
        while body.hasSuffix("^") || body.hasSuffix("/") || body.hasSuffix("|") { body = body.dropLast() }
        let host = body.lowercased()
        return RuleParser.isValidDomain(host) ? host : nil
    }
}
