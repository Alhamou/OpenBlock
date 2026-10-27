import Foundation

/// A parsed AdBlock / AdGuard filter rule that Safari content blockers can express.
public enum FilterRule: Equatable, Sendable {
    case network(NetworkRule)
    case cosmetic(CosmeticRule)
}

/// Safari `resource-type` values.
public enum ResourceType: String, CaseIterable, Comparable, Sendable {
    case document
    case image
    case styleSheet = "style-sheet"
    case script
    case font
    case raw
    case svgDocument = "svg-document"
    case media
    case popup

    /// Types a rule applies to when it only lists negated types (`$~script`).
    static let universe: Set<ResourceType> = [.document, .image, .styleSheet, .script, .font, .raw, .svgDocument, .media]

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// `||ads.example.com^$third-party,script` and `@@||cdn.example.com/ads.js`.
public struct NetworkRule: Equatable, Sendable {
    public var pattern: String
    public var isException = false
    public var isRegex = false
    public var matchCase = false
    /// `true` = third-party only, `false` = first-party only, `nil` = both.
    public var thirdParty: Bool?
    /// `nil` means every resource type.
    public var resourceTypes: Set<ResourceType>?
    /// `true` when the only requested type was `$subdocument` (adds `load-context: child-frame`).
    public var subdocumentOnly = false
    public var permittedDomains: [String] = []
    public var restrictedDomains: [String] = []
    public var isImportant = false
    public var isBadfilter = false
    /// Exception modifiers that whitelist page behavior instead of a single request.
    public var isDocumentException = false
    public var isElemhide = false
    public var isGenerichide = false
    /// Options as written (minus `badfilter`), used to match `$badfilter` rules.
    public var normalizedOptions: [String] = []

    public init(pattern: String) { self.pattern = pattern }

    var badfilterKey: String {
        (isException ? "@@" : "") + pattern + "$" + normalizedOptions.joined(separator: ",")
    }
}

/// `example.com##.banner`, `##.ad`, `example.com#@#.ad`.
public struct CosmeticRule: Equatable, Sendable {
    public var selector: String
    public var isException = false
    public var permittedDomains: [String] = []
    public var restrictedDomains: [String] = []

    public init(selector: String) { self.selector = selector }

    public var isGeneric: Bool { permittedDomains.isEmpty }
}
