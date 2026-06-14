import Foundation

/// A parsed GitHub release, reduced to what the in-app updater needs.
public struct ReleaseInfo: Sendable, Equatable {
    public let tagName: String      // e.g. "v1.1.6"
    public let version: String      // e.g. "1.1.6" (tag with any leading "v" stripped)
    public let zipURL: URL?         // browser_download_url of the macOS .zip asset
    public let htmlURL: URL?        // the release page (fallback when no asset / install fails)
    public let notes: String?       // release body

    public init(tagName: String, version: String, zipURL: URL?, htmlURL: URL?, notes: String?) {
        self.tagName = tagName
        self.version = version
        self.zipURL = zipURL
        self.htmlURL = htmlURL
        self.notes = notes
    }
}

/// Pure update logic: version comparison and GitHub release-payload parsing. Kept free of
/// networking and AppKit so it is unit-testable; the App layer wraps it with URLSession + install.
public enum UpdateService {
    /// The repository whose Releases feed the in-app updater.
    public static let repository = "BennettL569/Token-UI-TokenScope"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// Compares dotted numeric versions component-by-component, so "1.1.10" > "1.1.9" (a plain
    /// string compare would get that wrong). A leading "v"/"V" is tolerated; missing trailing
    /// components count as 0 ("1.2" == "1.2.0"); non-numeric suffixes are ignored.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs)
        let b = components(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// True only when `latest` is strictly newer than `current` — the sole condition under which
    /// the "Update Now" action is offered.
    public static func isUpdateAvailable(latest: String, current: String) -> Bool {
        compare(latest, current) == .orderedDescending
    }

    /// Parses a GitHub `releases/latest` JSON payload. Returns nil if it lacks a tag.
    public static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = (object["tag_name"] as? String), !tag.isEmpty else { return nil }
        let version = String(tag.drop { $0 == "v" || $0 == "V" })
        let htmlURL = (object["html_url"] as? String).flatMap(URL.init(string:))
        let notes = object["body"] as? String
        var zipURL: URL?
        if let assets = object["assets"] as? [[String: Any]] {
            // Prefer the macOS zip (a plain bundle that unzips without mounting); fall back to any
            // other .zip. The .dmg is intentionally not auto-installed.
            let chosen = assets.first { ($0["name"] as? String)?.hasSuffix("-macOS.zip") == true }
                ?? assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
            zipURL = (chosen?["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        return ReleaseInfo(tagName: tag, version: version, zipURL: zipURL, htmlURL: htmlURL, notes: notes)
    }

    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
