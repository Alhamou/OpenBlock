import Foundation

/// A filter-list line OpenBlock cannot use, with the reason.
public struct RuleIssue: Equatable, Sendable, Codable {
    public var line: String
    public var reason: String

    public init(line: String, reason: String) {
        self.line = line
        self.reason = reason
    }
}

/// Reports what a list contains, for the UI: how many rules are usable and which lines are dropped.
public enum ListInspector {
    public struct Report: Equatable, Sendable, Codable {
        public var rules = 0
        public var unsupported = 0
        /// The first `maxIssues` dropped lines.
        public var issues: [RuleIssue] = []

        public init() {}
    }

    /// Parses every line the way the converters do.
    public static func inspect(_ text: String, maxIssues: Int = 50) -> Report {
        var report = Report()
        func drop(_ line: String, _ reason: String) {
            report.unsupported += 1
            if report.issues.count < maxIssues { report.issues.append(RuleIssue(line: line, reason: reason)) }
        }
        for line in Preprocessor.process(text.split(whereSeparator: \.isNewline).map(String.init)).lines {
            switch RuleParser.parse(line.text) {
            case .rule:
                report.rules += 1
            case .advanced(let rule):
                if case .unsupported? = AdvancedCompiler.parse(rule) {
                    drop(line.text, "unsupported in-page rule")
                } else {
                    report.rules += 1
                }
            case .unsupported(let reason):
                drop(line.text, reason)
            case .ignored:
                break
            }
        }
        return report
    }
}
