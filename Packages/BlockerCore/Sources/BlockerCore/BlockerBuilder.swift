import Foundation

/// A downloaded filter list and the content blocker it belongs to.
public struct FilterListSource: Sendable {
    public var name: String
    public var category: BlockerCategory
    public var text: String
    /// Trusted sources may run JavaScript in pages (`#%#` rules, `trusted-*` scriptlets).
    public var isTrusted: Bool

    public init(name: String, category: BlockerCategory, text: String, isTrusted: Bool = false) {
        self.name = name
        self.category = category
        self.text = text
        self.isTrusted = isTrusted
    }
}

/// Builds the rule list for every content blocker from all enabled sources.
public struct BlockerBuilder: Sendable {
    public var converter: Converter

    public init(converter: Converter = Converter()) {
        self.converter = converter
    }

    /// - Parameters:
    ///   - allowlist: domains where OpenBlock is disabled; added to every blocker
    ///     because Safari's content blockers cannot see each other's exceptions.
    public func build(sources: [FilterListSource], allowlist: [String]) -> [BlockerCategory: ConversionResult] {
        var lines: [BlockerCategory: [String]] = [:]
        for source in sources {
            let processed = Preprocessor.process(source.text.split(whereSeparator: \.isNewline).map(String.init))
            for line in processed.lines {
                for category in line.affinity ?? [source.category] {
                    lines[category, default: []].append(line.text)
                }
            }
        }

        let allowRules = allowlist
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter(RuleParser.isValidDomain)
            .map { "@@||\($0)^$document" }

        var results: [BlockerCategory: ConversionResult] = [:]
        for category in BlockerCategory.allCases {
            results[category] = converter.convert(lines: (lines[category] ?? []) + allowRules)
        }
        return results
    }

    /// Collects every source's advanced rules (and page-level exceptions) into one ruleset
    /// for the OpenBlock Advanced web extension.
    public func buildAdvanced(sources: [FilterListSource], allowlist: [String]) -> (AdvancedRuleset, AdvancedStats) {
        var lines: [AdvancedCompiler.Line] = []
        for source in sources {
            let processed = Preprocessor.process(source.text.split(whereSeparator: \.isNewline).map(String.init))
            lines += processed.lines.map { AdvancedCompiler.Line(text: $0.text, trusted: source.isTrusted) }
        }
        return AdvancedCompiler.compile(lines, allowlist: allowlist)
    }
}
