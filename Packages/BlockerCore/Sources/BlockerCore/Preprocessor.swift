import Foundation

/// The content blockers OpenBlock ships. Safari limits each one to 150k rules,
/// so filter lists are spread across them like AdGuard does.
public enum BlockerCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case ads
    case privacy
    case annoyances
    case custom

    public var id: String { rawValue }

    /// Maps AdGuard's `!#safari_cb_affinity(...)` names onto OpenBlock blockers.
    static func fromAffinity(_ name: String) -> [BlockerCategory] {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "general": [.ads]
        case "privacy": [.privacy]
        case "social", "other", "security": [.annoyances]
        case "custom": [.custom]
        case "all": BlockerCategory.allCases
        default: []
        }
    }
}

/// Resolves list-level directives:
/// - `!#if (condition)` / `!#else` / `!#endif`, evaluated as the Safari extension platform
/// - `!#safari_cb_affinity(privacy,general)` … `!#safari_cb_affinity`, which sends the enclosed
///   rules to specific content blockers instead of the list's own blocker
public enum Preprocessor {
    public struct Line: Equatable, Sendable {
        public var text: String
        /// `nil` = the blocker that owns the list.
        public var affinity: Set<BlockerCategory>?
    }

    public struct Output: Sendable {
        public var lines: [Line]
    }

    static let platformConstants: Set<String> = ["adguard", "adguard_ext_safari"]

    public static func process(_ lines: [String]) -> Output {
        var output: [Line] = []
        output.reserveCapacity(lines.count)
        // Each entry: (branch active, any branch taken so far, parent active)
        var conditions: [(active: Bool, taken: Bool, parent: Bool)] = []
        var affinity: Set<BlockerCategory>?
        var active: Bool { conditions.last?.active ?? true }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#") {
                if line.hasPrefix("!#if") {
                    let parent = active
                    let value = parent && evaluate(String(line.dropFirst(4)))
                    conditions.append((value, value, parent))
                } else if line.hasPrefix("!#else"), let last = conditions.popLast() {
                    conditions.append((last.parent && !last.taken, true, last.parent))
                } else if line.hasPrefix("!#endif") {
                    _ = conditions.popLast()
                } else if line.hasPrefix("!#safari_cb_affinity"), active {
                    if let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")") {
                        let names = line[line.index(after: open)..<close].split(separator: ",")
                        affinity = Set(names.flatMap { BlockerCategory.fromAffinity(String($0)) })
                    } else {
                        affinity = nil
                    }
                }
                continue
            }
            if active { output.append(Line(text: raw, affinity: affinity)) }
        }
        return Output(lines: output)
    }

    // MARK: Condition evaluation: identifiers, !, &&, ||, parentheses

    static func evaluate(_ expression: String) -> Bool {
        var parser = ConditionParser(tokens: tokenize(expression))
        return parser.parseOr()
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == ")" || c == "!" {
                flush(); tokens.append(String(c))
            } else if (c == "&" || c == "|"), i + 1 < chars.count, chars[i + 1] == c {
                flush(); tokens.append(String([c, c])); i += 1
            } else if c.isWhitespace {
                flush()
            } else {
                current.append(c)
            }
            i += 1
        }
        flush()
        return tokens
    }

    private struct ConditionParser {
        var tokens: [String]
        var index = 0

        mutating func next() -> String? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        func peek() -> String? { index < tokens.count ? tokens[index] : nil }

        mutating func parseOr() -> Bool {
            var value = parseAnd()
            while peek() == "||" { _ = next(); value = parseAnd() || value }
            return value
        }

        mutating func parseAnd() -> Bool {
            var value = parseUnary()
            while peek() == "&&" { _ = next(); value = parseUnary() && value }
            return value
        }

        mutating func parseUnary() -> Bool {
            switch next() {
            case "!": return !parseUnary()
            case "(":
                let value = parseOr()
                if peek() == ")" { _ = next() }
                return value
            case let identifier?: return Preprocessor.platformConstants.contains(identifier)
            case nil: return false
            }
        }
    }
}
