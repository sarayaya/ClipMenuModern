import Cocoa

// MARK: - ThumbnailCache (thin wrapper — ImageStore owns the real cache)
// Kept for call-site compatibility. All actual caching/generation is in ImageStore.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Called on main thread after a thumbnail is generated asynchronously.
    /// Consumers set this to reload the relevant row (e.g. NSTableView.reloadData).
    var onThumbnailReady: (() -> Void)?

    private init() {}

    func image(for item: ClipItem, maxPixelSize: CGFloat) -> NSImage? {
        guard item.type == .image, let fileName = item.imageFileName else { return nil }
        let size = Int(maxPixelSize)
        if let img = ImageStore.shared.cachedThumbnail(for: fileName, maxPixelSize: size) {
            return img
        }
        // Not in cache — generate in background, then notify so the row can reload
        ImageStore.shared.preloadThumbnail(for: fileName, maxPixelSize: size) { [weak self] img in
            guard img != nil else { return }
            self?.onThumbnailReady?()
        }
        return nil
    }

    func preload(_ item: ClipItem, maxPixelSize: CGFloat = 120) {
        guard item.type == .image, let fileName = item.imageFileName else { return }
        ImageStore.shared.preloadThumbnail(for: fileName, maxPixelSize: Int(maxPixelSize))
    }
}

func cachedThumbnail(for item: ClipItem, maxPixelSize: CGFloat) -> NSImage? {
    ThumbnailCache.shared.image(for: item, maxPixelSize: maxPixelSize)
}

enum LiquidGlassStyle {
    static let panelRadius: CGFloat = 24
    static let controlRadius: CGFloat = 14
    static let rowRadius: CGFloat = 14
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var panelFill: NSColor {
        isDark
            ? NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
            : NSColor(red: 250.0 / 255.0, green: 252.0 / 255.0, blue: 254.0 / 255.0, alpha: 1.0)
    }
    static var segmentFill: NSColor {
        isDark
            ? NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)
            : NSColor(red: 253.0 / 255.0, green: 254.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
    }
    static var glassLine: NSColor {
        isDark
            ? NSColor(red: 0.42, green: 0.48, blue: 0.78, alpha: 0.36)
            : NSColor(red: 0.74, green: 0.78, blue: 1.00, alpha: 0.42)
    }
    static var glassLineStrong: NSColor {
        isDark
            ? NSColor(red: 0.48, green: 0.55, blue: 0.90, alpha: 0.48)
            : NSColor(red: 0.68, green: 0.73, blue: 1.00, alpha: 0.58)
    }
    static var glassFill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.76)
    }
    static var glassFillStrong: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.88)
    }
    static var searchFill: NSColor {
        isDark ? NSColor(red: 0.14, green: 0.15, blue: 0.18, alpha: 1.0) : .white
    }
    static var cardFill: NSColor {
        isDark ? NSColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 0.92) : NSColor.white.withAlphaComponent(0.82)
    }
    static var translucentControlFill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.40)
    }
    static var hoverFill: NSColor {
        isDark
            ? NSColor(red: 0.45, green: 0.51, blue: 1.00, alpha: 0.22)
            : NSColor(red: 0.55, green: 0.59, blue: 1.00, alpha: 0.14)
    }
    static var softText: NSColor {
        isDark
            ? NSColor(red: 0.74, green: 0.76, blue: 0.86, alpha: 0.78)
            : NSColor(red: 0.49, green: 0.51, blue: 0.62, alpha: 0.76)
    }
    static var selectedStart: NSColor {
        NSColor(red: 0.42, green: 0.55, blue: 1.00, alpha: 1.00)
    }
    static var selectedEnd: NSColor {
        NSColor(red: 0.68, green: 0.43, blue: 1.00, alpha: 1.00)
    }

    static func applyGlassLayer(_ layer: CALayer?, radius: CGFloat = controlRadius, fill: NSColor = glassFill) {
        layer?.cornerRadius = radius
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 0.7
        layer?.borderColor = glassLine.cgColor
        layer?.shadowColor = (isDark ? NSColor.black : NSColor(red: 0.50, green: 0.54, blue: 0.78, alpha: 1)).cgColor
        layer?.shadowOpacity = 0.09
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }
}

final class LiquidGlassPanelSheenView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        LiquidGlassStyle.panelFill.setFill()
        bounds.fill()

        NSGradient(colors: [
            NSColor.white.withAlphaComponent(LiquidGlassStyle.isDark ? 0.08 : 0.78),
            NSColor.white.withAlphaComponent(LiquidGlassStyle.isDark ? 0.04 : 0.30),
            NSColor.white.withAlphaComponent(LiquidGlassStyle.isDark ? 0.01 : 0.04)
        ])?.draw(in: NSRect(x: 1, y: bounds.height - 160, width: bounds.width - 2, height: 158), angle: -90)

        let shine = NSBezierPath()
        shine.move(to: NSPoint(x: -bounds.width * 0.25, y: bounds.height * 0.88))
        shine.line(to: NSPoint(x: bounds.width * 0.55, y: bounds.height * 1.10))
        shine.line(to: NSPoint(x: bounds.width * 0.78, y: bounds.height * 0.82))
        shine.line(to: NSPoint(x: -bounds.width * 0.10, y: bounds.height * 0.62))
        shine.close()
        NSColor.white.withAlphaComponent(LiquidGlassStyle.isDark ? 0.05 : 0.22).setFill()
        shine.fill()
    }
}

final class LiquidSegmentButton: FilterButton {
    private var gradientLayer: CAGradientLayer?

    func setSelectedGradient(_ selected: Bool) {
        gradientLayer?.removeFromSuperlayer()
        gradientLayer = nil
        guard selected, let layer else { return }

        let gradient = CAGradientLayer()
        gradient.colors = [
            LiquidGlassStyle.selectedStart.cgColor,
            LiquidGlassStyle.selectedEnd.cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.cornerRadius = 8
        gradient.frame = bounds
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.insertSublayer(gradient, at: 0)
        gradientLayer = gradient
    }
}

final class LiquidDividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let line = CAGradientLayer()
        line.frame = bounds
        let mid1: NSColor = LiquidGlassStyle.isDark
            ? NSColor(red: 0.42, green: 0.46, blue: 0.72, alpha: 0.38)
            : NSColor(red: 0.70, green: 0.76, blue: 1.00, alpha: 0.42)
        let mid2: NSColor = LiquidGlassStyle.isDark
            ? NSColor(red: 0.48, green: 0.52, blue: 0.80, alpha: 0.30)
            : NSColor(red: 0.78, green: 0.82, blue: 1.00, alpha: 0.34)
        line.colors = [
            NSColor.clear.cgColor,
            mid1.cgColor,
            mid2.cgColor,
            NSColor.clear.cgColor
        ]
        line.locations = [0, 0.18, 0.82, 1]
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(line)
    }
}
