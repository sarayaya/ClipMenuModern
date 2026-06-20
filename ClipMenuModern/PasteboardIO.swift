import Cocoa
import ImageIO

final class PasteboardIO {
    static func readCurrent(settings: AppSettings) -> ClipItem? {
        autoreleasepool {
            let pb = NSPasteboard.general
            if settings.captureFiles,
               let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
                return ClipItem(type: .fileURLs, fileURLs: urls.map { $0.path })
            }
            if settings.captureImages,
               let image = NSImage(pasteboard: pb), let png = image.optimizedPNGData() {
                var item = ClipItem(type: .image)
                item.imageFileName = ImageStore.shared.saveOriginal(png, id: item.id)
                if item.imageFileName == nil {
                    item.imagePNG = png
                }
                return item
            }
            if settings.captureText,
               let string = pb.string(forType: .string), !string.isEmpty {
                return ClipItem(type: .text, text: string)
            }
            return nil
        }
    }

    static func write(_ item: ClipItem) {
        autoreleasepool {
            let pb = NSPasteboard.general
            pb.clearContents()
            switch item.type {
            case .text:
                pb.setString(item.text ?? "", forType: .string)
            case .image:
                if let fn = item.imageFileName,
                   let data = ImageStore.shared.originalData(for: fn),
                   let image = NSImage(data: data) {
                    pb.writeObjects([image])
                }
            case .fileURLs:
                let urls = (item.fileURLs ?? []).map { URL(fileURLWithPath: $0) as NSURL }
                pb.writeObjects(urls)
            }
        }
    }

    static func writeString(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    static func requestAccessibilityPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func sendCommandV() {
        // Send a real system-level Command-key chord to the currently active app.
        // Posting to a specific PID is less reliable for menu-bar panels because
        // the target process may be active while its text field is not yet key.
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0

        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)

        commandDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        commandUp?.flags = []

        [commandDown, vDown, vUp, commandUp].compactMap { $0 }.forEach {
            $0.post(tap: .cghidEventTap)
        }
    }

}

extension NSImage {
    func optimizedPNGData(maxPixelSize: CGFloat = 1280) -> Data? {
        let source = self
        let targetSize = source.size.fitting(maxPixelSize: maxPixelSize)
        let imageToEncode: NSImage
        if targetSize != source.size {
            imageToEncode = NSImage(size: targetSize)
            imageToEncode.lockFocus()
            source.draw(in: NSRect(origin: .zero, size: targetSize),
                        from: NSRect(origin: .zero, size: source.size),
                        operation: .copy,
                        fraction: 1.0)
            imageToEncode.unlockFocus()
        } else {
            imageToEncode = source
        }
        return imageToEncode.pngData()
    }

    private func pngData() -> Data? {
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension NSSize {
    func fitting(maxPixelSize: CGFloat) -> NSSize {
        let longest = max(width, height)
        guard longest > maxPixelSize, longest > 0 else { return self }
        let scale = maxPixelSize / longest
        return NSSize(width: width * scale, height: height * scale)
    }
}

extension Data {
    func thumbnailImage(maxPixelSize: CGFloat) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(self as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
