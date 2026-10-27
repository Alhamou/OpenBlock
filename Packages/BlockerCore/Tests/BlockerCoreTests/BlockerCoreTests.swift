@testable import BlockerCore
import XCTest

final class URLFilterTests: XCTestCase {
    func testDomainAnchorWithSeparator() {
        XCTAssertEqual(
            URLFilter.fromPattern("||ads.example.com^"),
            #"^[a-z][a-z0-9.+-]*://([a-z0-9_-]+\.)*ads\.example\.com([^a-zA-Z0-9_.%-].*)?$"#
        )
    }

    func testWildcardsAndAnchors() {
        XCTAssertEqual(URLFilter.fromPattern("/banner/*/img"), "/banner/.*/img")
        XCTAssertEqual(URLFilter.fromPattern("|https://x.com/ad.js|"), #"^https://x\.com/ad\.js$"#)
        XCTAssertEqual(URLFilter.fromPattern("*ad*"), "ad")
        XCTAssertNil(URLFilter.fromPattern("a|b"))
    }

    func testRegexSubset() {
        XCTAssertEqual(URLFilter.fromRegex(#"/^https?:\/\/ads\./"#), #"^https?://ads\."#)
        XCTAssertNil(URLFilter.fromRegex("/ad(s|v)/"))
        XCTAssertNil(URLFilter.fromRegex(#"/\d{3}/"#))
    }

    func testHostname() {
        XCTAssertEqual(URLFilter.hostname(fromPattern: "||Example.com^"), "example.com")
        XCTAssertNil(URLFilter.hostname(fromPattern: "||example.com/path"))
    }
}

final class RuleParserTests: XCTestCase {
    func testNetworkOptions() throws {
        guard case .rule(.network(let rule)) = RuleParser.parse("||ads.com^$third-party,script,domain=a.com|~b.a.com") else {
            return XCTFail("not a network rule")
        }
        XCTAssertEqual(rule.thirdParty, true)
        XCTAssertEqual(rule.resourceTypes, [.script])
        XCTAssertEqual(rule.permittedDomains, ["a.com"])
        XCTAssertEqual(rule.restrictedDomains, ["b.a.com"])
    }

    func testNegatedTypes() {
        guard case .rule(.network(let rule)) = RuleParser.parse("||ads.com^$~script,~image") else { return XCTFail() }
        XCTAssertEqual(rule.resourceTypes, ResourceType.universe.subtracting([.script, .image]))
    }

    func testCosmetic() {
        guard case .rule(.cosmetic(let rule)) = RuleParser.parse("example.com,~sub.example.com##.ad") else { return XCTFail() }
        XCTAssertEqual(rule.selector, ".ad")
        XCTAssertEqual(rule.permittedDomains, ["example.com"])
        XCTAssertEqual(rule.restrictedDomains, ["sub.example.com"])
    }

    func testClassification() {
        XCTAssertEqual(RuleParser.parse("! comment"), .ignored)
        XCTAssertEqual(RuleParser.parse("[Adblock Plus 2.0]"), .ignored)
        XCTAssertEqual(RuleParser.parse("example.com#%#//scriptlet('abort-on-property-read', 'x')"), .advanced("example.com#%#//scriptlet('abort-on-property-read', 'x')"))
        XCTAssertEqual(RuleParser.parse("example.com#$#body { overflow: auto; }"), .advanced("example.com#$#body { overflow: auto; }"))
        XCTAssertEqual(RuleParser.parse("example.com##div:has-text(Ad)"), .advanced("example.com##div:has-text(Ad)"))
        XCTAssertEqual(RuleParser.parse("||x.com^$redirect=noopjs"), .unsupported("$redirect"))
        XCTAssertEqual(RuleParser.parse("||x.com^$document"), .unsupported("blocking $document"))
        // Wildcard TLDs cannot be expressed, so a site-specific rule must not become generic.
        XCTAssertEqual(RuleParser.parse("example.*##.ad"), .unsupported("unsupported domain"))
    }

    func testRegexRuleKeepsDollar() {
        guard case .rule(.network(let rule)) = RuleParser.parse("/ads\\.js$/") else { return XCTFail() }
        XCTAssertTrue(rule.isRegex)
        XCTAssertEqual(rule.pattern, "/ads\\.js$/")
    }
}

final class ConverterTests: XCTestCase {
    private func convert(_ lines: String...) -> [SafariRule] {
        Converter().convert(lines: lines).rules
    }

    func testOrderingImplementsPrecedence() {
        let rules = convert(
            "@@||site.com^$document",
            "||important.com^$important",
            "@@||cdn.com/ads.js",
            "||ads.com^",
            "example.com##.banner",
            "##.ad",
            "@@||news.com^$generichide"
        )
        XCTAssertEqual(rules.map(\.action.type), [
            .cssDisplayNone,      // generic CSS
            .ignorePreviousRules, // generichide
            .cssDisplayNone,      // specific CSS
            .block,               // network block
            .ignorePreviousRules, // network exception
            .block,               // important block
            .ignorePreviousRules, // document exception
        ])
        XCTAssertEqual(rules.last?.trigger.ifDomain, ["*site.com"])
    }

    func testGenericSelectorsAreBatched() {
        let rules = Converter(cssBatchSize: 2).convert(lines: ["##.a", "##.b", "##.c", "##.a"]).rules
        XCTAssertEqual(rules.compactMap(\.action.selector), [".a, .b", ".c"])
    }

    func testCosmeticExceptions() {
        let rules = convert("##.ad", "##.gone", "#@#.gone", "a.com,b.com##.x", "a.com#@#.x", "news.com#@#.ad")
        let byselector = Dictionary(uniqueKeysWithValues: rules.map { ($0.action.selector!, $0.trigger) })
        XCTAssertNil(byselector[".gone"])
        XCTAssertEqual(byselector[".ad"]?.unlessDomain, ["*news.com"])
        XCTAssertEqual(byselector[".x"]?.ifDomain, ["*b.com"])
    }

    func testBadfilter() {
        let result = Converter().convert(lines: ["||ads.com^$script", "||ads.com^$script,badfilter", "||other.com^"])
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.stats.badfiltered, 1)
    }

    func testTruncationKeepsExceptions() {
        let result = Converter(maxRules: 3).convert(lines: ["||a.com^", "||b.com^", "||c.com^", "@@||d.com^$document"])
        XCTAssertEqual(result.rules.count, 3)
        XCTAssertEqual(result.rules.last?.action.type, .ignorePreviousRules)
        XCTAssertEqual(result.stats.truncated, 1)
    }

    func testEmptyListProducesPlaceholder() throws {
        let json = try [SafariRule]().jsonData()
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("openblock-placeholder"))
    }
}

final class PreprocessorTests: XCTestCase {
    func testConditions() {
        let output = Preprocessor.process([
            "!#if adguard_ext_safari", "safari", "!#else", "other", "!#endif",
            "!#if (adguard_ext_chromium || adguard_app_windows)", "chrome", "!#endif",
            "!#if !adguard_ext_firefox && adguard", "notfirefox", "!#endif",
        ])
        XCTAssertEqual(output.lines.map(\.text), ["safari", "notfirefox"])
    }

    func testAffinityRoutesToOtherBlockers() {
        let source = FilterListSource(name: "base", category: .ads, text: """
        ||ads.com^
        !#safari_cb_affinity(privacy)
        @@||tracker.com/allowed.js
        !#safari_cb_affinity
        """)
        let results = BlockerBuilder().build(sources: [source], allowlist: ["mysite.com"])
        XCTAssertEqual(results[.ads]?.rules.map(\.action.type), [.block, .ignorePreviousRules])
        XCTAssertEqual(results[.privacy]?.rules.map(\.action.type), [.ignorePreviousRules, .ignorePreviousRules])
        // The allowlist reaches every blocker.
        XCTAssertEqual(results[.custom]?.rules.first?.trigger.ifDomain, ["*mysite.com"])
    }
}
