import Foundation

/// One entry of Safari's content-blocker JSON.
/// https://developer.apple.com/documentation/safariservices/creating-a-content-blocker
public struct SafariRule: Codable, Hashable, Sendable {
    public struct Trigger: Codable, Hashable, Sendable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var loadContext: [String]?

        public init(urlFilter: String) { self.urlFilter = urlFilter }

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
        }
    }

    public struct Action: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case block
            case cssDisplayNone = "css-display-none"
            case ignorePreviousRules = "ignore-previous-rules"
        }

        public var type: Kind
        public var selector: String?
    }

    public var trigger: Trigger
    public var action: Action

    public init(trigger: Trigger, action: Action) {
        self.trigger = trigger
        self.action = action
    }

    /// A rule that never matches; Safari refuses to load an empty rule list.
    public static let placeholder = SafariRule(
        trigger: Trigger(urlFilter: "^openblock-placeholder://never-matches$"),
        action: Action(type: .block)
    )
}

extension Array where Element == SafariRule {
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(isEmpty ? [SafariRule.placeholder] : self)
    }
}
