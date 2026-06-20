import Foundation
import os.log
import os.signpost

// MARK: - Unified performance logger
// All timing data flows here. Read measurements in Instruments → Logging,
// or run:  log stream --predicate 'subsystem == "com.clipmenu.modern"'

final class PerfLogger {
    static let shared = PerfLogger()
    private init() {}

    // Subsystem / categories
    private let log = Logger(subsystem: "com.clipmenu.modern", category: "performance")
    private let signposter: OSSignposter = {
        let log = OSLog(subsystem: "com.clipmenu.modern", category: .pointsOfInterest)
        return OSSignposter(logHandle: log)
    }()

    // MARK: - Named intervals

    /// Measure a synchronous block and log its duration.
    @discardableResult
    func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now()
        defer {
            let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let ms = Double(ns) / 1_000_000
            log.info("⏱ \(label, privacy: .public): \(ms, format: .fixed(precision: 2)) ms")
        }
        return try work()
    }

    // MARK: - Async begin/end (returns an ID you pass to end)

    func begin(_ label: String) -> UInt64 {
        let id = UInt64(bitPattern: Int64(bitPattern: UInt64.random(in: 0..<UInt64.max)))
        log.debug("▶ \(label, privacy: .public) begin (id=\(id))")
        return id
    }

    func end(_ label: String, id: UInt64, extraInfo: String = "") {
        log.info("◀ \(label, privacy: .public) end id=\(id) \(extraInfo, privacy: .public)")
    }

    // MARK: - Specific shortcuts

    func panelOpen(ms: Double) {
        log.info("📋 Panel open: \(ms, format: .fixed(precision: 1)) ms")
    }
    func searchRefresh(ms: Double, resultCount: Int) {
        log.info("🔍 Search refresh: \(ms, format: .fixed(precision: 1)) ms → \(resultCount) rows")
    }
    func historySave(ms: Double, itemCount: Int) {
        log.info("💾 History save: \(ms, format: .fixed(precision: 1)) ms, \(itemCount) items")
    }
    func thumbnailGenerated(ms: Double, pixelSize: Int) {
        log.info("🖼 Thumbnail \(pixelSize)px: \(ms, format: .fixed(precision: 1)) ms")
    }
    func memoryPressure(level: String) {
        log.warning("⚠️ Memory pressure: \(level, privacy: .public)")
    }
}

// MARK: - Convenience timing wrapper (non-logging use)
extension PerfLogger {
    static func time<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        try shared.measure(label, work)
    }
}
