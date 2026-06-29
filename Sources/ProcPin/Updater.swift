import Foundation

/// Static app metadata.
enum AppInfo {
    /// Current app version. Bump this with each release (matches the git tag).
    static let version = "1.9.0"
    /// GitHub repo "owner/name" used for update checks and the releases page.
    static let repo = "Snaylaker/ProcPin"
    static var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }
}

/// Checks GitHub Releases for a newer version.
enum Updater {

    struct Release: Equatable {
        let version: String   // normalized, e.g. "1.9.1"
        let htmlURL: URL
    }

    /// Fetches the latest release and returns it if newer than the current app.
    /// Returns nil if up to date or on any error.
    static func checkForUpdate() async -> Release? {
        guard let latest = await fetchLatest() else { return nil }
        return isNewer(latest.version, than: AppInfo.version) ? latest : nil
    }

    /// Fetches the latest release regardless of comparison.
    static func fetchLatest() async -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ProcPin", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return nil }
            let urlString = (obj["html_url"] as? String) ?? AppInfo.releasesURL.absoluteString
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return Release(version: version, htmlURL: URL(string: urlString) ?? AppInfo.releasesURL)
        } catch {
            return nil
        }
    }

    /// Semantic-ish comparison of dotted version strings ("1.10.0" > "1.9.0").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
