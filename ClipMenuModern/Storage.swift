import Foundation

// MARK: - Storage
// Low-level file I/O. All callers are responsible for calling from the right queue.
// HistoryStore owns history lifecycle; Storage is only the serialization layer.

final class Storage {
    static let shared = Storage()
    private init() {}

    // MARK: - URLs (computed lazily, creating dirs on first access)
    private(set) lazy var baseURL: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ClipMenuModern", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    lazy var historyURL:  URL = { baseURL.appendingPathComponent("history.json")  }()
    lazy var snippetsURL: URL = { baseURL.appendingPathComponent("snippets.json") }()
    lazy var settingsURL: URL = { baseURL.appendingPathComponent("settings.json") }()

    // MARK: - History (called from HistoryStore's background queue)
    func saveHistoryItems(_ items: [ClipItem]) {
        // Strip inline imagePNG before serialising — data lives in ImageStore
        let stripped = items.map { item -> ClipItem in
            var copy = item
            copy.imagePNG = nil
            return copy
        }
        save(stripped, to: historyURL)
    }

    // MARK: - Snippets (main thread OK — small file)
    func loadSnippets() -> [SnippetNode] {
        (try? decode([SnippetNode].self, from: snippetsURL)) ?? SnippetNode.defaults()
    }
    func saveSnippets(_ value: [SnippetNode]) { save(value, to: snippetsURL) }

    // MARK: - Settings (main thread OK — small file)
    func loadSettings() -> AppSettings {
        (try? decode(AppSettings.self, from: settingsURL)) ?? AppSettings()
    }
    func saveSettings(_ value: AppSettings) { save(value, to: settingsURL) }

    // MARK: - Generic helpers
    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
