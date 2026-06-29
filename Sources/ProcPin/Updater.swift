import AppKit
import Foundation

/// Static app metadata.
enum AppInfo {
    /// Current app version. Bump this with each release (matches the git tag).
    static let version = "1.11.0"
    /// GitHub repo "owner/name" used for update checks and the releases page.
    static let repo = "Snaylaker/ProcPin"
    static var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }
}

/// Checks GitHub Releases for a newer version and can self-install it.
enum Updater {

    struct Release: Equatable {
        let version: String     // normalized, e.g. "1.11.0"
        let htmlURL: URL
        let zipURL: URL?        // .zip asset for auto-install (nil = manual only)
    }

    enum InstallError: Error, CustomStringConvertible {
        case noZipAsset, notBundled, download, extract, swap
        var description: String {
            switch self {
            case .noZipAsset: return "This release has no auto-installable build."
            case .notBundled: return "Auto-update only works from the installed app."
            case .download: return "Download failed."
            case .extract: return "Could not unpack the update."
            case .swap: return "Could not replace the app."
            }
        }
    }

    // MARK: - Check

    static func checkForUpdate() async -> Release? {
        guard let latest = await fetchLatest() else { return nil }
        return isNewer(latest.version, than: AppInfo.version) ? latest : nil
    }

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
            // Find a .zip asset for auto-install.
            var zip: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets {
                    if let name = a["name"] as? String, name.hasSuffix(".zip"),
                       let dl = a["browser_download_url"] as? String, let u = URL(string: dl) {
                        zip = u; break
                    }
                }
            }
            return Release(version: version,
                           htmlURL: URL(string: urlString) ?? AppInfo.releasesURL,
                           zipURL: zip)
        } catch {
            return nil
        }
    }

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

    // MARK: - Install

    /// Downloads the release zip, replaces the running app bundle, and relaunches.
    /// On success this terminates the app (a helper script finishes the swap).
    @MainActor
    static func installUpdate(_ release: Release) async -> Result<Void, InstallError> {
        guard let zipURL = release.zipURL else { return .failure(.noZipAsset) }
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return .failure(.notBundled) }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ProcPinUpdate-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipPath = work.appendingPathComponent("update.zip")
        let extractDir = work.appendingPathComponent("extracted")

        // 1. Download.
        do {
            var req = URLRequest(url: zipURL)
            req.setValue("ProcPin", forHTTPHeaderField: "User-Agent")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(.download)
            }
            try? fm.removeItem(at: zipPath)
            try fm.moveItem(at: tmp, to: zipPath)
        } catch {
            return .failure(.download)
        }

        // 2. Extract with ditto.
        try? fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path]) else {
            return .failure(.extract)
        }
        guard let newApp = (try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            return .failure(.extract)
        }

        // 3. Strip quarantine so Gatekeeper doesn't block the relaunch.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // 4. Write a helper that waits for us to quit, swaps the bundle, relaunches.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        APP='\(bundlePath)'
        NEW='\(newApp.path)'
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
        /bin/rm -rf "$APP"
        /usr/bin/ditto "$NEW" "$APP"
        /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        /usr/bin/open "$APP"
        /bin/rm -rf '\(work.path)'
        """
        let scriptPath = work.appendingPathComponent("swap.sh")
        do {
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.swap)
        }

        // 5. Launch the helper detached, then quit so it can replace us.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [scriptPath.path]
        do { try task.run() } catch { return .failure(.swap) }

        NSApp.terminate(nil)
        return .success(())
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
