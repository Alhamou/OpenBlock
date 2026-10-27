import BlockerCore
import Foundation
import WebKit

// Usage: obconvert <list.txt>... [--out rules.json] [--verify]
//
// Converts AdBlock-syntax filter lists into Safari content-blocker JSON and, with --verify,
// compiles the result with WKContentRuleListStore — the same compiler Safari uses.

var inputs: [String] = []
var outPath: String?
var verify = false
var advancedOut: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--out": outPath = arguments.next()
    case "--verify": verify = true
    case "--advanced": advancedOut = arguments.next()
    default: inputs.append(argument)
    }
}
guard !inputs.isEmpty else {
    FileHandle.standardError.write(Data("usage: obconvert <list.txt>... [--out rules.json] [--verify] [--advanced advanced.json]\n".utf8))
    exit(2)
}

var lines: [String] = []
for path in inputs {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    lines += text.split(whereSeparator: \.isNewline).map(String.init)
}

let started = Date()
let result = Converter().convert(lines: lines)
let data = try result.rules.jsonData()
let stats = result.stats
print("""
input lines:      \(lines.count)
source rules:     \(stats.sourceRules)
safari rules:     \(stats.safariRules)
advanced (phase2):\(stats.advancedRules)
unsupported:      \(stats.unsupportedRules)
badfiltered:      \(stats.badfiltered)
truncated:        \(stats.truncated)
json size:        \(data.count / 1024) KB
convert time:     \(String(format: "%.2f", Date().timeIntervalSince(started)))s
""")
if let outPath { try data.write(to: URL(fileURLWithPath: outPath)) }

if let advancedOut {
    let (ruleset, advancedStats) = AdvancedCompiler.compile(lines.map { .init(text: $0, trusted: true) })
    let advancedData = try ruleset.jsonData()
    try advancedData.write(to: URL(fileURLWithPath: advancedOut))
    print("advanced rules:   \(advancedStats.rules) (+\(advancedStats.exceptions) exceptions, \(advancedStats.unsupported) unsupported, \(advancedData.count / 1024) KB)")
}

if verify {
    let json = String(decoding: data, as: UTF8.self)
    let compileStart = Date()
    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    DispatchQueue.main.async {
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "obconvert-verify", encodedContentRuleList: json) { list, error in
            failure = error
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "obconvert-verify") { _ in done.signal() }
        }
    }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if let failure {
        print("WebKit compile:   FAILED — \(failure)")
        exit(1)
    }
    print("WebKit compile:   OK (\(String(format: "%.1f", Date().timeIntervalSince(compileStart)))s)")
}
