import Foundation

/// Persists the list of pinned processes to a JSON file in Application Support.
final class Store {
    static let shared = Store()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.procpin.store")

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("ProcPin", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("pins.json")
    }

    func load() -> [PinnedProcess] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            return (try? JSONDecoder().decode([PinnedProcess].self, from: data)) ?? []
        }
    }

    func save(_ pins: [PinnedProcess]) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(pins) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
