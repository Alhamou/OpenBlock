import BlockerCore
import Foundation

/// A filter list OpenBlock can download.
struct FilterList: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var summary: String
    var url: URL
    var category: BlockerCategory
    var enabledByDefault = false
    var isUserAdded = false
}

/// Built-in lists. AdGuard publishes Safari-specific builds of its filters at
/// `filters.adtidy.org/extension/safari/filters/<id>.txt` that are already tuned for content blockers.
enum FilterCatalog {
    private static func adguard(_ id: Int) -> URL {
        URL(string: "https://filters.adtidy.org/extension/safari/filters/\(id).txt")!
    }

    static let builtIn: [FilterList] = [
        // Ads
        FilterList(id: "adguard-base", name: "AdGuard Base", summary: "EasyList + AdGuard English filter, optimized for Safari",
                   url: adguard(2), category: .ads, enabledByDefault: true),
        FilterList(id: "easylist", name: "EasyList", summary: "The original ad-blocking list (overlaps with AdGuard Base)",
                   url: URL(string: "https://easylist.to/easylist/easylist.txt")!, category: .ads),
        FilterList(id: "adguard-german", name: "AdGuard German", summary: "Ads on German-language sites",
                   url: adguard(6), category: .ads),
        FilterList(id: "easylist-germany", name: "EasyList Germany", summary: "Ads on German-language sites",
                   url: URL(string: "https://easylist.to/easylistgermany/easylistgermany.txt")!, category: .ads),
        FilterList(id: "liste-ar", name: "Liste AR", summary: "Ads on Arabic-language sites",
                   url: URL(string: "https://easylist-downloads.adblockplus.org/Liste_AR.txt")!, category: .ads),
        FilterList(id: "adguard-mobile", name: "AdGuard Mobile App Banners", summary: "\"Open in app\" banners",
                   url: adguard(20), category: .ads),
        // Privacy
        FilterList(id: "adguard-tracking", name: "AdGuard Tracking Protection", summary: "Analytics, trackers and counters",
                   url: adguard(3), category: .privacy, enabledByDefault: true),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", summary: "Tracker list from the EasyList project (overlaps with AdGuard Tracking)",
                   url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, category: .privacy),
        FilterList(id: "openblock-error-trackers", name: "OpenBlock Error Trackers",
                   summary: "Sentry, Bugsnag, Rollbar, TrackJS and Raygun error monitoring (built in)",
                   url: Bundle.main.url(forResource: "error-trackers", withExtension: "txt")!,
                   category: .privacy, enabledByDefault: true),
        FilterList(id: "peter-lowe", name: "Peter Lowe's List", summary: "Ad and tracking servers",
                   url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblock&showintro=0&mimetype=plaintext")!,
                   category: .privacy),
        // Annoyances
        FilterList(id: "adguard-social", name: "AdGuard Social Media", summary: "Like/share buttons and social widgets",
                   url: adguard(4), category: .annoyances, enabledByDefault: true),
        FilterList(id: "adguard-cookies", name: "AdGuard Cookie Notices", summary: "Cookie consent banners",
                   url: adguard(18), category: .annoyances, enabledByDefault: true),
        FilterList(id: "adguard-popups", name: "AdGuard Popups", summary: "Newsletter and push-notification popups",
                   url: adguard(19), category: .annoyances, enabledByDefault: true),
        FilterList(id: "adguard-other-annoyances", name: "AdGuard Other Annoyances", summary: "Miscellaneous page clutter",
                   url: adguard(21), category: .annoyances),
        FilterList(id: "adguard-widgets", name: "AdGuard Widgets", summary: "Chat and support widgets",
                   url: adguard(22), category: .annoyances),
    ]
}

extension BlockerCategory {
    var title: String {
        switch self {
        case .ads: "Ads"
        case .privacy: "Privacy"
        case .annoyances: "Annoyances"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .ads: "rectangle.slash"
        case .privacy: "eye.slash"
        case .annoyances: "bell.slash"
        case .custom: "slider.horizontal.3"
        }
    }
}
