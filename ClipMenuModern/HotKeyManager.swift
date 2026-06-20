import Cocoa

/// Global hot-key listener implemented with CGEvent tap.
/// Unlike NSEvent.addGlobalMonitorForEvents, a CGEvent tap can *consume*
/// the event so it never reaches other apps, and it works even when
/// Accessibility permission is granted (required for any global key capture).
final class HotKeyManager {
    static let shared = HotKeyManager()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: (() -> Void)?
    private var registeredKeyCode: UInt16 = 0
    private var registeredModifiers: CGEventFlags = []

    private init() {}

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        unregister()
        self.handler = handler
        self.registeredKeyCode = UInt16(keyCode)
        self.registeredModifiers = Self.carbonToCGFlags(modifiers)

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let mgr = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return mgr.handleTap(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            // Accessibility permission not granted – fall back to passive monitor
            // (can observe but not consume the event).
            fallbackRegister(keyCode: keyCode, modifiers: modifiers, handler: handler)
            return
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func unregister() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        handler = nil
    }

    // MARK: - Private

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if the system disabled it (e.g. after a timeout).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

        if code == registeredKeyCode, flags == registeredModifiers {
            DispatchQueue.main.async { [weak self] in self?.handler?() }
            return nil          // consume – other apps never see it
        }
        return Unmanaged.passUnretained(event)
    }

    /// Passive fallback used when Accessibility is not granted.
    private var fallbackLocalMonitor: Any?
    private var fallbackGlobalMonitor: Any?

    private func fallbackRegister(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        let flags = Self.carbonToEventFlags(modifiers)
        fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesFallback(event, keyCode: keyCode, flags: flags) else { return event }
            handler()
            return nil
        }
        fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesFallback(event, keyCode: keyCode, flags: flags) else { return }
            handler()
        }
    }

    private func matchesFallback(_ event: NSEvent, keyCode: UInt32, flags: NSEvent.ModifierFlags) -> Bool {
        guard UInt32(event.keyCode) == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return event.modifierFlags.intersection(relevant) == flags.intersection(relevant)
    }

    // MARK: - Modifier conversion

    private static func carbonToCGFlags(_ carbon: UInt32) -> CGEventFlags {
        var f: CGEventFlags = []
        if carbon & UInt32(cmdKey)     != 0 { f.insert(.maskCommand) }
        if carbon & UInt32(shiftKey)   != 0 { f.insert(.maskShift) }
        if carbon & UInt32(optionKey)  != 0 { f.insert(.maskAlternate) }
        if carbon & UInt32(controlKey) != 0 { f.insert(.maskControl) }
        // Handle the packed bitmask used by the default shortcut (⌃⌥⌘)
        if carbon == 3840 { return [.maskCommand, .maskAlternate, .maskControl] }
        return f
    }

    private static func carbonToEventFlags(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        if carbon == 3840 { return [.command, .option, .control] }
        var f: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey)     != 0 { f.insert(.command) }
        if carbon & UInt32(shiftKey)   != 0 { f.insert(.shift) }
        if carbon & UInt32(optionKey)  != 0 { f.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }
}

// Carbon modifier key bit constants (avoids importing Carbon framework)
private let cmdKey     : UInt32 = 1 << 8
private let shiftKey   : UInt32 = 1 << 9
private let optionKey  : UInt32 = 1 << 11
private let controlKey : UInt32 = 1 << 12
