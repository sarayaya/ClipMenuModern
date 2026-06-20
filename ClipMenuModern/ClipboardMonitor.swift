import Cocoa

protocol ClipboardMonitorDelegate: AnyObject {
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture item: ClipItem)
}

final class ClipboardMonitor {
    weak var delegate: ClipboardMonitorDelegate?
    var settings: AppSettings
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        stop()
        let interval = max(0.2, settings.observeIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard !isFrontmostAppExcluded() else { return }
        if let item = PasteboardIO.readCurrent(settings: settings) {
            delegate?.clipboardMonitor(self, didCapture: item)
        }
    }

    func ignoreNextPasteboardChange() { lastChangeCount = NSPasteboard.general.changeCount }

    private func isFrontmostAppExcluded() -> Bool {
        let excluded = settings.excludedApplications
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !excluded.isEmpty,
              let app = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        return excluded.contains { item in
            bundleID == item || name == item || bundleID.contains(item) || name.contains(item)
        }
    }
}
