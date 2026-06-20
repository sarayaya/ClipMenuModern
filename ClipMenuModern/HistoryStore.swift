import Foundation

// MARK: - HistoryStore
// Single source of truth for clipboard history.
// - All JSON I/O runs on a dedicated serial background queue (never blocks main thread).
// - Debounced saves: coalesces rapid writes into one disk write per 4-second window.
// - Crash-safe: corrupt / truncated JSON falls back to empty history instead of crashing.
// - Startup migration: inline imagePNG data is extracted to ImageStore on first load.

final class HistoryStore {
    static let shared = HistoryStore()

    // MARK: - Public in-memory state (always accessed on main thread)
    private(set) var items: [ClipItem] = []

    // MARK: - I/O queue
    private let queue = DispatchQueue(label: "com.clipmenu.historystore", qos: .utility)

    // MARK: - Debounce
    private var pendingSave: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 4.0

    // MARK: - Delegate
    weak var delegate: HistoryStoreDelegate?

    private init() {}

    // MARK: - Load (call once from main thread at startup)
    func loadFromDisk() {
        let t0 = DispatchTime.now()
        queue.async { [weak self] in
            guard let self else { return }
            var loaded = Self.decodeSafely(from: Storage.shared.historyURL) ?? []
            var migrated = false

            // Migrate any inline imagePNG to files
            for idx in loaded.indices where loaded[idx].type == .image {
                if loaded[idx].imageFileName == nil, let data = loaded[idx].imagePNG {
                    let name = ImageStore.shared.saveOriginal(data, id: loaded[idx].id)
                    loaded[idx].imageFileName = name
                    loaded[idx].imagePNG = nil
                    migrated = true
                }
            }

            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            PerfLogger.shared.measure("History load (\(loaded.count) items)") {}
            PerfLogger.shared.historySave(ms: ms, itemCount: loaded.count) // reuse slot for "load"

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.items = loaded
                self.delegate?.historyStoreDidLoad(self)
                if migrated { self.scheduleSave() }
            }
        }
    }

    // MARK: - Mutate (call from main thread; triggers debounced save)

    func prepend(_ item: ClipItem) {
        items.insert(item, at: 0)
        scheduleSave()
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        items.remove(at: index)
        if let fn = item.imageFileName { ImageStore.shared.deleteOriginal(fileName: fn) }
        scheduleSave()
    }

    func remove(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) { remove(at: idx) }
    }

    func removeAll() {
        let toDelete = items.compactMap(\.imageFileName)
        items.removeAll()
        for fn in toDelete { ImageStore.shared.deleteOriginal(fileName: fn) }
        scheduleSave()
    }

    func update(id: UUID, transform: (inout ClipItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        transform(&items[idx])
        scheduleSave()
    }

    func trimToMax(_ max: Int) {
        let cap = Swift.max(1, max)

        // Favorites are intentionally protected from automatic history trimming.
        // The history limit only applies to non-favorite clips, so favorited clips
        // will not disappear simply because new clipboard items were captured.
        var kept: [ClipItem] = []
        var removed: [ClipItem] = []
        var normalCount = 0

        for item in items {
            if item.isFavorite == true {
                kept.append(item)
            } else if normalCount < cap {
                kept.append(item)
                normalCount += 1
            } else {
                removed.append(item)
            }
        }

        guard !removed.isEmpty else { return }
        for item in removed where item.imageFileName != nil {
            ImageStore.shared.deleteOriginal(fileName: item.imageFileName!)
        }
        items = kept
        scheduleSave()
    }

    // MARK: - Immediate save (quit / clear / explicit)
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = items
        let t0 = DispatchTime.now()
        queue.async {
            Storage.shared.saveHistoryItems(snapshot)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            PerfLogger.shared.historySave(ms: ms, itemCount: snapshot.count)
        }
        // Prune orphaned image files
        let kept = Set(snapshot.compactMap(\.imageFileName))
        ImageStore.shared.pruneOrphans(keepFileNames: kept)
    }

    // MARK: - Private

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = items
        let work = DispatchWorkItem { [weak self] in
            let t0 = DispatchTime.now()
            Storage.shared.saveHistoryItems(snapshot)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            PerfLogger.shared.historySave(ms: ms, itemCount: snapshot.count)
            self?.pendingSave = nil
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    // MARK: - Crash-safe decode
    private static func decodeSafely(from url: URL) -> [ClipItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode([ClipItem].self, from: data)
        } catch {
            // Attempt partial recovery: decode as raw array and skip bad elements
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var recovered: [ClipItem] = []
                for obj in raw {
                    if let d = try? JSONSerialization.data(withJSONObject: obj),
                       let item = try? JSONDecoder().decode(ClipItem.self, from: d) {
                        recovered.append(item)
                    }
                }
                if !recovered.isEmpty { return recovered }
            }
            return nil     // fall back to empty history — never crash
        }
    }
}

// MARK: - Delegate
protocol HistoryStoreDelegate: AnyObject {
    func historyStoreDidLoad(_ store: HistoryStore)
}
