import Cocoa
import ImageIO
import UniformTypeIdentifiers

// MARK: - ImageStore
// Owns all image I/O: original file storage, thumbnail generation via ImageIO
// (never creates a full NSImage for large source files), and a two-level cache
// (memory NSCache + disk thumbnails directory).  All disk I/O runs on a
// dedicated serial background queue; callers receive results on the main thread.

final class ImageStore {
    static let shared = ImageStore()

    // MARK: - Queues
    private let ioQueue   = DispatchQueue(label: "com.clipmenu.imagestore.io",   qos: .utility)
    private let thumbQueue = DispatchQueue(label: "com.clipmenu.imagestore.thumb", qos: .userInitiated)

    // MARK: - Memory cache (thumbnails only, never originals)
    private let memCache = NSCache<NSString, NSImage>()

    // MARK: - Paths
    private var baseURL: URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ClipMenuModern", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var originalsURL: URL {
        let dir = baseURL.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var thumbsURL: URL {
        let dir = baseURL.appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        memCache.countLimit       = 120
        memCache.totalCostLimit   = 32 * 1024 * 1024   // 32 MB for thumbnails

        // Register for memory pressure: evict memory cache, keep disk thumbs
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            let level = source.data == .critical ? "critical" : "warning"
            PerfLogger.shared.memoryPressure(level: level)
            self?.memCache.removeAllObjects()
        }
        source.resume()
        self.pressureSource = source
    }
    // Hold reference so the source isn't cancelled
    private var pressureSource: DispatchSourceMemoryPressure?

    // MARK: - Save original (background)
    /// Write image data to disk and return the filename, or nil on failure.
    func saveOriginal(_ data: Data, id: UUID) -> String? {
        let name = "\(id.uuidString).png"
        let url  = originalsURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return name }
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Async variant – calls back on main thread.
    func saveOriginalAsync(_ data: Data, id: UUID, completion: @escaping (String?) -> Void) {
        ioQueue.async { [weak self] in
            let name = self?.saveOriginal(data, id: id)
            DispatchQueue.main.async { completion(name) }
        }
    }

    // MARK: - Load original data (background)
    func originalData(for fileName: String) -> Data? {
        let url = originalsURL.appendingPathComponent(fileName)
        return try? Data(contentsOf: url)
    }

    // MARK: - Thumbnail (ImageIO down-sample, never full NSImage)
    /// Returns a cached thumbnail synchronously if available, otherwise nil.
    /// Call `preloadThumbnail` to warm the cache asynchronously.
    func cachedThumbnail(for fileName: String, maxPixelSize: Int) -> NSImage? {
        let key = cacheKey(fileName: fileName, size: maxPixelSize)
        if let img = memCache.object(forKey: key as NSString) { return img }
        // Try disk thumb
        if let img = loadDiskThumb(fileName: fileName, size: maxPixelSize) {
            memCache.setObject(img, forKey: key as NSString, cost: memoryCost(img))
            return img
        }
        return nil
    }

    /// Generate thumbnail in background, deliver to main thread.
    func preloadThumbnail(
        for fileName: String,
        maxPixelSize: Int,
        completion: ((NSImage?) -> Void)? = nil
    ) {
        let key = cacheKey(fileName: fileName, size: maxPixelSize)
        if memCache.object(forKey: key as NSString) != nil {
            completion?(memCache.object(forKey: key as NSString))
            return
        }
        thumbQueue.async { [weak self] in
            guard let self else { return }
            let t0 = DispatchTime.now()
            let img = self.generateThumb(fileName: fileName, maxPixelSize: maxPixelSize)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            PerfLogger.shared.thumbnailGenerated(ms: ms, pixelSize: maxPixelSize)
            if let img {
                self.memCache.setObject(img, forKey: key as NSString, cost: self.memoryCost(img))
                self.saveDiskThumb(img, fileName: fileName, size: maxPixelSize)
            }
            DispatchQueue.main.async { completion?(img) }
        }
    }

    // MARK: - Delete
    func deleteOriginal(fileName: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.originalsURL.appendingPathComponent(fileName))
            // Also delete any disk thumbs for this file
            let fm = FileManager.default
            let thumbDir = self.thumbsURL
            if let names = try? fm.contentsOfDirectory(atPath: thumbDir.path) {
                for name in names where name.hasPrefix(fileName) {
                    try? fm.removeItem(at: thumbDir.appendingPathComponent(name))
                }
            }
            // Evict from mem cache
            let prefix = fileName
            DispatchQueue.main.async { [weak self] in
                // NSCache has no prefix-eviction; iterate known sizes
                for size in [60, 80, 120, 160, 240] {
                    let key = self?.cacheKey(fileName: prefix, size: size) ?? ""
                    self?.memCache.removeObject(forKey: key as NSString)
                }
            }
        }
    }

    /// Remove originals not referenced by any item in the current history.
    func pruneOrphans(keepFileNames: Set<String>) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            guard let all = try? fm.contentsOfDirectory(atPath: self.originalsURL.path) else { return }
            for name in all where !keepFileNames.contains(name) {
                try? fm.removeItem(at: self.originalsURL.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Private helpers

    private func cacheKey(fileName: String, size: Int) -> String {
        "\(fileName)@\(size)"
    }

    private func memoryCost(_ image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height * 4))
    }

    /// Core ImageIO down-sample — never loads the full original into memory.
    private func generateThumb(fileName: String, maxPixelSize: Int) -> NSImage? {
        let url = originalsURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let sourceOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, sourceOpts as CFDictionary) else { return nil }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately:         false,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixelSize
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        else { return nil }

        return NSImage(cgImage: cgThumb,
                       size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }

    // MARK: - Disk thumb cache

    private func diskThumbURL(fileName: String, size: Int) -> URL {
        thumbsURL.appendingPathComponent("\(fileName)@\(size).jpg")
    }

    private func loadDiskThumb(fileName: String, size: Int) -> NSImage? {
        let url = diskThumbURL(fileName: fileName, size: size)
        guard let data = try? Data(contentsOf: url),
              let img  = NSImage(data: data) else { return nil }
        return img
    }

    private func saveDiskThumb(_ image: NSImage, fileName: String, size: Int) {
        let url = diskThumbURL(fileName: fileName, size: size)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        // Encode as JPEG (smaller than PNG for photos)
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let jpg  = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: 0.80])
        else { return }
        try? jpg.write(to: url, options: .atomic)
    }
}
