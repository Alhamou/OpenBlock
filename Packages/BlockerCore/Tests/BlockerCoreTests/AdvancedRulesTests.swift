@testable import BlockerCore
import XCTest

final class AdvancedRulesTests: XCTestCase {
    private func compile(_ lines: [String], trusted: Bool = true, allowlist: [String] = []) -> AdvancedRuleset {
        AdvancedCompiler.compile(lines.map { .init(text: $0, trusted: trusted) }, allowlist: allowlist).0
    }

    func testScriptletSyntaxes() {
        let ruleset = compile([
            #"example.com#%#//scriptlet('set-constant', 'ads.enabled', 'false')"#,
            "example.com##+js(aopr, adblock\\, detector)",
            #"news.com#@%#//scriptlet('set-constant')"#,
        ])
        XCTAssertEqual(ruleset.rules(for: "example.com"), [
            .init(t: .scriptlet, c: "set-constant", a: ["ads.enabled", "false"]),
            .init(t: .scriptlet, c: "ubo-aopr.js", a: ["adblock, detector"]),
        ])
        XCTAssertEqual(ruleset.exceptions["news.com"], [.init(t: .scriptlet, c: "set-constant", a: [])])
    }

    func testCssAndExtendedCss() {
        let ruleset = compile([
            "example.com#$#body { overflow: auto !important; }",
            "example.com#$#.x { background: url(https://evil.test/a.png) }",
            "#?#div:has-text(Sponsored)",
            "example.com##.ad:has-text(Ad)",
            "example.com##.box:style(height: 0 !important)",
            "example.com##.plain",
            "~safe.com#$?#.banner:contains(ad) { remove: true; }",
        ])
        XCTAssertEqual(ruleset.rules(for: "example.com"), [
            .init(t: .css, c: "body { overflow: auto !important; }"),
            .init(t: .ext, c: ".ad:has-text(Ad) { display: none !important; }"),
            .init(t: .ext, c: ".box { height: 0 !important }"),
        ])
        XCTAssertEqual(ruleset.rules(for: ""), [
            .init(t: .ext, c: "div:has-text(Sponsored) { display: none !important; }"),
            .init(t: .ext, c: ".banner:contains(ad) { remove: true; }", x: ["safe.com"]),
        ])
    }

    func testUntrustedSourcesCannotRunJavaScript() {
        let (ruleset, stats) = AdvancedCompiler.compile([
            .init(text: "example.com#%#alert(1)", trusted: false),
            .init(text: #"example.com#%#//scriptlet('trusted-set-cookie', 'a', 'b')"#, trusted: false),
            .init(text: #"example.com#%#//scriptlet('set-cookie', 'a', '1')"#, trusted: false),
        ])
        XCTAssertEqual(stats.untrustedRejected, 2)
        XCTAssertEqual(ruleset.rules(for: "example.com")?.map(\.c), ["set-cookie"])
    }

    func testPageExceptionsAndAllowlist() {
        let ruleset = compile([
            "@@||shop.com^$generichide",
            "@@||bank.com^$document",
            "@@$elemhide,domain=a.com|b.com",
            "@@||cdn.com/script.js",
        ], allowlist: ["mysite.com"])
        XCTAssertEqual(ruleset.pages, [
            "shop.com": [.generichide], "bank.com": [.all], "a.com": [.elemhide], "b.com": [.elemhide],
            "mysite.com": [.all],
        ])
    }

    func testRealisticListLinesAreIgnoredWhenNotAdvanced() {
        let ruleset = compile(["||ads.com^", "##.banner", "! comment", "example.com##^script:has-text(ad)"])
        XCTAssertEqual(ruleset.ruleCount, 0)
    }
}
