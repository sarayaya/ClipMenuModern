import Cocoa

private let submenuOpaqueBackgroundColor = NSColor(calibratedRed: 249.0 / 255.0,
                                                   green: 251.0 / 255.0,
                                                   blue: 254.0 / 255.0,
                                                   alpha: 1.0)

private func configureOpaqueSubmenu(_ menu: NSMenu) {
    menu.userInterfaceLayoutDirection = .leftToRight
    menu.appearance = NSAppearance(named: .aqua)
}

final class AppDelegate: NSObject, NSApplicationDelegate, ClipboardMonitorDelegate, PreferencesWindowControllerDelegate, NSTextFieldDelegate, HistoryStoreDelegate, NSTableViewDelegate, NSTableViewDataSource {

    // MARK: - Filter enum
    private enum MenuFilter: Int, CaseIterable {
        case all, favorite, today, text, image, file
        func title(settings: AppSettings) -> String {
            switch self {
            case .all:   return settings.text(en: "All", zh: "全部")
            case .favorite: return settings.text(en: "Fav", zh: "收藏")
            case .today: return settings.text(en: "Today", zh: "今天")
            case .text:  return settings.text(en: "Text", zh: "文本")
            case .image: return settings.text(en: "Image", zh: "图像")
            case .file:  return settings.text(en: "Files", zh: "文件")
            }
        }
    }

    // MARK: - State
    private var statusItem: NSStatusItem!
    private var monitor: ClipboardMonitor!
    /// Live copy of history — always access on main thread.
    private var history: [ClipItem] { HistoryStore.shared.items }
    private var snippets: [SnippetNode] = []
    private var settings: AppSettings = AppSettings()
    private var prefs: PreferencesWindowController?
    private var searchText: String = ""
    private var activeFilter: MenuFilter = .all
    private var isMenuOpen = false
    private var menuPinned = false
    private var panel: NSPanel?
    private weak var panelStack: NSStackView?
    private weak var panelSearchField: NSTextField?
    /// NSTableView that holds the inline clip rows — replaces direct ClipRowView allocation.
    private weak var panelTableView: ClipTableView?
    /// Data source for panelTableView.
    private var inlineClipItems: [ClipItem] = []
    private var panelClipRows: [ClipRowView] = []   // kept for keyboard nav lookup
    private var selectedPanelClipIndex: Int?
    private var lastPanelRowsSignature: String?

    // MARK: - Fixed menu width — all custom views use this exact value
    // NSMenu sizes itself to the widest item; text items are truncated to stay within this
    private let menuWidth: CGFloat = 352
    private let folderIconSize = NSSize(width: 18, height: 18)

    // MARK: - Live-menu references for in-place updates
    private weak var liveMenu: NSMenu?
    private weak var pinButton: NSButton?
    private weak var menuPinButton: PinButton?
    private var filterButtons: [MenuFilter: FilterButton] = [:]
    private var dynamicSectionStartIndex: Int = 0
    private var isReopeningPinnedMenu = false
    private var menuNeedsRefresh = false
    private var statusActivationMenu: NSMenu?
    private var isHandlingStatusActivationMenu = false
    private var lastStatusToggleTime: TimeInterval = 0
    private var statusItemLocalMouseMonitor: Any?
    private var statusItemGlobalMouseMonitor: Any?
    /// The app that was frontmost before our panel appeared, so we can
    /// re-activate it before sending ⌘V for auto-paste.
    private var previousApp: NSRunningApplication?
    /// Tracks the latest non-ClipMenu app activated by the user. This is more
    /// reliable than only reading frontmostApplication when the status item is clicked,
    /// because macOS can briefly report the menu-bar app as frontmost.
    private var lastNonSelfFrontmostApp: NSRunningApplication?

    private func t(en: String, zh: String) -> String {
        settings.text(en: en, zh: zh)
    }

    private func actionTitle(_ raw: String) -> String {
        switch raw {
        case "Uppercase": return t(en: "Uppercase", zh: "转为大写")
        case "Lowercase": return t(en: "Lowercase", zh: "转为小写")
        case "Capitalize": return t(en: "Capitalize", zh: "首字母大写")
        case "Trim Whitespace": return t(en: "Trim Whitespace", zh: "去除首尾空白")
        case "Remove Line Breaks": return t(en: "Remove Line Breaks", zh: "移除换行")
        case "Delete Empty Lines": return t(en: "Delete Empty Lines", zh: "删除空行")
        case "Merge Multiple Lines": return t(en: "Merge Multiple Lines", zh: "合并多行")
        case "Clean DOI / PMID": return t(en: "Clean DOI / PMID", zh: "DOI / PMID 清理")
        case "Replace Chinese Punctuation": return t(en: "Replace Chinese Punctuation", zh: "替换中文标点为英文标点")
        case "Add Space Between Numbers and Units": return t(en: "Add Space Between Numbers and Units", zh: "数字与单位之间加空格")
        case "URL Encode": return t(en: "URL Encode", zh: "URL 编码")
        case "URL Decode": return t(en: "URL Decode", zh: "URL 解码")
        default: return raw
        }
    }

    // MARK: - App lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        let t0 = DispatchTime.now()
        settings = Storage.shared.loadSettings()
        snippets = Storage.shared.loadSnippets()
        // Wire HistoryStore — loads asynchronously, calls historyStoreDidLoad when ready
        HistoryStore.shared.delegate = self
        HistoryStore.shared.loadFromDisk()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshStatusItemIcon()
        applyApplicationIcon()
        monitor = ClipboardMonitor(settings: settings)
        monitor.delegate = self
        monitor.start()
        buildMenu()
        configureHotKey()
        setupStatusItemClickHandling()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastNonSelfFrontmostApp = front
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        PerfLogger.shared.panelOpen(ms: ms)   // "app launch" timing

        // Rebuild the panel whenever the user switches between light and dark mode
        // so that all CALayer colours (set as cgColor, not dynamic NSColor) refresh.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func frontmostApplicationDidChange(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastNonSelfFrontmostApp = app
        }
    }

    @objc private func systemAppearanceDidChange() {
        // Defer one runloop cycle so NSApp.effectiveAppearance has updated.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // If the panel is open, close and reopen to repaint all CGColor layers.
            if panel?.isVisible == true {
                panel?.orderOut(nil)
                panel = nil
                panelStack = nil
                panelSearchField = nil
                filterButtons.removeAll()
                pinButton = nil
                menuPinButton = nil
                showPanel()
            } else {
                // Just tear down so it's rebuilt fresh next time it opens.
                panel = nil
                panelStack = nil
                panelSearchField = nil
                filterButtons.removeAll()
                pinButton = nil
                menuPinButton = nil
            }
        }
    }

    private func setupStatusItemClickHandling() {
        guard let button = statusItem.button else { return }

        // Do not rely on NSStatusItem.menu or a normal button action as the
        // primary trigger. In an LSUIElement menu-bar app, the first click can
        // be consumed by activation/menu tracking, which makes the popup appear
        // only on the second click. Instead, detect mouseDown directly on the
        // status-item screen frame. This mirrors native one-click menu-bar
        // utilities more closely.
        statusItem.menu = nil
        button.target = self
        button.action = #selector(statusItemButtonAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItemLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.isStatusItemEvent(event) {
                self.handleStatusItemMouseDown()
                return nil
            }
            self.closePanelIfNeeded(for: event)
            return event
        }

        statusItemGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            if self.isStatusItemEvent(event) {
                self.handleStatusItemMouseDown()
            } else {
                self.closePanelIfNeeded(for: event)
            }
        }
    }

    @objc private func statusItemButtonAction(_ sender: Any?) {
        // Fallback for accessibility/keyboard activation. Mouse activation is
        // handled on mouseDown above, with debounce to avoid duplicate toggles.
        handleStatusItemMouseDown()
    }

    private func handleStatusItemMouseDown() {
        DispatchQueue.main.async { [weak self] in
            self?.handleStatusItemActivation()
        }
    }

    private func handleStatusItemActivation() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStatusToggleTime > 0.20 else { return }
        lastStatusToggleTime = now
        togglePanel()
    }

    private func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonRectInWindow).insetBy(dx: -4, dy: -4)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }

    private func isStatusItemEvent(_ event: NSEvent) -> Bool {
        guard let frame = statusButtonScreenFrame() else { return false }
        return frame.contains(screenPoint(for: event))
    }

    private func closePanelIfNeeded(for event: NSEvent) {
        guard let panel, panel.isVisible, !menuPinned else { return }
        let point = screenPoint(for: event)
        if panel.frame.contains(point) { return }
        if statusButtonScreenFrame()?.contains(point) == true { return }
        panel.orderOut(nil)
    }

    // MARK: - HistoryStoreDelegate
    func historyStoreDidLoad(_ store: HistoryStore) {
        // Called on main thread once background load completes
        trimHistoryToMax()
        buildMenu()
        if panel?.isVisible == true { rebuildPanelRows() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItemLocalMouseMonitor { NSEvent.removeMonitor(statusItemLocalMouseMonitor) }
        if let statusItemGlobalMouseMonitor { NSEvent.removeMonitor(statusItemGlobalMouseMonitor) }
        if settings.saveHistoryOnQuit { HistoryStore.shared.saveNow() }
        Storage.shared.saveSnippets(snippets)
        Storage.shared.saveSettings(settings)
    }

    // MARK: - Clipboard capture
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture item: ClipItem) {
        // Remove duplicates then prepend — all via HistoryStore.
        // If the previous duplicate was favorited, preserve that favorite state on
        // the newly captured clip so re-copying the same content does not un-favorite it.
        var newItem = item
        if let dupIdx = HistoryStore.shared.items.firstIndex(where: { $0.duplicateKey == item.duplicateKey }) {
            let oldItem = HistoryStore.shared.items[dupIdx]
            newItem.isFavorite = oldItem.isFavorite
            HistoryStore.shared.remove(at: dupIdx)
        }
        HistoryStore.shared.prepend(newItem)
        preloadThumbnailIfNeeded(for: newItem)
        trimHistoryToMax()
        if isMenuOpen {
            updateDynamicSection()
        } else {
            menuNeedsRefresh = true
        }
    }

    // MARK: - Build full menu (only when closed)
    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Width lock: a custom view of exactly menuWidth forces the menu to that width.
        // ALL regular (text) menu items are also truncated so they never exceed this.
        menu.addItem(widthLockItem())
        menu.addItem(searchHeaderItem())

        filterButtons.removeAll()
        menu.addItem(filterBarItem())

        dynamicSectionStartIndex = menu.items.count
        appendDynamicItems(to: menu)

        // Footer
        menu.addItem(NSMenuItem.separator())
        if settings.addClearHistoryItem {
            let clear = make(title: t(en: "Clear History", zh: "清除历史"), action: #selector(clearHistory))
            menu.addItem(clear)
        }
        let prefsItem = make(title: t(en: "Preferences…", zh: "偏好设置…"), action: #selector(showPreferences), key: ",")
        menu.addItem(prefsItem)
        menu.addItem(NSMenuItem.separator())
        let quit = make(title: t(en: "Quit ClipMenu", zh: "退出 ClipMenu"), action: #selector(quit), key: "q")
        menu.addItem(quit)

        liveMenu = menu
        // DON'T assign to statusItem.menu — we use the floating panel instead
        // statusItem.menu = menu
    }

    // MARK: - In-place dynamic section refresh (menu stays open)
    private func updateDynamicSection() {
        guard let menu = liveMenu else { return }
        // separator + [Clear?] + Prefs + separator + Quit
        let footerCount = settings.addClearHistoryItem ? 5 : 4
        let removeCount = menu.items.count - dynamicSectionStartIndex - footerCount
        if removeCount > 0 {
            for _ in 0..<removeCount { menu.removeItem(at: dynamicSectionStartIndex) }
        }
        var idx = dynamicSectionStartIndex
        for item in makeDynamicItems() { menu.insertItem(item, at: idx); idx += 1 }
    }

    private func appendDynamicItems(to menu: NSMenu) {
        makeDynamicItems().forEach { menu.addItem($0) }
    }

    // MARK: - Floating panel
    @objc private func togglePanel() {
        if panel?.isVisible == true {
            dismissPanelAnimated()
            return
        }
        showPanel()
    }

    private func showPanel() {
        let t0 = DispatchTime.now()
        // Remember the target app before showing our panel. Prefer the current
        // frontmost non-self app; fall back to the last non-self app we observed.
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
            lastNonSelfFrontmostApp = front
        } else {
            previousApp = lastNonSelfFrontmostApp
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel == nil {
            createPanel()
            // Wire thumbnail-ready callback: when ImageStore finishes generating a
            // thumbnail in background, reload the table so the image appears immediately.
            ThumbnailCache.shared.onThumbnailReady = { [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                self.panelTableView?.reloadData()
            }
        }
        rebuildPanelRows()
        positionPanel()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        panel?.makeKey()
        if let panelSearchField {
            panel?.makeFirstResponder(panelSearchField)
            (panelSearchField as? PanelSearchTextField)?.updateInsertionPointVisibility()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel?.animator().alphaValue = 1
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        PerfLogger.shared.panelOpen(ms: ms)
    }

    private func createPanel() {
        // Panel window
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: menuWidth, height: 600),
                               styleMask: [.nonactivatingPanel, .fullSizeContentView],
                               backing: .buffered,
                               defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        // Keep the panel visible after the first menu-bar click; closing is
        // handled by the mouse monitors so inactive-state clicks do not make
        // the popup instantly disappear.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = LiquidGlassStyle.panelFill.cgColor
        root.layer?.cornerRadius = LiquidGlassStyle.panelRadius
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 0.9
        root.layer?.borderColor = LiquidGlassStyle.glassLineStrong.cgColor
        panel.contentView = root

        let effect = NSVisualEffectView(frame: root.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.blendingMode = .behindWindow
        effect.material = .underWindowBackground
        effect.state = .active
        effect.alphaValue = 0.18
        root.addSubview(effect)

        let sheen = LiquidGlassPanelSheenView(frame: root.bounds)
        sheen.autoresizingMask = [.width, .height]
        root.addSubview(sheen)

        // Use a flipped container so y=0 = top
        let flipRoot = FlippedView(frame: root.bounds)
        flipRoot.autoresizingMask = [.width, .height]
        root.addSubview(flipRoot)

        var curY: CGFloat = 0

        // ── Header (search + pin + settings) ──────────────────────────────
        let headerH: CGFloat = 56
        let header = MenuMouseView(frame: NSRect(x: 0, y: curY, width: menuWidth, height: headerH))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.clear.cgColor
        flipRoot.addSubview(header)

        let btnSz: CGFloat = 34
        let rInset: CGFloat = 14
        let btnGap: CGFloat = 8

        // Pin button (rightmost)
        let pinBtn = PinButton(frame: NSRect(x: menuWidth - rInset - btnSz, y: (headerH - btnSz) / 2,
                                             width: btnSz, height: btnSz))
        pinBtn.toolTip = t(en: "Pin", zh: "固定")
        pinBtn.isPinned = menuPinned
        pinBtn.target = self
        pinBtn.action = #selector(pinButtonTapped(_:))
        header.addSubview(pinBtn)
        self.pinButton = pinBtn

        // Settings button
        let settingsBtn = NSButton(frame: NSRect(x: menuWidth - rInset - btnSz * 2 - btnGap,
                                                  y: (headerH - btnSz) / 2, width: btnSz, height: btnSz))
        settingsBtn.bezelStyle = .texturedRounded
        settingsBtn.isBordered = false
        settingsBtn.wantsLayer = true
        LiquidGlassStyle.applyGlassLayer(settingsBtn.layer, radius: 13, fill: LiquidGlassStyle.translucentControlFill)
        let gearConf = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        settingsBtn.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(gearConf)
        settingsBtn.contentTintColor = .secondaryLabelColor
        settingsBtn.target = self
        settingsBtn.action = #selector(showPreferences)
        header.addSubview(settingsBtn)

        // Search field
        let searchX: CGFloat = 16
        let searchW = menuWidth - rInset - btnSz * 2 - btnGap - 8 - searchX
        let searchH: CGFloat = 36
        let search = SearchFieldContainer(frame: NSRect(x: searchX, y: (headerH - searchH) / 2,
                                                        width: searchW, height: searchH))
        search.wantsLayer = true
        LiquidGlassStyle.applyGlassLayer(search.layer, radius: 9, fill: LiquidGlassStyle.searchFill)
        search.layer?.masksToBounds = false

        let textField = PanelSearchTextField(frame: NSRect(x: 30, y: (searchH - 18) / 2, width: searchW - 38, height: 18))
        textField.autoresizingMask = [.width]
        textField.placeholderString = t(en: "Search clipboard...", zh: "搜索剪贴板...")
        textField.stringValue = searchText
        textField.delegate = self
        textField.target = self
        textField.action = #selector(searchFieldSubmitted(_:))
        textField.isEditable = true
        textField.isSelectable = true
        textField.focusRingType = .none
        textField.isBordered = false
        textField.drawsBackground = false
        textField.font = .systemFont(ofSize: 14, weight: .medium)
        search.textField = textField
        search.addSubview(textField)
        header.addSubview(search)
        panelSearchField = textField
        curY += headerH

        // ── Segmented filter bar ───────────────────────────────────────────
        let filterH: CGFloat = 46
        let filterView = MenuMouseView(frame: NSRect(x: 0, y: curY, width: menuWidth, height: filterH))
        filterView.wantsLayer = true
        filterView.layer?.backgroundColor = NSColor.clear.cgColor
        flipRoot.addSubview(filterView)

        let trackH: CGFloat = 34
        let trackInset: CGFloat = 16
        let trackRightInset: CGFloat = 16
        let track = NSView(frame: NSRect(x: trackInset, y: (filterH - trackH) / 2,
                                          width: menuWidth - trackInset - trackRightInset, height: trackH))
        track.wantsLayer = true
        track.layer?.backgroundColor = LiquidGlassStyle.translucentControlFill.cgColor
        track.layer?.cornerRadius = 10
        track.layer?.borderWidth = 0.7
        track.layer?.borderColor = LiquidGlassStyle.glassLine.cgColor
        filterView.addSubview(track)

        filterButtons.removeAll()
        let segCount = MenuFilter.allCases.count
        let trackW = menuWidth - trackInset - trackRightInset
        let segW = trackW / CGFloat(segCount)
        for filter in MenuFilter.allCases {
            let btn = LiquidSegmentButton(title: filter.title(settings: settings), target: self, action: #selector(filterButtonTapped(_:)))
            btn.tag = filter.rawValue
            btn.frame = NSRect(x: segW * CGFloat(filter.rawValue), y: 0, width: segW, height: trackH)
            applyFilterStyle(btn, selected: filter == activeFilter)
            track.addSubview(btn)
            filterButtons[filter] = btn
        }
        curY += filterH

        // ── Thin separator with equal vertical breathing room ───────────────
        let dividerBandH: CGFloat = 12
        let sep = LiquidDividerView(frame: NSRect(x: 16, y: curY + (dividerBandH - 1) / 2, width: menuWidth - 32, height: 1))
        flipRoot.addSubview(sep)
        curY += dividerBandH

        // ── Content scroll area ────────────────────────────────────────────
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: curY, width: menuWidth, height: 400))
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14)
        scrollView.documentView = stack
        flipRoot.addSubview(scrollView)
        panelStack = stack

        self.panel = panel
    }

    private func positionPanel() {
        guard let button = statusItem.button, let panel else { return }
        let buttonFrame = statusButtonScreenFrame()?.insetBy(dx: 4, dy: 4) ?? .zero
        let screenFrame = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(buttonFrame.midX - menuWidth / 2, screenFrame.minX + 8), screenFrame.maxX - menuWidth - 8)
        let y = buttonFrame.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: max(screenFrame.minY + 8, y)))
    }

    private func rebuildPanelRows() {
        guard let stack = panelStack else { return }
        let t0 = DispatchTime.now()
        let visible = filteredHistory()
        let signature = panelRowsSignature(visible: visible)
        if signature == lastPanelRowsSignature, !stack.arrangedSubviews.isEmpty {
            return
        }
        lastPanelRowsSignature = signature
        panelClipRows.removeAll()
        selectedPanelClipIndex = nil
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if snippetsAreAboveHistory {
            addPanelSnippetsSection(to: stack)
            addPanelSeparator(to: stack)
        }
        addPanelHistorySection(visible: visible, to: stack)

        if settings.enableActions, let firstText = visible.first(where: { $0.type == .text })?.text {
            let sub = NSMenu(title: t(en: "Actions", zh: "快捷操作"))
            configureSubmenuDirection(sub)
            for action in TextAction.allActions(customRules: settings.customTextRules) {
                let m = NSMenuItem(title: actionTitle(action.title), action: #selector(applyTextAction(_:)), keyEquivalent: "")
                m.target = self
                m.representedObject = ["action": action.title, "text": firstText]
                sub.addItem(m)
            }
            addPanelFolderRow(title: t(en: "Actions", zh: "快捷操作"), menu: sub, to: stack, image: nil, hoverMenuYOffset: -36)
        }

        if snippetsAreBelowHistory {
            addPanelSeparator(to: stack)
            addPanelSnippetsSection(to: stack)
        }

        addPanelFooterBar(to: stack)

        let contentHeight = stack.arrangedSubviews.reduce(CGFloat(20)) { $0 + $1.frame.height + stack.spacing }
        stack.setFrameSize(NSSize(width: menuWidth, height: contentHeight))

        // Auto-size panel to fit content (no scrolling)
        let fixedTop: CGFloat = 56 + 46 + 12  // header + filter + centered divider band
        let maxH = (NSScreen.main?.visibleFrame.height ?? 800) - 60
        let totalH = min(contentHeight + fixedTop, maxH)

        if let panel = self.panel,
           let flipRoot = panel.contentView?.subviews.compactMap({ $0 as? FlippedView }).first {
            // Resize scroll view to fill remaining space
            if let sv = flipRoot.subviews.compactMap({ $0 as? NSScrollView }).first {
                sv.frame = NSRect(x: 0, y: fixedTop, width: menuWidth, height: totalH - fixedTop)
            }
            // Resize panel
            var frame = panel.frame
            let oldH = frame.height
            frame.size.height = totalH
            frame.origin.y -= (totalH - oldH)
            panel.setFrame(frame, display: true, animate: false)
            flipRoot.frame = panel.contentView?.bounds ?? flipRoot.frame
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        PerfLogger.shared.searchRefresh(ms: ms, resultCount: visible.count)
    }

    private func panelRowsSignature(visible: [ClipItem]) -> String {
        let historyPart = visible.map {
            "\($0.id.uuidString):\($0.type.rawValue):\($0.isFavorite ?? false):\($0.preview)"
        }.joined(separator: "|")
        let snippetsPart = filteredSnippets().map {
            "\($0.id.uuidString):\($0.title):\($0.children.count)"
        }.joined(separator: "|")
        return [
            searchText,
            "\(activeFilter.rawValue)",
            settings.language,
            "\(settings.previewHistoryCount)",
            "\(settings.pageSize)",
            "\(settings.secondFolderSize)",
            settings.snippetsPositionValue.rawValue,
            "\(settings.enableActions)",
            historyPart,
            snippetsPart
        ].joined(separator: "§")
    }

    private func addPanelHistorySection(visible: [ClipItem], to stack: NSStackView) {
        let total = visible.count
        addPanelLabel(t(en: "History", zh: "历史记录"), to: stack, muted: true, badge: t(en: "\(total) items", zh: "\(total) 条"))
        if visible.isEmpty {
            addPanelLabel(searchText.isEmpty ? t(en: "No Clips", zh: "无剪贴记录") : t(en: "No Results", zh: "无结果"), to: stack, muted: true)
            return
        }

        let buckets = historyBuckets(from: visible)

        // Inline rows: NSTableView with cell reuse (stable memory, no per-item allocation).
        if !buckets.inline.isEmpty {
            inlineClipItems = buckets.inline
            let rowH: CGFloat = 38
            let tableH = rowH * CGFloat(buckets.inline.count)
            let tableW = menuWidth - 32

            let table: ClipTableView
            if let existing = panelTableView {
                table = existing
                table.frame = NSRect(x: 0, y: 0, width: tableW, height: tableH)
                table.reloadData()
            } else {
                table = ClipTableView()
                table.style = .plain
                table.backgroundColor = .clear
                table.headerView = nil
                table.rowHeight = rowH
                table.intercellSpacing = NSSize(width: 0, height: 0)
                table.usesAutomaticRowHeights = false
                table.selectionHighlightStyle = .none
                table.allowsEmptySelection = true
                table.focusRingType = .none
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
                col.width = tableW
                table.addTableColumn(col)
                table.delegate = self
                table.dataSource = self
                table.frame = NSRect(x: 0, y: 0, width: tableW, height: tableH)
                panelTableView = table
            }
            panelClipRows.removeAll()
            addPanelRowView(table, height: tableH, to: stack)
        }

        if !buckets.firstFolder.isEmpty {
            addPanelFolderRow(title: rangeTitle(start: buckets.firstFolderStart, count: buckets.firstFolder.count),
                              menu: historySubmenu(title: t(en: "History", zh: "历史记录"), items: buckets.firstFolder, startNumber: buckets.firstFolderStart),
                              to: stack,
                              hoverMenuYOffset: -36)
        }
        if !buckets.secondFolder.isEmpty {
            addPanelFolderRow(title: rangeTitle(start: buckets.secondFolderStart, count: buckets.secondFolder.count),
                              menu: historySubmenu(title: t(en: "History", zh: "历史记录"), items: buckets.secondFolder, startNumber: buckets.secondFolderStart),
                              to: stack,
                              hoverMenuYOffset: -36)
        }
    }

    // Legacy single-row add, kept for non-table paths.
    private func addPanelClipRow(item: ClipItem, number: Int, to stack: NSStackView) {
        let rowH: CGFloat = 38
        let row = ClipRowView(item: item, number: number, settings: settings,
                               width: menuWidth - 32, height: rowH,
                               target: self, action: #selector(selectClip(_:)))
        row.setContextMenu(historyContextMenu(for: item))
        panelClipRows.append(row)
        addPanelRowView(row, height: rowH, to: stack)
    }


    private func addPanelFooterBar(to stack: NSStackView) {
        let footerH: CGFloat = 64
        let bar = FooterBarView(width: menuWidth - 32, height: footerH,
                                 clearTitle: t(en: "Clear", zh: "清除历史"),
                                 prefsTitle: t(en: "Preferences", zh: "偏好设置"),
                                 quitTitle: t(en: "Quit", zh: "退出"),
                                 clearTarget: self, clearAction: #selector(clearHistory),
                                 prefsTarget: self, prefsAction: #selector(showPreferences),
                                 quitTarget: self, quitAction: #selector(quit))
        addPanelRowView(bar, height: footerH, to: stack)
    }

    private func addPanelFolderRow(title: String, menu: NSMenu, to stack: NSStackView, image: NSImage? = nil, hoverMenuYOffset: CGFloat = 0) {
        let button = PanelFolderButton(title: title, target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: menuWidth - 32, height: 38)
        button.menuToShow = menu
        button.hoverMenuYOffset = hoverMenuYOffset
        button.image = image ?? folderIcon()
        button.imagePosition = .imageLeading
        button.addDisclosureArrow(width: menuWidth - 32)
        addPanelRowView(button, height: 38, to: stack)
    }

    private func addPanelSnippetRow(_ node: SnippetNode, to stack: NSStackView) {
        if node.type == .folder {
            let sub = NSMenu(title: node.title)
            configureSubmenuDirection(sub)
            addWideSnippetSubmenuLockIfNeeded(to: sub, folderTitle: node.title)
            let centeredWidth = centeredSnippetSubmenuWidth(for: node.title)
            node.children.forEach { sub.addItem(snippetMenuItem($0, centeredWidth: centeredWidth)) }
            addPanelFolderRow(title: node.title, menu: sub, to: stack)
        } else {
            let button = PanelRowButton(title: truncated(node.title, length: 22), target: self, action: #selector(selectSnippet(_:)))
            button.frame = NSRect(x: 0, y: 0, width: menuWidth - 32, height: 38)
            button.representedObject = node.id.uuidString
            addPanelRowView(button, height: 38, to: stack)
        }
    }

    private func addPanelRowView(_ view: NSView, height: CGFloat, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false

        // When reusable views (especially the inline history NSTableView) are
        // removed and added again after search text changes, AppKit keeps the
        // previous width/height constraints on the view. If the search result
        // once showed fewer rows, those stale height constraints can make the
        // empty-search state still reserve only the smaller height, causing only
        // part of the configured inline history count to appear. Clear only the
        // old fixed-size constraints before applying the new row height.
        let staleSizeConstraints = view.constraints.filter { constraint in
            constraint.secondItem == nil &&
            (constraint.firstAttribute == .width || constraint.firstAttribute == .height)
        }
        if !staleSizeConstraints.isEmpty {
            NSLayoutConstraint.deactivate(staleSizeConstraints)
            view.removeConstraints(staleSizeConstraints)
        }

        stack.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: menuWidth - 32),
            view.heightAnchor.constraint(equalToConstant: height)
        ])
    }

    private func addPanelLabel(_ title: String, to stack: NSStackView, muted: Bool = false, badge: String = "") {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth - 32, height: 30))
        let label = NSTextField(labelWithString: title.uppercased())
        label.frame = NSRect(x: 2, y: (30 - 16) / 2, width: 200, height: 16)
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = LiquidGlassStyle.softText.withAlphaComponent(0.70)
        container.addSubview(label)
        if !badge.isEmpty {
            let badgeLabel = NSTextField(labelWithString: badge)
            badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            badgeLabel.textColor = LiquidGlassStyle.softText.withAlphaComponent(0.55)
            badgeLabel.sizeToFit()
            let bw = badgeLabel.frame.width + 4
            badgeLabel.frame = NSRect(x: menuWidth - 34 - bw, y: (30 - 16) / 2, width: bw, height: 16)
            container.addSubview(badgeLabel)
        }
        addPanelRowView(container, height: 30, to: stack)
    }

    private func addPanelSeparator(to stack: NSStackView) {
        let rowWidth = menuWidth - 32
        let height: CGFloat = 14
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: height))
        let line = LiquidDividerView(frame: NSRect(x: 0, y: (height - 1) / 2, width: rowWidth, height: 1))
        container.addSubview(line)
        addPanelRowView(container, height: height, to: stack)
    }

    private func addPanelSnippetsSection(to stack: NSStackView) {
        let visibleSnippets = filteredSnippets()
        addPanelLabel(t(en: "Snippets", zh: "片段"), to: stack, muted: true, badge: t(en: "\(visibleSnippets.count) folders", zh: "\(visibleSnippets.count) 个文件夹"))
        if visibleSnippets.isEmpty {
            addPanelLabel(searchText.isEmpty ? t(en: "No Snippets", zh: "无片段") : t(en: "No Snippets Found", zh: "未找到片段"), to: stack, muted: true)
        } else {
            let folders = visibleSnippets.filter { $0.type == .folder }
            let singles = visibleSnippets.filter { $0.type == .snippet }
            var i = 0
            let colW: CGFloat = (menuWidth - 32 - 8) / 2
            while i < folders.count {
                let leftNode = folders[i]
                let rightNode = i + 1 < folders.count ? folders[i + 1] : nil
                let gridRow = SnippetGridRowView(left: leftNode, right: rightNode,
                                                  colWidth: colW, height: 32,
                                                  totalWidth: menuWidth - 32,
                                                  target: self)
                addPanelRowView(gridRow, height: 40, to: stack)
                i += 2
            }
            singles.forEach { addPanelSnippetRow($0, to: stack) }
        }
    }

    private func historySubmenu(title: String, items: [ClipItem], startNumber: Int) -> NSMenu {
        let menu = NSMenu(title: title)
        configureSubmenuDirection(menu)
        menu.autoenablesItems = false
        menu.minimumWidth = menuWidth - 32
        menu.showsStateColumn = false
        for (index, item) in items.enumerated() {
            menu.addItem(historyFolderMenuItem(item: item, number: startNumber + index))
        }
        return menu
    }

    private struct HistoryBuckets {
        var inline: [ClipItem]
        var firstFolder: [ClipItem]
        var secondFolder: [ClipItem]
        var firstFolderStart: Int
        var secondFolderStart: Int
    }

    private var snippetsAreAboveHistory: Bool {
        settings.snippetsPositionValue == .aboveHistory
    }

    private var snippetsAreBelowHistory: Bool {
        settings.snippetsPositionValue == .belowHistory
    }

    private func historyBuckets(from visible: [ClipItem]) -> HistoryBuckets {
        let inlineCount = min(max(0, settings.previewHistoryCount), visible.count)
        let firstStart = inlineCount + 1
        let firstCount = min(max(0, settings.pageSize), max(0, visible.count - inlineCount))
        let secondStart = firstStart + firstCount
        let secondCount = min(max(0, settings.secondFolderSize), max(0, visible.count - inlineCount - firstCount))

        let inline = Array(visible.prefix(inlineCount))
        let firstFolder = firstCount == 0 ? [] : Array(visible.dropFirst(inlineCount).prefix(firstCount))
        let secondFolder = secondCount == 0 ? [] : Array(visible.dropFirst(inlineCount + firstCount).prefix(secondCount))
        return HistoryBuckets(inline: inline,
                              firstFolder: firstFolder,
                              secondFolder: secondFolder,
                              firstFolderStart: firstStart,
                              secondFolderStart: secondStart)
    }

    private func rangeTitle(start: Int, count: Int) -> String {
        "\(start) - \(start + count - 1)"
    }

    private func historyFolderItem(items: [ClipItem], startNumber: Int) -> NSMenuItem {
        let title = rangeTitle(start: startNumber, count: items.count)
        let folderItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        folderItem.image = folderIcon()
        folderItem.submenu = historySubmenu(title: title, items: items, startNumber: startNumber)
        return folderItem
    }

    // MARK: - Dynamic items: history + snippets
    private func makeDynamicItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let visible = filteredHistory()

        if snippetsAreAboveHistory {
            items.append(contentsOf: snippetSectionMenuItems())
            items.append(NSMenuItem.separator())
        }

        items.append(contentsOf: historySectionMenuItems(visible: visible))

        // Actions submenu (only for text items)
        if settings.enableActions, let firstText = visible.first(where: { $0.type == .text })?.text {
            let actionItem = NSMenuItem(title: t(en: "Actions", zh: "快捷操作"), action: nil, keyEquivalent: "")
            let sub = NSMenu(title: t(en: "Actions", zh: "快捷操作"))
            configureSubmenuDirection(sub)
            for action in TextAction.allActions(customRules: settings.customTextRules) {
                let m = NSMenuItem(title: actionTitle(action.title), action: #selector(applyTextAction(_:)), keyEquivalent: "")
                m.target = self
                m.representedObject = ["action": action.title, "text": firstText]
                sub.addItem(m)
            }
            actionItem.submenu = sub
            items.append(actionItem)
        }

        if snippetsAreBelowHistory {
            items.append(NSMenuItem.separator())
            items.append(contentsOf: snippetSectionMenuItems())
        }

        return items
    }

    private func historySectionMenuItems(visible: [ClipItem]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let histHeader = NSMenuItem(title: t(en: "History", zh: "历史记录"), action: nil, keyEquivalent: "")
        histHeader.isEnabled = false
        items.append(histHeader)

        if visible.isEmpty {
            let empty = NSMenuItem(title: searchText.isEmpty ? t(en: "No Clips", zh: "无剪贴记录") : t(en: "No Results", zh: "无结果"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        } else {
            let buckets = historyBuckets(from: visible)
            for (index, clip) in buckets.inline.enumerated() {
                items.append(historyMenuItem(item: clip, number: index + 1))
            }
            if !buckets.firstFolder.isEmpty {
                items.append(historyFolderItem(items: buckets.firstFolder, startNumber: buckets.firstFolderStart))
            }
            if !buckets.secondFolder.isEmpty {
                items.append(historyFolderItem(items: buckets.secondFolder, startNumber: buckets.secondFolderStart))
            }
        }

        return items
    }

    private func snippetSectionMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let snipHeader = NSMenuItem(title: t(en: "Snippets", zh: "片段"), action: nil, keyEquivalent: "")
        snipHeader.isEnabled = false
        items.append(snipHeader)

        let visibleSnippets = filteredSnippets()
        if visibleSnippets.isEmpty {
            let empty = NSMenuItem(title: searchText.isEmpty ? t(en: "No Snippets", zh: "无片段") : t(en: "No Snippets Found", zh: "未找到片段"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        } else {
            visibleSnippets.forEach { items.append(snippetMenuItem($0)) }
        }

        return items
    }

    // MARK: - Width-lock custom view item
    // This item has no height so it's invisible, but forces the menu to menuWidth.
    private func widthLockItem() -> NSMenuItem {
        let item = NSMenuItem()
        // Use a container that clips its content — text items cannot push past menuWidth
        let container = WidthLockView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 1))
        item.view = container
        return item
    }

    // MARK: - Search header
    private func searchHeaderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = MenuMouseView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 44))

        // Right: pin button
        let btnSize: CGFloat = 28
        let gap: CGFloat = 6
        let rightInset: CGFloat = 8

        let pinBtn = PinButton(frame: NSRect(x: menuWidth - rightInset - btnSize,
                                             y: 8, width: btnSize, height: btnSize))
        pinBtn.toolTip = t(en: "Pin", zh: "固定")
        pinBtn.isPinned = menuPinned
        pinBtn.target = self
        pinBtn.action = #selector(pinButtonTappedMenu(_:))
        view.addSubview(pinBtn)
        self.menuPinButton = pinBtn

        // Right: settings button (left of pin)
        let settingsBtn = NSButton(frame: NSRect(x: menuWidth - rightInset - btnSize * 2 - gap,
                                                 y: 8, width: btnSize, height: btnSize))
        settingsBtn.bezelStyle = .texturedRounded
        settingsBtn.isBordered = false
        let settingsConf = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        settingsBtn.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(settingsConf)
        settingsBtn.contentTintColor = .secondaryLabelColor
        settingsBtn.wantsLayer = true
        settingsBtn.layer?.cornerRadius = 6
        settingsBtn.target = self
        settingsBtn.action = #selector(showPreferences)
        view.addSubview(settingsBtn)

        // Left: search field (fills remaining width)
        let searchRight = menuWidth - rightInset - btnSize * 2 - gap - 8
        let sfContainer = SearchFieldContainer(frame: NSRect(x: 8, y: 8,
                                                             width: searchRight - 8,
                                                             height: 28))
        let sf = NSTextField(frame: NSRect(x: 32, y: 4, width: sfContainer.bounds.width - 38, height: 20))
        sf.autoresizingMask = [.width]
        sf.placeholderString = t(en: "Type to search…", zh: "输入开始搜索…")
        sf.stringValue = searchText
        sf.delegate = self
        sf.target = self
        sf.action = #selector(searchFieldSubmitted(_:))
        sf.isEditable = true
        sf.isSelectable = true
        sf.focusRingType = .none
        sf.isBordered = false
        sf.drawsBackground = false
        sf.font = .systemFont(ofSize: 13)
        sfContainer.textField = sf
        sfContainer.addSubview(sf)
        view.addSubview(sfContainer)

        item.view = view
        return item
    }

    @objc private func pinButtonTappedMenu(_ sender: PinButton) {
        menuPinned.toggle()
        sender.isPinned = menuPinned
    }

    // MARK: - Filter bar (Segmented Control style)
    private func filterBarItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = MenuMouseView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 38))

        // Background pill track
        let hPad: CGFloat = 16
        let rightPad: CGFloat = 16
        let trackH: CGFloat = 28
        let trackY: CGFloat = (38 - trackH) / 2
        let track = NSView(frame: NSRect(x: hPad, y: trackY, width: menuWidth - hPad - rightPad, height: trackH))
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.07).cgColor
        track.layer?.cornerRadius = 8
        view.addSubview(track)

        let count = MenuFilter.allCases.count
        let trackW = menuWidth - hPad - rightPad
        let segW = trackW / CGFloat(count)

        for filter in MenuFilter.allCases {
            let x = segW * CGFloat(filter.rawValue)
            let btn = FilterButton(title: filter.title(settings: settings), target: self, action: #selector(filterButtonTapped(_:)))
            btn.tag = filter.rawValue
            btn.frame = NSRect(x: x, y: 0, width: segW, height: trackH)
            applyFilterStyle(btn, selected: filter == activeFilter)
            track.addSubview(btn)
            filterButtons[filter] = btn
        }

        item.view = view
        return item
    }

    private func refreshFilterButtonStyles() {
        for (filter, btn) in filterButtons { applyFilterStyle(btn, selected: filter == activeFilter) }
    }

    private func applyFilterStyle(_ btn: NSButton, selected: Bool) {
        btn.wantsLayer = true
        btn.isBordered = false
        btn.font = selected ? .systemFont(ofSize: 12, weight: .bold) : .systemFont(ofSize: 12, weight: .semibold)
        btn.layer?.cornerRadius = 8
        (btn as? LiquidSegmentButton)?.setSelectedGradient(selected)
        if selected {
            btn.layer?.backgroundColor = NSColor.clear.cgColor
            btn.layer?.borderWidth = 0
            btn.layer?.shadowColor = LiquidGlassStyle.selectedEnd.cgColor
            btn.layer?.shadowOpacity = 0.22
            btn.layer?.shadowRadius = 10
            btn.layer?.shadowOffset = CGSize(width: 0, height: -4)
            btn.contentTintColor = NSColor.white
        } else {
            btn.layer?.backgroundColor = LiquidGlassStyle.segmentFill.cgColor
            btn.layer?.borderWidth = 0
            btn.layer?.shadowOpacity = 0
            btn.contentTintColor = LiquidGlassStyle.softText
        }
    }

    // MARK: - Filter / search callbacks
    @objc private func filterButtonTapped(_ sender: NSButton) {
        guard let filter = MenuFilter(rawValue: sender.tag), filter != activeFilter else { return }
        activeFilter = filter
        refreshFilterButtonStyles()
        updateDynamicSection()
        rebuildPanelRows()
    }

    @objc private func pinButtonTapped(_ sender: PinButton) {
        menuPinned.toggle()
        sender.isPinned = menuPinned
        panel?.hidesOnDeactivate = false
    }

    @objc private func searchFieldSubmitted(_ sender: NSTextField) {
        searchText = sender.stringValue
        guard !sender.hasMarkedTextInCurrentEditor else { return }
        updateDynamicSection()
        rebuildPanelRows()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let sf = obj.object as? NSTextField else { return }
        (sf as? PanelSearchTextField)?.updateInsertionPointVisibility()
        searchText = sf.stringValue
        guard !sf.hasMarkedTextInCurrentEditor else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(delayedUpdate), object: nil)
        perform(#selector(delayedUpdate), with: nil, afterDelay: 0.25)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let sf = obj.object as? NSTextField else { return }
        (sf as? PanelSearchTextField)?.updateInsertionPointVisibility()
        searchText = sf.stringValue
        updateDynamicSection()
    }

    @objc private func delayedUpdate() {
        updateDynamicSection()
        rebuildPanelRows()
    }

    fileprivate func handlePanelKeyDown(_ event: NSEvent) -> Bool {
        let count = inlineClipItems.count
        switch event.keyCode {
        case 53:
            dismissPanelAnimated()
            return true
        case 125: // ↓
            movePanelSelection(delta: 1)
            return true
        case 126: // ↑
            movePanelSelection(delta: -1)
            return true
        case 36, 76: // Return / Numpad Enter
            guard let idx = selectedPanelClipIndex, count > 0, idx < count else { return false }
            let item = inlineClipItems[idx]
            // Simulate selectClip from the table cell
            if let cell = panelTableView?.view(atColumn: 0, row: idx, makeIfNecessary: false) as? ClipRowCellView {
                selectClip(cell)
            } else {
                // Fallback: directly use item
                PasteboardIO.write(item)
                monitor.ignoreNextPasteboardChange()
                closePanelAndPaste()
            }
            return true
        default:
            return false
        }
    }

    private func movePanelSelection(delta: Int) {
        let count = inlineClipItems.count
        guard count > 0 else { return }
        let current = selectedPanelClipIndex ?? (delta > 0 ? -1 : count)
        let next = min(max(current + delta, 0), count - 1)
        selectedPanelClipIndex = next
        // Highlight via table row update
        if let table = panelTableView {
            var rows = IndexSet()
            if let old = selectedPanelClipIndex, old != next { rows.insert(old) }
            rows.insert(next)
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            table.scrollRowToVisible(next)
        }
    }

    private func updatePanelSelectionHighlight() {
        panelTableView?.reloadData()
    }

    // MARK: - NSTableViewDataSource
    func numberOfRows(in tableView: NSTableView) -> Int {
        inlineClipItems.count
    }

    // MARK: - NSTableViewDelegate
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < inlineClipItems.count else { return nil }
        let item = inlineClipItems[row]
        let reuseID = NSUserInterfaceItemIdentifier("ClipCell")
        let cell: ClipRowCellView
        if let reused = tableView.makeView(withIdentifier: reuseID, owner: self) as? ClipRowCellView {
            cell = reused
            cell.configure(item: item, number: row + 1, settings: settings,
                           isKeyboardSelected: selectedPanelClipIndex == row,
                           contextMenu: historyContextMenu(for: item),
                           target: self, action: #selector(selectClip(_:)))
        } else {
            cell = ClipRowCellView(identifier: reuseID)
            cell.configure(item: item, number: row + 1, settings: settings,
                           isKeyboardSelected: selectedPanelClipIndex == row,
                           contextMenu: historyContextMenu(for: item),
                           target: self, action: #selector(selectClip(_:)))
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 38 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: - Data filtering
    private func filteredHistory() -> [ClipItem] {
        let cal = Calendar.current
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return history.filter { item in
            let match: Bool
            switch activeFilter {
            case .all:   match = true
            case .favorite: match = item.isFavorite ?? false
            case .today: match = cal.isDateInToday(item.createdAt)
            case .text:  match = item.type == .text
            case .image: match = item.type == .image
            case .file:  match = item.type == .fileURLs
            }
            guard match else { return false }
            guard !q.isEmpty else { return true }
            let hay = [item.preview, item.text ?? "", (item.fileURLs ?? []).joined(separator: " ")]
                .joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    private func filteredSnippets() -> [SnippetNode] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snippets }
        return snippets.compactMap { folder in
            if folder.title.lowercased().contains(q) { return folder }
            let kids = folder.children.filter {
                $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)
            }
            guard !kids.isEmpty else { return nil }
            var c = folder; c.children = kids; return c
        }
    }

    // MARK: - Menu item factories
    private func historyMenuItem(item: ClipItem, number: Int) -> NSMenuItem {
        // Truncate to keep within menuWidth (approx 30 chars safe at system font size)
        let preview = truncated(clipPreview(for: item), length: settings.menuPreviewLength)
        let displayNumber = settings.numberItemsFromZero ? number - 1 : number
        let typePrefix = settings.showLabels ? "\(clipTypeLabel(for: item)): " : ""
        let bareTitle = "\(typePrefix)\(preview)"
        let title = settings.markItemsWithNumbers ? "\(displayNumber). \(bareTitle)" : bareTitle
        let key = (settings.addNumericKeyEquivalents && number <= 10) ? String(number % 10) : ""
        let mi = NSMenuItem(title: title, action: #selector(selectClip(_:)), keyEquivalent: key)
        mi.target = self
        mi.representedObject = item.id.uuidString
        if settings.changeFontSize, settings.fontSizeModeValue == .select {
            mi.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: CGFloat(settings.selectedFontSize))
            ])
        }
        if settings.showToolTip, item.type == .text, let full = item.text, !full.isEmpty {
            mi.toolTip = String(full.prefix(max(10, settings.maxToolTipLength)))
        }
        if settings.showImagesInMenu, item.type == .image, let img = cachedThumbnail(for: item, maxPixelSize: 120) {
            img.size = NSSize(width: settings.imagePreviewWidth, height: settings.imagePreviewHeight)
            mi.image = img
        }
        return mi
    }

    private func historyFolderMenuItem(item: ClipItem, number: Int) -> NSMenuItem {
        let preview = truncated(clipPreview(for: item), length: settings.menuPreviewLength)
        let displayNumber = settings.numberItemsFromZero ? number - 1 : number
        let key = (settings.addNumericKeyEquivalents && number <= 10) ? String(number % 10) : ""

        let mi = NSMenuItem(title: "", action: #selector(selectClip(_:)), keyEquivalent: key)
        mi.target = self
        mi.representedObject = item.id.uuidString
        mi.isEnabled = true
        mi.view = HistoryFolderMenuItemView(item: item,
                                            displayNumber: displayNumber,
                                            preview: preview,
                                            width: menuWidth - 32,
                                            settings: settings,
                                            target: self,
                                            action: #selector(selectClip(_:)))

        if settings.showToolTip, item.type == .text, let full = item.text, !full.isEmpty {
            mi.toolTip = String(full.prefix(max(10, settings.maxToolTipLength)))
        }
        return mi
    }

    private func historyTypeDotColor(for type: ClipItem.ClipType) -> NSColor {
        switch type {
        case .text:
            return NSColor.systemBlue.withAlphaComponent(0.85)
        case .image:
            return NSColor.systemPurple.withAlphaComponent(0.85)
        case .fileURLs:
            return NSColor.systemGreen.withAlphaComponent(0.85)
        }
    }

    private func historyTypeDotImage(for type: ClipItem.ClipType) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let color: NSColor
        switch type {
        case .text:
            color = NSColor.systemBlue.withAlphaComponent(0.8)
        case .image:
            color = NSColor.systemPurple.withAlphaComponent(0.8)
        case .fileURLs:
            color = NSColor.systemGreen.withAlphaComponent(0.8)
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 6, height: 6)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func clipPreview(for item: ClipItem) -> String {
        switch item.type {
        case .text:
            let raw = (item.text ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? t(en: "(Empty Text)", zh: "(空文本)") : raw
        case .image:
            return t(en: "(Image)", zh: "(图像)")
        case .fileURLs:
            if let first = item.fileURLs?.first { return URL(fileURLWithPath: first).lastPathComponent }
            return t(en: "(File)", zh: "(文件)")
        }
    }

    private func clipTypeLabel(for item: ClipItem) -> String {
        switch item.type {
        case .text: return t(en: "Text", zh: "文本")
        case .image: return t(en: "Image", zh: "图像")
        case .fileURLs: return t(en: "File", zh: "文件")
        }
    }

    private func historyContextMenu(for item: ClipItem) -> NSMenu {
        let menu = NSMenu()
        configureSubmenuDirection(menu)
        menu.autoenablesItems = false

        let copyPlain = NSMenuItem(title: t(en: "Copy as Plain Text", zh: "复制为纯文本"),
                                   action: #selector(copyHistoryAsPlainText(_:)),
                                   keyEquivalent: "")
        copyPlain.target = self
        copyPlain.representedObject = item.id.uuidString
        menu.addItem(copyPlain)

        let copyCleaned = NSMenuItem(title: t(en: "Copy after Cleaning Extra Spaces / Line Breaks", zh: "清理多余空格/换行后复制"),
                                     action: #selector(copyHistoryCleanedText(_:)),
                                     keyEquivalent: "")
        copyCleaned.target = self
        copyCleaned.representedObject = item.id.uuidString
        menu.addItem(copyCleaned)

        let viewFull = NSMenuItem(title: t(en: "View Full Content", zh: "查看完整内容"),
                                  action: #selector(showFullHistoryContent(_:)),
                                  keyEquivalent: "")
        viewFull.target = self
        viewFull.representedObject = item.id.uuidString
        menu.addItem(viewFull)

        menu.addItem(NSMenuItem.separator())

        let favoriteTitle = (item.isFavorite ?? false) ? t(en: "Unfavorite", zh: "取消收藏") : t(en: "Favorite", zh: "收藏")
        let favorite = NSMenuItem(title: favoriteTitle,
                                  action: #selector(toggleHistoryFavorite(_:)),
                                  keyEquivalent: "")
        favorite.target = self
        favorite.representedObject = item.id.uuidString
        menu.addItem(favorite)

        let addToSnippet = NSMenuItem(title: t(en: "Add to Snippet", zh: "加入 Snippet"), action: nil, keyEquivalent: "")
        let snippetSubmenu = NSMenu(title: t(en: "Add to Snippet", zh: "加入 Snippet"))
        configureSubmenuDirection(snippetSubmenu)
        let folders = snippetFoldersForContextMenu()
        if folders.isEmpty {
            let empty = NSMenuItem(title: t(en: "No Folders", zh: "没有文件夹"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            snippetSubmenu.addItem(empty)
        } else {
            for folder in folders {
                let folderItem = NSMenuItem(title: folder.title,
                                            action: #selector(addHistoryToSnippetFolder(_:)),
                                            keyEquivalent: "")
                folderItem.target = self
                folderItem.representedObject = ["clipID": item.id.uuidString, "folderID": folder.id.uuidString]
                snippetSubmenu.addItem(folderItem)
            }
        }
        addToSnippet.submenu = snippetSubmenu
        menu.addItem(addToSnippet)

        menu.addItem(NSMenuItem.separator())

        let delete = NSMenuItem(title: t(en: "Delete", zh: "删除"),
                                action: #selector(deleteHistoryItem(_:)),
                                keyEquivalent: "")
        delete.target = self
        delete.representedObject = item.id.uuidString
        menu.addItem(delete)
        return menu
    }

    private func snippetFoldersForContextMenu() -> [SnippetNode] {
        snippets.filter { $0.type == .folder }
    }

    private func plainText(for item: ClipItem) -> String {
        switch item.type {
        case .text:
            return item.text ?? ""
        case .image:
            return t(en: "(Image)", zh: "(图像)")
        case .fileURLs:
            return (item.fileURLs ?? []).joined(separator: "\n")
        }
    }

    private func snippetMenuItem(_ node: SnippetNode, centeredWidth: CGFloat? = nil) -> NSMenuItem {
        if node.type == .snippet, let centeredWidth {
            return makeCenteredSnippetMenuItem(title: node.title,
                                               action: #selector(selectSnippet(_:)),
                                               target: self,
                                               representedObject: node.id.uuidString,
                                               width: centeredWidth)
        }

        let mi = NSMenuItem(title: node.title,
                            action: node.type == .snippet ? #selector(selectSnippet(_:)) : nil,
                            keyEquivalent: "")
        mi.target = self
        if node.type == .folder {
            mi.image = folderIcon()
            let sub = NSMenu(title: node.title)
            configureSubmenuDirection(sub)
            addWideSnippetSubmenuLockIfNeeded(to: sub, folderTitle: node.title)
            let childCenteredWidth = centeredSnippetSubmenuWidth(for: node.title)
            node.children.forEach { sub.addItem(snippetMenuItem($0, centeredWidth: childCenteredWidth)) }
            mi.submenu = sub
        } else {
            mi.representedObject = node.id.uuidString
        }
        return mi
    }

    // Helper: make a standard (text-only) menu item, truncated to stay within menuWidth
    private func make(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: truncated(title, length: 28), action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func truncated(_ s: String, length: Int) -> String {
        guard s.count > length else { return s }
        return String(s.prefix(length - 1)) + "…"
    }

        private func folderIcon() -> NSImage? {
        let image = NSImage(size: folderIconSize)
        image.lockFocus()
        let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: folderIconSize.width - 3, height: folderIconSize.height - 6),
                                xRadius: 3, yRadius: 3)
        NSColor(calibratedRed: 0.42, green: 0.65, blue: 0.88, alpha: 0.95).setFill()
        body.fill()
        let tab = NSBezierPath(roundedRect: NSRect(x: 3, y: folderIconSize.height - 7, width: 7.5, height: 4),
                               xRadius: 2, yRadius: 2)
        NSColor(calibratedRed: 0.55, green: 0.74, blue: 0.92, alpha: 0.95).setFill()
        tab.fill()
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2.5, y: folderIconSize.height - 8.5, width: folderIconSize.width - 5, height: 2),
                     xRadius: 1, yRadius: 1).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func clipTypeDotImage(for item: ClipItem) -> NSImage {
        let color: NSColor
        switch item.type {
        case .text:
            color = NSColor.systemBlue.withAlphaComponent(0.8)
        case .image:
            color = NSColor.systemPurple.withAlphaComponent(0.8)
        case .fileURLs:
            color = NSColor.systemGreen.withAlphaComponent(0.8)
        }

        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 6, height: 6)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func configureSubmenuDirection(_ menu: NSMenu) {
        configureOpaqueSubmenu(menu)
    }

    private func cachedThumbnail(for item: ClipItem, maxPixelSize: CGFloat) -> NSImage? {
        ThumbnailCache.shared.image(for: item, maxPixelSize: maxPixelSize)
    }

    private func preloadThumbnailIfNeeded(for item: ClipItem) {
        // Preload both sizes used in the panel so they are ready before the user opens it
        ThumbnailCache.shared.preload(item, maxPixelSize: 60)
        ThumbnailCache.shared.preload(item, maxPixelSize: 120)
    }

    private func trimHistoryToMax() {
        HistoryStore.shared.trimToMax(settings.maxHistory)
    }

    // MARK: - Selection actions

    /// Close the panel, switch focus back to the previous app, then send ⌘V.
    private func closePanelAndPaste() {
        let target = previousApp ?? lastNonSelfFrontmostApp
        PasteboardIO.requestAccessibilityPermissionIfNeeded()

        // Auto-paste must remove the popup from focus even when the panel is pinned;
        // otherwise ⌘V can be sent while the ClipMenu panel is still the active UI.
        panel?.orderOut(nil)
        releaseRowViewsFromPanel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let target, target.bundleIdentifier != Bundle.main.bundleIdentifier, !target.isTerminated {
                target.activate(options: [.activateIgnoringOtherApps])
                self.sendPasteWhenTargetIsReady(target, attemptsLeft: 10)
            } else {
                NSApp.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    PasteboardIO.sendCommandV()
                }
            }
        }
    }

    private func sendPasteWhenTargetIsReady(_ target: NSRunningApplication, attemptsLeft: Int) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier == target.processIdentifier || attemptsLeft <= 0 {
            // Balanced mode: once the target app is frontmost, give its text field
            // a very short moment to become key before sending the paste chord.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                PasteboardIO.sendCommandV()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            self.sendPasteWhenTargetIsReady(target, attemptsLeft: attemptsLeft - 1)
        }
    }


    /// Fade the panel out, then run `completion` and restore alphaValue.
    private func dismissPanelAnimated(_ completion: (() -> Void)? = nil) {
        guard !menuPinned, let panel else { completion?(); return }
        // PopupPanel.orderOut already handles the fade-out animation.
        // Calling our own fade here would cause a double-fade flicker on selection.
        panel.orderOut(nil)
        completion?()
    }

    /// Tear down all arranged subviews and clear table data so views
    /// can be deallocated (layer backing stores freed) while panel is hidden.
    private func releaseRowViews() {
        guard let stack = panelStack else { return }
        panelClipRows.removeAll()
        inlineClipItems.removeAll()
        selectedPanelClipIndex = nil
        lastPanelRowsSignature = nil
        // Clear table — rows are gone, no leak of ClipRowCellView backing stores
        panelTableView?.reloadData()
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    /// Public trampoline so PopupPanel can call this on every orderOut path.
    func releaseRowViewsFromPanel() { releaseRowViews() }

    @objc private func selectClip(_ sender: Any) {
        let representedObject: Any?
        if let item = sender as? NSMenuItem {
            representedObject = item.representedObject
        } else if let row = sender as? HistoryFolderMenuItemView {
            representedObject = row.representedObject
        } else if let row = sender as? HistoryFolderImageMenuItemView {
            representedObject = row.representedObject
        } else if let button = sender as? PanelRowButton {
            representedObject = button.representedObject
        } else if let row = sender as? ClipRowView {
            representedObject = row.representedObject
        } else if let cell = sender as? ClipRowCellView {
            representedObject = cell.representedObject
        } else {
            representedObject = nil
        }
        guard let id = representedObject as? String,
              let item = history.first(where: { $0.id.uuidString == id }) else { return }
        PasteboardIO.write(item)
        monitor.ignoreNextPasteboardChange()
        // Auto-paste immediately after choosing a history item.
        // This avoids the extra manual ⌘V / Paste step while leaving all other UI unchanged.
        closePanelAndPaste()
    }

    @objc private func selectSnippet(_ sender: Any) {
        let representedObject: Any?
        if let item = sender as? NSMenuItem {
            representedObject = item.representedObject
        } else if let button = sender as? PanelRowButton {
            representedObject = button.representedObject
        } else {
            representedObject = nil
        }
        guard let id = representedObject as? String,
              let node = findSnippet(id: id, in: snippets) else { return }
        PasteboardIO.writeString(node.content)
        monitor.ignoreNextPasteboardChange()
        closePanelAndPaste()
    }

    @objc private func applyTextAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let text = info["text"], let actionTitle = info["action"],
              let action = TextAction.allActions(customRules: settings.customTextRules).first(where: { $0.title == actionTitle }) else { return }
        PasteboardIO.writeString(action.transform(text))
        monitor.ignoreNextPasteboardChange()
        if settings.pasteAfterSelection {
            closePanelAndPaste()
        } else {
            dismissPanelAnimated()
        }
    }

    @objc func selectSnippetFromGrid(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let node = findSnippet(id: id, in: snippets) else { return }
        PasteboardIO.writeString(node.content)
        monitor.ignoreNextPasteboardChange()
        closePanelAndPaste()
    }

    private func findSnippet(id: String, in nodes: [SnippetNode]) -> SnippetNode? {
        for node in nodes {
            if node.id.uuidString == id { return node }
            if let found = findSnippet(id: id, in: node.children) { return found }
        }
        return nil
    }

    @objc private func copyHistoryAsPlainText(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = history.first(where: { $0.id.uuidString == id }) else { return }
        PasteboardIO.writeString(plainText(for: item))
        monitor.ignoreNextPasteboardChange()
    }

    @objc private func copyHistoryCleanedText(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = history.first(where: { $0.id.uuidString == id }) else { return }
        PasteboardIO.writeString(TextAction.normalizedWhitespace(plainText(for: item)))
        monitor.ignoreNextPasteboardChange()
    }

    @objc private func showFullHistoryContent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = history.first(where: { $0.id.uuidString == id }) else { return }
        let alert = NSAlert()
        alert.messageText = t(en: "Full Content", zh: "完整内容")
        alert.informativeText = plainText(for: item)
        alert.addButton(withTitle: t(en: "Copy", zh: "复制"))
        alert.addButton(withTitle: t(en: "Close", zh: "关闭"))
        if alert.runModal() == .alertFirstButtonReturn {
            PasteboardIO.writeString(plainText(for: item))
            monitor.ignoreNextPasteboardChange()
        }
    }

    @objc private func toggleHistoryFavorite(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        HistoryStore.shared.update(id: id) { $0.isFavorite = !($0.isFavorite ?? false) }
        rebuildPanelRows()
    }

    @objc private func addHistoryToSnippetFolder(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let clipID = info["clipID"],
              let folderID = info["folderID"],
              let item = history.first(where: { $0.id.uuidString == clipID }) else { return }
        let title = truncated(clipPreview(for: item), length: 28)
        let content = plainText(for: item)
        let node = SnippetNode(type: .snippet, title: title, content: content)
        guard appendSnippet(node, toFolderID: folderID, in: &snippets) else { return }
        Storage.shared.saveSnippets(snippets)
        rebuildPanelRows()
    }

    @discardableResult
    private func appendSnippet(_ node: SnippetNode, toFolderID folderID: String, in nodes: inout [SnippetNode]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id.uuidString == folderID, nodes[index].type == .folder {
                nodes[index].children.append(node)
                return true
            }
            if appendSnippet(node, toFolderID: folderID, in: &nodes[index].children) {
                return true
            }
        }
        return false
    }

    @objc private func deleteHistoryItem(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        HistoryStore.shared.remove(id: id)
        rebuildPanelRows()
    }

    // MARK: - Menu actions
    @objc private func clearHistory() {
        if settings.confirmBeforeClearHistory {
            let alert = NSAlert()
            alert.messageText = t(en: "Clear Clipboard History?", zh: "清除剪贴板历史记录？")
            alert.informativeText = t(en: "This will remove all clipboard history items. This action cannot be undone.",
                                      zh: "这会删除所有剪贴板历史记录，且无法撤销。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: t(en: "Clear", zh: "清除"))
            alert.addButton(withTitle: t(en: "Cancel", zh: "取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        HistoryStore.shared.removeAll()
        HistoryStore.shared.saveNow()
        buildMenu()
        rebuildPanelRows()
    }

    @objc private func showPreferences() {
        if prefs == nil { prefs = PreferencesWindowController(settings: settings, snippets: snippets) }
        prefs?.delegate = self
        prefs?.showWindow(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Preferences delegate
    func preferencesDidChange(settings: AppSettings, snippets: [SnippetNode]) {
        self.settings = settings
        self.snippets = snippets
        monitor.settings = settings
        monitor.start()
        applyApplicationIcon()
        configureHotKey()
        buildMenu()
        rebuildPanelForCurrentLanguageIfNeeded()
    }

    /// The floating popup is created once and reused. Several localized strings
    /// live in the fixed header/filter/footer views, so rebuilding only the
    /// dynamic rows is not enough after switching languages. Recreate the panel
    /// to prevent Chinese labels from remaining in English mode.
    private func rebuildPanelForCurrentLanguageIfNeeded() {
        let wasVisible = panel?.isVisible == true
        panel?.orderOut(nil)
        panel = nil
        panelStack = nil
        panelSearchField = nil
        filterButtons.removeAll()
        pinButton = nil
        menuPinButton = nil
        if wasVisible {
            showPanel()
        }
    }

    // MARK: - Helpers
    private func applyApplicationIcon() {
        if let source = NSImage(named: "ClipMenu"), let icon = source.copy() as? NSImage {
            NSApplication.shared.applicationIconImage = icon
        }
        refreshStatusItemIcon()
    }

    private func refreshStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        button.toolTip = "ClipMenu"
        button.title = ""
        switch settings.appIconStyleValue {
        case .none:
            button.image = nil
            button.title = "Clip"
        case .clipboard, .backup1:
            button.image = statusSymbolImage("clipboard") ?? { button.title = "Clip"; return nil }()
        case .scissors, .backup2:
            button.image = statusSymbolImage("scissors") ?? { button.title = "Clip"; return nil }()
        case .default:
            button.image = statusResourceImage("Menu") ?? { button.title = "Clip"; return nil }()
        }
    }

    private func statusResourceImage(_ name: String) -> NSImage? {
        guard let source = NSImage(named: name), let image = source.copy() as? NSImage else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private func statusSymbolImage(_ symbolName: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private func configureHotKey() {
        if settings.hotKeyEnabled {
            HotKeyManager.shared.register(keyCode: settings.hotKeyKeyCode, modifiers: settings.hotKeyModifiers) { [weak self] in
                self?.togglePanel()
            }
        } else {
            HotKeyManager.shared.unregister()
        }
    }
}



// After a modal popUp closes, reactivate the panel and force tracking areas to re-evaluate.
private func reactivatePanel() {
    guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else { return }
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // Force all tracking areas to re-fire by posting synthetic mouseMoved events
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        let loc = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        // mouseExited on all, then mouseEntered on the one under cursor
        if let exitEvent = NSEvent.mouseEvent(with: .mouseMoved, location: loc,
                                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 0, pressure: 0) {
            panel.sendEvent(exitEvent)
        }
        // Also force ClipRowView items to re-evaluate hover from current mouse pos
        ClipRowView.refreshAllVisibleHover()
        ClipRowCellView.refreshAllVisible()
        PanelFolderButton.refreshAllVisible()
        SnippetCardView.refreshAllVisible()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        let loc = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        if let enterEvent = NSEvent.mouseEvent(with: .mouseMoved, location: loc,
                                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: panel.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 0, pressure: 0) {
            panel.sendEvent(enterEvent)
        }
        ClipRowView.refreshAllVisibleHover()
        ClipRowCellView.refreshAllVisible()
        PanelFolderButton.refreshAllVisible()
        SnippetCardView.refreshAllVisible()
    }
}

// MARK: - PopupPanel
// Floating panel with Esc-to-close support.
private final class PopupPanel: NSPanel {
    private var isAnimatingOut = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func orderFrontRegardless() {
        alphaValue = 0
        super.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    override func orderOut(_ sender: Any?) {
        guard isVisible, !isAnimatingOut else {
            super.orderOut(sender)
            return
        }
        isAnimatingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.finishOrderOut(sender)
            self.alphaValue = 1
            self.isAnimatingOut = false
        }
    }

    private func finishOrderOut(_ sender: Any?) {
        super.orderOut(sender)
        // Release row views on every close path — covers Esc, click-outside, selection, etc.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.releaseRowViewsFromPanel()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.handlePanelKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }
}

private final class PanelSearchTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateInsertionPointVisibility()
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.handlePanelKeyDown(event) {
            updateInsertionPointVisibility()
            return
        }
        super.keyDown(with: event)
        updateInsertionPointVisibility()
    }

    func updateInsertionPointVisibility() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = stringValue.isEmpty ? .clear : .labelColor
    }
}

// MARK: - FlippedView
// NSView subclass with flipped coordinates (y=0 at top)
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - WidthLockView
// A 1pt-tall transparent view whose sole job is to set the menu's minimum width.
// Because it uses a fixed frame, it cannot be stretched by text items.
private class WidthLockView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = submenuOpaqueBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = submenuOpaqueBackgroundColor.cgColor
    }

    override var intrinsicContentSize: NSSize { NSSize(width: frame.width, height: 1) }
}

private func addWideSnippetSubmenuLockIfNeeded(to menu: NSMenu, folderTitle: String) {
    guard let width = snippetSubmenuWidth(for: folderTitle) else { return }
        let item = NSMenuItem()
        item.view = WidthLockView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        menu.addItem(item)
}

private func makeCenteredSnippetMenuItem(title: String, action: Selector, target: AnyObject?, representedObject: Any?, width: CGFloat) -> NSMenuItem {
    let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
    item.target = target
    item.representedObject = representedObject
    item.view = CenteredMenuItemView(title: title, width: width)
    return item
}

private func snippetSubmenuWidth(for folderTitle: String) -> CGFloat? {
    let title = folderTitle.lowercased()
    if title.contains("特殊") || title.contains("special") {
        return 150
    }
    if title.contains("希腊")
        || title.contains("greek")
        || title.contains("数字")
        || title.contains("序号")
        || title.contains("number") {
        return 75
    }
    return nil
}

private func centeredSnippetSubmenuWidth(for folderTitle: String) -> CGFloat? {
    let title = folderTitle.lowercased()
    if title.contains("希腊")
        || title.contains("greek")
        || title.contains("数字")
        || title.contains("序号")
        || title.contains("number") {
        return snippetSubmenuWidth(for: folderTitle)
    }
    return nil
}

private final class CenteredMenuItemView: NSView {
    init(title: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        wantsLayer = true
        layer?.backgroundColor = submenuOpaqueBackgroundColor.cgColor
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 4, y: 5, width: max(1, width - 8), height: 18)
        label.alignment = .center
        label.font = NSFont.menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard let item = enclosingMenuItem, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

// MARK: - MenuMouseView
// Passes mouse events to subviews (needed inside NSMenu custom view items).
private class MenuMouseView: NSView {
    override func mouseDown(with event: NSEvent) { /* absorb so menu doesn't close */ }
    override var acceptsFirstResponder: Bool { false }
}

private final class NonHitTestingLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class HistoryFolderImageMenuItemView: NSView {
    var representedObject: Any?
    private weak var target: AnyObject?
    private let action: Selector
    private var trackRef: NSTrackingArea?
    private var isHovering = false

    init(item: ClipItem, displayNumber: Int, preview: String, thumbnail: NSImage,
         width: CGFloat, settings: AppSettings, target: AnyObject?, action: Selector) {
        self.target = target
        self.action = action
        self.representedObject = item.id.uuidString

        let thumbW = CGFloat(settings.imagePreviewWidth)
        let thumbH = CGFloat(settings.imagePreviewHeight)
        let rowH = max(CGFloat(32), thumbH + 8)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        wantsLayer = true

        let numberText = settings.markItemsWithNumbers ? "\(displayNumber)." : ""
        // Match AppKit's native menu-item title inset more closely so image
        // rows line up with the text/file rows in the same history-folder menu.
        let leadingInset: CGFloat = 6
        let numberWidth: CGFloat = settings.markItemsWithNumbers ? 22 : 12
        if settings.markItemsWithNumbers {
            let numberLabel = NSTextField(labelWithString: numberText)
            numberLabel.frame = NSRect(x: leadingInset, y: (rowH - 17) / 2, width: numberWidth, height: 17)
            numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            numberLabel.textColor = .labelColor
            numberLabel.alignment = .right
            addSubview(numberLabel)
        }

        let dotSize: CGFloat = 6
        let dot = NSView(frame: NSRect(x: leadingInset + numberWidth + 6, y: (rowH - dotSize) / 2, width: dotSize, height: dotSize))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotSize / 2
        dot.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.85).cgColor
        addSubview(dot)

        thumbnail.size = NSSize(width: thumbW, height: thumbH)
        let imageX = leadingInset + numberWidth + 18
        let imageView = NSImageView(frame: NSRect(x: imageX, y: (rowH - thumbH) / 2, width: thumbW, height: thumbH))
        imageView.image = thumbnail
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 3
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        let label = NSTextField(labelWithString: preview)
        let textX = imageX + thumbW + 8
        label.frame = NSRect(x: textX, y: (rowH - 17) / 2, width: max(80, width - textX - 12), height: 17)
        label.font = settings.changeFontSize && settings.fontSizeModeValue == .select
            ? NSFont.menuFont(ofSize: CGFloat(settings.selectedFontSize))
            : NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackRef { removeTrackingArea(trackRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackRef = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setHoverFeedback(true) }
    override func mouseMoved(with event: NSEvent) { setHoverFeedback(true) }
    override func mouseExited(with event: NSEvent) { setHoverFeedback(false) }

    private func setHoverFeedback(_ active: Bool) {
        isHovering = active
        layer?.backgroundColor = active
            ? LiquidGlassStyle.hoverFill.cgColor
            : NSColor.clear.cgColor
        layer?.cornerRadius = 8
        needsDisplay = true
        layer?.setNeedsDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        if let target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}

private final class HistoryFolderMenuItemView: NSView {
    private static let visibleRows = NSHashTable<HistoryFolderMenuItemView>.weakObjects()
    private static var sharedHoverTimer: Timer?

    var representedObject: Any?
    private weak var target: AnyObject?
    private let action: Selector
    private var trackRef: NSTrackingArea?
    private var isHovering = false

    init(item: ClipItem, displayNumber: Int, preview: String, width: CGFloat, settings: AppSettings, target: AnyObject?, action: Selector) {
        self.target = target
        self.action = action
        self.representedObject = item.id.uuidString

        let thumbW = item.type == .image && settings.showImagesInMenu ? CGFloat(settings.imagePreviewWidth) : 0
        let thumbH = item.type == .image && settings.showImagesInMenu ? CGFloat(settings.imagePreviewHeight) : 0
        let rowH = max(CGFloat(30), thumbH + 8)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))

        wantsLayer = true

        let leadingInset: CGFloat = 8
        let numberWidth: CGFloat = settings.markItemsWithNumbers ? 28 : 0
        if settings.markItemsWithNumbers {
            let numberLabel = NSTextField(labelWithString: "\(displayNumber).")
            numberLabel.frame = NSRect(x: leadingInset, y: (rowH - 17) / 2, width: numberWidth, height: 17)
            numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            numberLabel.textColor = .labelColor
            numberLabel.alignment = .right
            addSubview(numberLabel)
        }

        let dotX = leadingInset + numberWidth + (numberWidth > 0 ? 8 : 4)
        let dot = NSView(frame: NSRect(x: dotX, y: (rowH - 6) / 2, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        switch item.type {
        case .text:
            dot.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        case .image:
            dot.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.8).cgColor
        case .fileURLs:
            dot.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
        }
        addSubview(dot)

        var textX: CGFloat = dotX + 18
        if item.type == .image,
           settings.showImagesInMenu,
           let thumbnail = cachedThumbnail(for: item, maxPixelSize: 120) {
            thumbnail.size = NSSize(width: thumbW, height: thumbH)
            let imageView = NSImageView(frame: NSRect(x: textX, y: (rowH - thumbH) / 2, width: thumbW, height: thumbH))
            imageView.image = thumbnail
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 3
            imageView.layer?.masksToBounds = true
            addSubview(imageView)
            textX += thumbW + 8
        }

        let label = NSTextField(labelWithString: preview)
        label.font = settings.changeFontSize && settings.fontSizeModeValue == .select
            ? NSFont.menuFont(ofSize: CGFloat(settings.selectedFontSize))
            : NSFont.menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: textX, y: (rowH - 17) / 2, width: max(80, width - textX - 18), height: 17)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        Self.visibleRows.remove(self)
        Self.stopSharedHoverPollingIfUnused()
    }

    override func mouseEntered(with event: NSEvent) {
        setHoverFeedback(true)
    }

    override func mouseMoved(with event: NSEvent) {
        // NSMenu custom views can miss a mouseEntered event when the cursor
        // moves upward from a lower pop-up/menu region. Treat mouseMoved inside
        // the row as a hover refresh so feedback is direction-independent.
        setHoverFeedback(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHoverFeedback(false)
    }

    override func updateTrackingAreas() {
        if let trackRef { removeTrackingArea(trackRef) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .assumeInside]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackRef = area
        super.updateTrackingAreas()
        refreshHoverFromCurrentMouseLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.visibleRows.remove(self)
            Self.stopSharedHoverPollingIfUnused()
            setHoverFeedback(false)
        } else {
            Self.visibleRows.add(self)
            Self.startSharedHoverPollingIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.refreshHoverFromCurrentMouseLocation()
            }
        }
    }

    static func refreshVisibleRowsHover() {
        let rows = Set(visibleRows.allObjects + visibleRowsDiscoveredInOpenWindows())
        for row in rows {
            row.refreshHoverFromCurrentMouseLocation()
        }
    }

    private static func visibleRowsDiscoveredInOpenWindows() -> [HistoryFolderMenuItemView] {
        var rows: [HistoryFolderMenuItemView] = []
        for window in NSApp.windows where window.isVisible {
            guard let contentView = window.contentView else { continue }
            collectRows(in: contentView, into: &rows)
        }
        return rows
    }

    private static func collectRows(in view: NSView, into rows: inout [HistoryFolderMenuItemView]) {
        if let row = view as? HistoryFolderMenuItemView {
            rows.append(row)
        }
        for subview in view.subviews {
            collectRows(in: subview, into: &rows)
        }
    }

    private static func startSharedHoverPollingIfNeeded() {
        guard sharedHoverTimer == nil else { return }
        // 15 fps is sufficient as a fallback; tracking areas handle the fast path.
        // Timer is started only when rows are visible (viewDidMoveToWindow) and
        // stopped when all rows are gone, so it never runs while panel is closed.
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { _ in
            refreshVisibleRowsHover()
        }
        sharedHoverTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func stopSharedHoverPollingIfUnused() {
        guard visibleRows.allObjects.isEmpty else { return }
        sharedHoverTimer?.invalidate()
        sharedHoverTimer = nil
    }

    private func refreshHoverFromCurrentMouseLocation() {
        guard let window, !isHidden, alphaValue > 0 else { return }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(pointInWindow, from: nil)
        setHoverFeedback(bounds.contains(point))
    }

    private func setHoverFeedback(_ active: Bool) {
        isHovering = active
        layer?.backgroundColor = active
            ? LiquidGlassStyle.hoverFill.cgColor
            : NSColor.clear.cgColor
        layer?.cornerRadius = 8
        needsDisplay = true
        layer?.setNeedsDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        if let target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}

// MARK: - SearchFieldContainer
// Uses a plain NSTextField because NSSearchField inside NSMenu can break IME marked text.
private class SearchFieldContainer: NSView {
    weak var textField: NSTextField?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 9

        let icon = NSImageView(frame: NSRect(x: 8, y: 7, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.autoresizingMask = [.maxXMargin]
        addSubview(icon)
    }

    override func mouseDown(with event: NSEvent) {
        guard let sf = textField else { return }
        // Activate the app window that hosts this menu view
        if let window = sf.window {
            window.makeFirstResponder(sf)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - FilterButton
// Fires action on mouseDown (not mouseUp) for instant response inside NSMenu custom views.
class FilterButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        if let t = target, let a = action { NSApp.sendAction(a, to: t, from: self) }
    }
}

private protocol HoverSubmenuPresenter: AnyObject {
    var hoverMenuToShow: NSMenu? { get }
    var hoverSourceView: NSView { get }
    func hoverMenuOrigin() -> NSPoint
    func hoverMenuWillOpen()
    func hoverMenuDidClose()
}

private final class HoverSubmenuCoordinator {
    static let shared = HoverSubmenuCoordinator()

    private weak var currentPresenter: (any HoverSubmenuPresenter)?
    private weak var currentMenu: NSMenu?
    private weak var pendingPresenter: (any HoverSubmenuPresenter)?
    private var isPresenting = false
    private var pollingTimer: Timer?
    private var pendingCloseTimer: Timer?
    private var mouseMoveMonitor: Any?

    func present(_ presenter: any HoverSubmenuPresenter) {
        guard presenter.hoverMenuToShow != nil else { return }

        if isPresenting {
            guard presenter !== currentPresenter else { return }
            cancelPendingClose()
            pendingPresenter = presenter
            currentMenu?.cancelTrackingWithoutAnimation()
            return
        }

        isPresenting = true
        startPolling()

        var presenterToShow: (any HoverSubmenuPresenter)? = presenter
        while let activePresenter = presenterToShow,
              let menu = activePresenter.hoverMenuToShow {
            pendingPresenter = nil
            currentPresenter = activePresenter
            currentMenu = menu
            activePresenter.hoverMenuWillOpen()
            DispatchQueue.main.async { Self.applyOpaqueBackgroundToVisibleMenuWindows() }
            menu.popUp(positioning: nil,
                       at: activePresenter.hoverMenuOrigin(),
                       in: activePresenter.hoverSourceView)
            activePresenter.hoverMenuDidClose()

            if let nextPresenter = pendingPresenter,
               nextPresenter !== activePresenter,
               nextPresenter.hoverMenuToShow != nil {
                presenterToShow = nextPresenter
            } else {
                presenterToShow = nil
            }
        }

        stopPolling()
        cancelPendingClose()
        currentPresenter = nil
        currentMenu = nil
        pendingPresenter = nil
        isPresenting = false
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.050, repeats: true) { [weak self] _ in
            self?.switchIfMouseMovedToAnotherPresenter()
        }
        pollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)

        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            self?.switchIfMouseMovedToAnotherPresenter()
            return event
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        cancelPendingClose()
        if let mouseMoveMonitor {
            NSEvent.removeMonitor(mouseMoveMonitor)
            self.mouseMoveMonitor = nil
        }
    }

    private func switchIfMouseMovedToAnotherPresenter() {
        Self.applyOpaqueBackgroundToVisibleMenuWindows()
        HistoryFolderMenuItemView.refreshVisibleRowsHover()
        ClipRowView.refreshAllVisibleHover()
        ClipRowCellView.refreshAllVisible()
        PanelFolderButton.refreshAllVisible()
        SnippetCardView.refreshAllVisible()
        guard isPresenting else { return }
        let target = presenterUnderMouse()
        if let target, target !== currentPresenter {
            // Mouse moved to a different HoverSubmenuPresenter — switch
            cancelPendingClose()
            pendingPresenter = target
            currentMenu?.cancelTrackingWithoutAnimation()
        } else if target != nil {
            cancelPendingClose()
        } else if target == nil, mouseIsInsideCurrentPresenterWindow() {
            // Mouse is back inside the source panel but not over a presenter.
            // Give the cursor a short grace period to cross the gap into the
            // popup menu; otherwise fast diagonal movement can close it.
            schedulePendingCloseIfNeeded()
        } else {
            cancelPendingClose()
        }
    }

    private func schedulePendingCloseIfNeeded() {
        guard pendingCloseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pendingCloseTimer = nil
            guard self.isPresenting,
                  self.presenterUnderMouse() == nil,
                  self.mouseIsInsideCurrentPresenterWindow() else { return }
            self.currentMenu?.cancelTrackingWithoutAnimation()
        }
        pendingCloseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func cancelPendingClose() {
        pendingCloseTimer?.invalidate()
        pendingCloseTimer = nil
    }

    private func mouseIsInsideCurrentPresenterWindow() -> Bool {
        guard let sourceWindow = currentPresenter?.hoverSourceView.window else { return false }
        return sourceWindow.isVisible && sourceWindow.frame.contains(NSEvent.mouseLocation)
    }

    private func presenterUnderMouse() -> (any HoverSubmenuPresenter)? {
        let mouseLocation = NSEvent.mouseLocation
        for window in NSApp.windows where window is NSPanel && window.isVisible {
            guard let contentView = window.contentView else { continue }
            let windowPoint = window.convertPoint(fromScreen: mouseLocation)
            let contentPoint = contentView.convert(windowPoint, from: nil)
            guard contentView.bounds.contains(contentPoint),
                  let hitView = contentView.hitTest(contentPoint) else { continue }

            var view: NSView? = hitView
            while let currentView = view {
                if let presenter = currentView as? any HoverSubmenuPresenter {
                    return presenter
                }
                view = currentView.superview
            }
        }
        return nil
    }

    private static func applyOpaqueBackgroundToVisibleMenuWindows() {
        for window in NSApp.windows where window.isVisible {
            let className = NSStringFromClass(type(of: window))
            guard className.localizedCaseInsensitiveContains("Menu"),
                  !(window is PopupPanel) else { continue }
            window.backgroundColor = submenuOpaqueBackgroundColor
            window.isOpaque = true
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = submenuOpaqueBackgroundColor.cgColor
                contentView.layer?.opacity = 1
            }
        }
    }
}

private class PanelRowButton: NSButton {
    var representedObject: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isBordered = false
        alignment = .left
        font = .systemFont(ofSize: 14, weight: .semibold)
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = LiquidGlassStyle.rowRadius
        setButtonType(.momentaryChange)
    }
}

private final class PanelFolderButton: PanelRowButton, HoverSubmenuPresenter {
    // Static registry so reactivatePanel can force-clear stale hover after popup closes.
    private static let visibleButtons = NSHashTable<PanelFolderButton>.weakObjects()
    static func refreshAllVisible() {
        for btn in visibleButtons.allObjects { btn.syncHoverVisual() }
    }

    var menuToShow: NSMenu?
    var hoverMenuYOffset: CGFloat = 0
    private var trackRef: NSTrackingArea?
    private var isHovering = false
    private var hasPendingAutoShow = false
    private var hasShownForCurrentHover = false
    private weak var disclosureArrow: NSTextField?

    var hoverMenuToShow: NSMenu? { menuToShow }
    var hoverSourceView: NSView { self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { Self.visibleButtons.remove(self) }
        else             { Self.visibleButtons.add(self) }
    }

    func addDisclosureArrow(width: CGFloat) {
        disclosureArrow?.removeFromSuperview()
        let arrow = NonHitTestingLabel(labelWithString: "›")
        arrow.font = .systemFont(ofSize: 22, weight: .regular)
        arrow.textColor = LiquidGlassStyle.softText.withAlphaComponent(0.48)
        arrow.alignment = .center
        arrow.frame = NSRect(x: width - 30, y: (bounds.height - 22) / 2 - 1, width: 28, height: 22)
        arrow.isSelectable = false
        addSubview(arrow)
        disclosureArrow = arrow
    }


    override func updateTrackingAreas() {
        if let t = trackRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackRef = t
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        beginHover()
    }

    override func mouseMoved(with event: NSEvent) {
        beginHover()
    }

    private func beginHover() {
        isHovering = true
        applyHoverFeedback()
        if hasPendingAutoShow || hasShownForCurrentHover { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autoShow), object: nil)
        hasPendingAutoShow = true
        perform(#selector(autoShow), with: nil, afterDelay: 0.08)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hasPendingAutoShow = false
        hasShownForCurrentHover = false
        layer?.backgroundColor = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autoShow), object: nil)
    }

    @objc private func autoShow() {
        hasPendingAutoShow = false
        HoverSubmenuCoordinator.shared.present(self)
    }

    override func mouseDown(with event: NSEvent) {
        hasPendingAutoShow = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autoShow), object: nil)
        guard menuToShow != nil else { super.mouseDown(with: event); return }
        HoverSubmenuCoordinator.shared.present(self)
    }

    func hoverMenuOrigin() -> NSPoint {
        NSPoint(x: bounds.maxX + 4, y: bounds.maxY + hoverMenuYOffset)
    }

    func hoverMenuWillOpen() {
        hasPendingAutoShow = false
        hasShownForCurrentHover = true
        applyHoverFeedback()
    }

    func hoverMenuDidClose() {
        resetHoverStateIfMouseIsOutside()
        if !isHovering { layer?.backgroundColor = nil }
        reactivatePanel()
    }

    private func applyHoverFeedback() {
        wantsLayer = true
        layer?.cornerRadius = LiquidGlassStyle.rowRadius
        layer?.backgroundColor = LiquidGlassStyle.hoverFill.cgColor
        layer?.borderWidth = 0
    }

    /// Recalculate isHovering from the current mouse position AND
    /// immediately update the visual state to match. Safe to call at any time.
    private func syncHoverVisual() {
        resetHoverStateIfMouseIsOutside()
        if isHovering {
            applyHoverFeedback()
        } else {
            layer?.backgroundColor = nil
        }
    }

    private func resetHoverStateIfMouseIsOutside() {
        guard let window else {
            isHovering = false
            hasShownForCurrentHover = false
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(pointInWindow, from: nil)
        if !bounds.contains(point) {
            isHovering = false
            hasShownForCurrentHover = false
        } else {
            isHovering = true
            applyHoverFeedback()
        }
    }
}

private extension NSTextField {
    var hasMarkedTextInCurrentEditor: Bool {
        guard let editor = currentEditor() as? NSTextView else { return false }
        return editor.hasMarkedText()
    }
}


// MARK: - FooterBarView
// Three equal-width footer buttons in one horizontal row
final class FooterBarView: NSView {
    init(width: CGFloat, height: CGFloat,
         clearTitle: String,
         prefsTitle: String,
         quitTitle: String,
         clearTarget: AnyObject?, clearAction: Selector,
         prefsTarget: AnyObject?, prefsAction: Selector,
         quitTarget: AnyObject?, quitAction: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true

        // Keep the footer separator visually lightweight and place it between
        // the snippet cards above and the footer buttons below with equal air.
        let dividerGap: CGFloat = 12
        let btnH: CGFloat = 36
        let lineY = height - dividerGap - 4.25
        let sep = LiquidDividerView(frame: NSRect(x: 0, y: lineY, width: width, height: 1))
        addSubview(sep)

        let btnY: CGFloat = max(0, lineY - dividerGap - btnH)
        let btnW = width / 3
        let items: [(String, String, AnyObject?, Selector)] = [
            ("trash", clearTitle, clearTarget, clearAction),
            ("clock", prefsTitle, prefsTarget, prefsAction),
            ("arrow.up.to.line", quitTitle, quitTarget, quitAction),
        ]
        for (i, (symbol, label, target, action)) in items.enumerated() {
            let btn = FooterButton(title: label, target: target, action: action)
            btn.frame = NSRect(x: CGFloat(i) * btnW, y: btnY, width: btnW, height: btnH)
            // Add SF Symbol icon
            let conf = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
            btn.imagePosition = .imageLeading
            btn.imageHugsTitle = true
            addSubview(btn)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}
// MARK: - NSMenuDelegate
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusActivationMenu {
            isHandlingStatusActivationMenu = true
            menu.cancelTrackingWithoutAnimation()
            DispatchQueue.main.async { [weak self] in
                self?.handleStatusItemActivation()
                self?.isHandlingStatusActivationMenu = false
            }
            return
        }

        isMenuOpen = true
        if menuNeedsRefresh {
            updateDynamicSection()
            menuNeedsRefresh = false
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === statusActivationMenu {
            return
        }

        isMenuOpen = false
        guard menuPinned, !isReopeningPinnedMenu else { return }
        isReopeningPinnedMenu = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            if self.menuPinned {
                self.showPanel()
            }
            self.isReopeningPinnedMenu = false
        }
    }
}

// MARK: - Design Components (PinButton, ClipRowView, SnippetGridRowView, FooterButton)
import Cocoa

// MARK: - PinButton
// Toggleable pin button: default = gray icon; pinned = red fill + white icon
final class PinButton: NSButton {
    var isPinned: Bool = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }

    private func configure() {
        bezelStyle = .texturedRounded
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 13
        updateAppearance()
    }

    private func updateAppearance() {
        if isPinned {
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
            layer?.borderWidth = 0.7
            layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.26).cgColor
            let conf = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pin")?
                .withSymbolConfiguration(conf)
            contentTintColor = .systemRed
        } else {
            layer?.backgroundColor = LiquidGlassStyle.translucentControlFill.cgColor
            layer?.borderWidth = 0.7
            layer?.borderColor = LiquidGlassStyle.glassLine.cgColor
            let conf = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")?
                .withSymbolConfiguration(conf)
            contentTintColor = .secondaryLabelColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let t = target, let a = action { NSApp.sendAction(a, to: t, from: self) }
    }
}

// MARK: - ClipTableView
// Plain NSTableView used as the reusable host for inline clip rows.
// Passes mouse events through to cell views so hover/tracking works naturally.
final class ClipTableView: NSTableView {
    override var isFlipped: Bool { true }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent)  { super.mouseExited(with: event)  }

    // Ensure the table never steals key focus from the panel search field.
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - ClipRowCellView
// NSView used as an NSTableView cell — reused across scrolling/rebuild cycles.
// Internally identical to ClipRowView but designed for dequeue/reuse.
final class ClipRowCellView: NSView {
    /// Static registry so reactivatePanel / coordinator polling can force-refresh
    /// hover state on all visible cells after a modal popup closes.
    private static let visibleCells = NSHashTable<ClipRowCellView>.weakObjects()

    static func refreshAllVisible() {
        for cell in visibleCells.allObjects {
            cell.refreshHoverState()
        }
    }

    var representedObject: Any?

    private let button = PanelRowButton(frame: .zero)
    private weak var _target: AnyObject?
    private var _action: Selector?
    private var trackRef: NSTrackingArea?
    private var isHovering = false
    private var isKeyboardSelected = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 38))
        self.identifier = identifier
        wantsLayer = true
        layer?.cornerRadius = LiquidGlassStyle.rowRadius
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configure (called on dequeue and on first creation)
    func configure(item: ClipItem, number: Int, settings: AppSettings,
                   isKeyboardSelected: Bool,
                   contextMenu: NSMenu?,
                   target: AnyObject?, action: Selector?) {
        self.representedObject = item.id.uuidString
        self._target = target
        self._action = action
        self.isKeyboardSelected = isKeyboardSelected

        // Remove old subviews before reconfiguring
        subviews.forEach { $0.removeFromSuperview() }

        // ── Number label ──────────────────────────────────────────────────
        let displayNumber = settings.numberItemsFromZero ? number - 1 : number
        let numLabel = NSTextField(labelWithString: "\(displayNumber)")
        numLabel.frame = NSRect(x: 0, y: 11, width: 20, height: 16)
        numLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        numLabel.textColor = LiquidGlassStyle.softText.withAlphaComponent(0.48)
        numLabel.alignment = .center
        addSubview(numLabel)

        // ── Color dot ─────────────────────────────────────────────────────
        let dot = NSView(frame: NSRect(x: 22, y: 16, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        switch item.type {
        case .text:     dot.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        case .image:    dot.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.8).cgColor
        case .fileURLs: dot.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
        }
        addSubview(dot)

        // ── Favorite star ─────────────────────────────────────────────────
        var textX: CGFloat = 32
        if item.isFavorite == true {
            let star = NSTextField(labelWithString: "★")
            star.frame = NSRect(x: textX, y: 11, width: 14, height: 16)
            star.font = .systemFont(ofSize: 11, weight: .semibold)
            star.textColor = .systemYellow
            star.alignment = .center
            addSubview(star)
            textX += 18
        }

        // ── Shortcut pill ─────────────────────────────────────────────────
        let w = bounds.width
        let shortcutW: CGFloat = 28
        let shortcutH: CGFloat = 18
        var pillRight: CGFloat = 4
        if settings.addNumericKeyEquivalents && number <= 10 {
            let pill = NSTextField(labelWithString: "⌘\(number % 10)")
            pill.frame = NSRect(x: w - shortcutW - 2, y: (38 - shortcutH) / 2, width: shortcutW, height: shortcutH)
            pill.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            pill.textColor = LiquidGlassStyle.softText.withAlphaComponent(0.58)
            pill.alignment = .center
            pill.wantsLayer = true
            pill.layer?.backgroundColor = LiquidGlassStyle.translucentControlFill.cgColor
            pill.layer?.cornerRadius = 8
            pill.layer?.borderWidth = 0.5
            pill.layer?.borderColor = LiquidGlassStyle.glassLine.cgColor
            addSubview(pill)
            pillRight = shortcutW + 6
        }

        // ── Content (image or text) ───────────────────────────────────────
        if item.type == .image, let img = cachedThumbnail(for: item, maxPixelSize: 60) {
            img.size = NSSize(width: 32, height: 22)
            let imgView = NSImageView(frame: NSRect(x: textX, y: 8, width: 32, height: 22))
            imgView.image = img
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 6
            imgView.layer?.masksToBounds = true
            addSubview(imgView)
            let imgLabel = NSTextField(labelWithString: settings.text(en: "(Image)", zh: "(图像)"))
            imgLabel.frame = NSRect(x: textX + 38, y: 11, width: 60, height: 16)
            imgLabel.font = .systemFont(ofSize: 12, weight: .medium)
            imgLabel.textColor = LiquidGlassStyle.softText
            addSubview(imgLabel)
        } else {
            let maxLen = settings.menuPreviewLength
            let raw = item.preview
            let preview = raw.count > maxLen ? String(raw.prefix(maxLen - 1)) + "…" : raw
            let textLabel = NSTextField(labelWithString: preview)
            textLabel.frame = NSRect(x: textX, y: 11, width: w - textX - pillRight - 4, height: 16)
            textLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
            textLabel.textColor = .labelColor
            textLabel.lineBreakMode = .byTruncatingTail
            addSubview(textLabel)
        }

        // ── Click button ──────────────────────────────────────────────────
        button.frame = bounds
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(clicked)
        button.menu = contextMenu
        addSubview(button)

        if let menu = contextMenu { self.menu = menu }
        refreshHoverState()
    }

    @objc private func clicked() {
        guard let t = _target, let a = _action else { return }
        NSApp.sendAction(a, to: t, from: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Hover (same pattern as ClipRowView)
    override func updateTrackingAreas() {
        if let trackRef { removeTrackingArea(trackRef) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .assumeInside]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackRef = area
        super.updateTrackingAreas()
        refreshHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.visibleCells.remove(self)
        } else {
            Self.visibleCells.add(self)
            DispatchQueue.main.async { [weak self] in self?.refreshHoverState() }
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true;  applyBackground() }
    override func mouseMoved(with event: NSEvent)   { isHovering = true;  applyBackground() }
    override func mouseExited(with event: NSEvent)  { isHovering = false; applyBackground() }

    private func refreshHoverState() {
        guard let window else { return }
        let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        isHovering = bounds.contains(p)
        applyBackground()
    }

    func setKeyboardSelected(_ selected: Bool) {
        isKeyboardSelected = selected
        applyBackground()
    }

    private func applyBackground() {
        if isKeyboardSelected {
            layer?.backgroundColor = LiquidGlassStyle.selectedStart.withAlphaComponent(0.18).cgColor
            layer?.borderWidth = 1.0
            layer?.borderColor = LiquidGlassStyle.selectedStart.withAlphaComponent(0.5).cgColor
        } else if isHovering {
            layer?.backgroundColor = LiquidGlassStyle.hoverFill.cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.white.withAlphaComponent(0.52).cgColor
        } else {
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }
}

// MARK: - ClipRowView
// A custom row view for history items: index number + color dot + text + shortcut pill
final class ClipRowView: NSView {
    // Static registry of all visible ClipRowView instances for forced hover refresh
    private static let visibleRows = NSHashTable<ClipRowView>.weakObjects()

    var representedObject: Any?

    private let button: PanelRowButton
    private var trackRef: NSTrackingArea?
    private var isHovering = false
    private var isKeyboardSelected = false
    private weak var _target: AnyObject?
    private var _action: Selector?

    init(item: ClipItem, number: Int, settings: AppSettings,
         width: CGFloat, height: CGFloat,
         target: AnyObject?, action: Selector?) {
        self.button = PanelRowButton(frame: .zero)
        self._target = target
        self._action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.representedObject = item.id.uuidString
        build(item: item, number: number, settings: settings, width: width, height: height)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        Self.visibleRows.remove(self)
    }

    /// Refresh hover state on all visible ClipRowView instances.
    /// Called after modal popup menus close so that tracking areas re-evaluate
    /// even when the mouse moved while a popUp was stealing events.
    static func refreshAllVisibleHover() {
        for row in visibleRows.allObjects {
            row.refreshHoverFromCurrentMouseLocation()
        }
    }

    private func build(item: ClipItem, number: Int, settings: AppSettings,
        width: CGFloat, height: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = LiquidGlassStyle.rowRadius

        // Hover tracking is installed in updateTrackingAreas so it stays valid
        // after stack/layout changes.

        // Index number
        let displayNumber = settings.numberItemsFromZero ? number - 1 : number
        let numLabel = NSTextField(labelWithString: "\(displayNumber)")
        numLabel.frame = NSRect(x: 0, y: (height - 16) / 2, width: 20, height: 16)
        numLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        numLabel.textColor = LiquidGlassStyle.softText.withAlphaComponent(0.48)
        numLabel.alignment = .center
        addSubview(numLabel)

        // Color type dot
        let dot = NSView(frame: NSRect(x: 22, y: (height - 6) / 2, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        switch item.type {
        case .text:     dot.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        case .image:    dot.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.8).cgColor
        case .fileURLs: dot.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
        }
        addSubview(dot)

        // Shortcut pill (⌘N) — right side
        let shortcutW: CGFloat = 28
        let shortcutH: CGFloat = 18
        var shortcutView: NSView? = nil
        if settings.addNumericKeyEquivalents && number <= 10 {
            let pill = NSTextField(labelWithString: "⌘\(number % 10)")
            pill.frame = NSRect(x: width - shortcutW - 2, y: (height - shortcutH) / 2,
                                width: shortcutW, height: shortcutH)
            pill.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            pill.textColor = LiquidGlassStyle.softText.withAlphaComponent(0.58)
            pill.alignment = .center
            pill.wantsLayer = true
            pill.layer?.backgroundColor = LiquidGlassStyle.translucentControlFill.cgColor
            pill.layer?.cornerRadius = 8
            pill.layer?.borderWidth = 0.5
            pill.layer?.borderColor = LiquidGlassStyle.glassLine.cgColor
            addSubview(pill)
            shortcutView = pill
        }

        // Preview text
        var textX: CGFloat = 32
        if item.isFavorite ?? false {
            let star = NSTextField(labelWithString: "★")
            star.frame = NSRect(x: textX, y: (height - 16) / 2, width: 14, height: 16)
            star.font = .systemFont(ofSize: 11, weight: .semibold)
            star.textColor = .systemYellow
            star.alignment = .center
            addSubview(star)
            textX += 18
        }
        let textRight = shortcutView != nil ? shortcutW + 6 : 4
        let maxLen = settings.menuPreviewLength
        let preview: String
        if item.type == .image {
            preview = settings.text(en: "(Image)", zh: "(图像)")
        } else {
            let raw = item.preview
            preview = raw.count > maxLen ? String(raw.prefix(maxLen - 1)) + "…" : raw
        }

        if item.type == .image,
           let img = cachedThumbnail(for: item, maxPixelSize: 60) {
            img.size = NSSize(width: 32, height: 22)
            let imgView = NSImageView(frame: NSRect(x: textX, y: (height - 22) / 2, width: 32, height: 22))
            imgView.image = img
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 6
            imgView.layer?.masksToBounds = true
            addSubview(imgView)
            let imgLabel = NSTextField(labelWithString: settings.text(en: "(Image)", zh: "(图像)"))
            imgLabel.frame = NSRect(x: textX + 38, y: (height - 16) / 2,
                                     width: 60, height: 16)
            imgLabel.font = .systemFont(ofSize: 12, weight: .medium)
            imgLabel.textColor = LiquidGlassStyle.softText
            addSubview(imgLabel)
        } else {
            let textLabel = NSTextField(labelWithString: preview)
            textLabel.frame = NSRect(x: textX, y: (height - 16) / 2,
                                      width: width - textX - textRight - shortcutW - 4, height: 16)
            textLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
            textLabel.textColor = .labelColor
            textLabel.lineBreakMode = .byTruncatingTail
            addSubview(textLabel)
        }

        // Invisible full-size click button on top
        button.frame = bounds
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(clicked)
        addSubview(button)
    }

    func setContextMenu(_ contextMenu: NSMenu) {
        self.menu = contextMenu
        button.menu = contextMenu
    }

    func setKeyboardSelected(_ selected: Bool) {
        isKeyboardSelected = selected
        setHoverFeedback(isHovering)
    }

    func showCopiedFeedback(title: String) {
        let badge = NSTextField(labelWithString: "✓ \(title)")
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.88).cgColor
        badge.layer?.cornerRadius = 9
        badge.frame = NSRect(x: bounds.width - 84, y: (bounds.height - 20) / 2, width: 76, height: 20)
        badge.alphaValue = 0
        addSubview(badge)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            badge.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    badge.animator().alphaValue = 0
                } completionHandler: {
                    badge.removeFromSuperview()
                }
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func clicked() {
        guard let t = _target, let a = _action else { return }
        NSApp.sendAction(a, to: t, from: self)
    }

    override func updateTrackingAreas() {
        if let trackRef { removeTrackingArea(trackRef) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .assumeInside]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackRef = area
        super.updateTrackingAreas()
        refreshHoverFromCurrentMouseLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.visibleRows.remove(self)
        } else {
            Self.visibleRows.add(self)
            DispatchQueue.main.async { [weak self] in
                self?.refreshHoverFromCurrentMouseLocation()
            }
        }
    }

    override func mouseEntered(with event: NSEvent) { setHoverFeedback(true) }
    override func mouseMoved(with event: NSEvent) { setHoverFeedback(true) }
    override func mouseExited(with event: NSEvent) { setHoverFeedback(false) }

    private func refreshHoverFromCurrentMouseLocation() {
        guard let window else { return }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(pointInWindow, from: nil)
        setHoverFeedback(bounds.contains(point))
    }

    private func setHoverFeedback(_ active: Bool) {
        isHovering = active
        let highlighted = active || isKeyboardSelected
        layer?.backgroundColor = highlighted
            ? LiquidGlassStyle.hoverFill.cgColor
            : nil
        layer?.borderWidth = highlighted ? 0.5 : 0
        layer?.borderColor = highlighted ? LiquidGlassStyle.glassLineStrong.cgColor : nil
        needsDisplay = true
        layer?.setNeedsDisplay()
    }
}


// MARK: - SVG icon helpers
private func svgImage(pathData: String, viewBox: CGFloat = 1024, size: CGFloat = 14, color: NSColor) -> NSImage {
    // Build a minimal SVG string with the path and a fill color
    let c = color.usingColorSpace(.sRGB) ?? color
    let r = Int(c.redComponent * 255)
    let g = Int(c.greenComponent * 255)
    let b = Int(c.blueComponent * 255)
    let hex = String(format: "#%02X%02X%02X", r, g, b)
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(viewBox)) \(Int(viewBox))" width="\(Int(size))" height="\(Int(size))">
    <path d="\(pathData)" fill="\(hex)"/>
    </svg>
    """
    guard let data = svg.data(using: .utf8), let img = NSImage(data: data) else {
        return NSImage(size: NSSize(width: size, height: size))
    }
    img.size = NSSize(width: size, height: size)
    return img
}

private let svgBiaodian = "M906.688 398.592c0 85.76-15.552 136.448-66.176 218.624-52.224 83.776-154.56 165.952-228.992 204.16l-23.808-45.952c64.128-45.504 105.472-81.152 150.976-168.512 12.928-24.832 20.16-46.528 24.32-66.176a155.264 155.264 0 0 1-31.552 3.072A170.304 170.304 0 0 1 561.28 373.248a170.304 170.304 0 0 1 170.112-170.56c78.08 0 144.192 52.672 163.84 125.056 7.232 20.672 11.392 43.968 11.392 70.848z m-444.032 0c0 85.76-15.552 136.448-66.176 218.624-52.224 83.776-154.56 165.952-228.992 204.16l-23.808-45.952c64.128-45.504 105.472-81.152 150.976-168.512 12.928-24.832 20.16-46.528 24.32-66.176a155.328 155.328 0 0 1-31.552 3.072 170.304 170.304 0 0 1-170.112-170.56 170.304 170.304 0 0 1 170.112-170.56c78.08 0 144.192 52.672 163.84 125.056 7.232 20.672 11.392 43.968 11.392 70.848z"

private let svgXila = "M84.992 569.3952c10.9824-138.0608 88.064-297.8816 200.3456-397.184l67.84 76.6976c-92.3136 81.664-157.2096 216.832-166.0928 328.6016-4.4288 55.6032 5.504 98.816 25.3184 126.6688 18.0736 25.4208 49.408 45.2352 106.8544 45.2352 31.3088 0 51.84-10.5472 67.584-27.0336 17.2288-18.0736 31.1552-46.08 41.3184-83.6352 20.5312-75.8016 20.8384-170.9312 20.8384-247.2448h102.4v2.816c0 73.1648 0 180.992-24.3968 271.1808-12.4416 46.0288-32.4352 92.288-66.0736 127.5648-35.1744 36.864-82.5088 58.752-141.6704 58.752-84.5568 0-149.7856-31.3088-190.3104-88.2688-38.7584-54.528-49.4592-124.8768-43.9552-194.1504z M923.264 569.3952c-10.9824-138.0608-88.064-297.8816-200.32-397.184l-67.84 76.6976c92.288 81.664 157.184 216.832 166.0928 328.6016 4.4032 55.6032-5.504 98.816-25.344 126.6688-18.048 25.4208-49.408 45.2352-106.8544 45.2352-31.3088 0-51.8144-10.5472-67.5584-27.0336-17.2288-18.0736-31.1808-46.08-41.344-83.6352-20.5056-75.8016-20.8384-170.9312-20.8384-247.2448h-102.4v2.816c0 73.1648 0 180.992 24.3968 271.1808 12.4672 46.0288 32.4352 92.288 66.0992 127.5648 35.1488 36.864 82.5088 58.752 141.6448 58.752 84.5824 0 149.7856-31.3088 190.3104-88.2688 38.784-54.528 49.4592-124.8768 43.9552-194.1504z"

private let svgZhanghao = "M514.558721 0c143.8001 0 259.966017 114.630685 259.966017 255.872064s-116.677661 255.872064-259.966017 255.872064c-143.8001 0-259.966017-114.630685-259.966017-255.872064-0.511744-141.241379 116.165917-255.872064 259.966017-255.872064z M416.815592 597.205397h216.97951c185.763118 0 336.215892 147.894053 336.215893 330.586707v21.493253c0 72.155922-150.452774 74.714643-336.215893 74.714643H416.815592c-185.763118 0-336.215892 0-336.215892-74.714643v-21.493253c0-182.692654 150.452774-330.586707 336.215892-330.586707z"

// MARK: - SnippetGridRowView
// Two snippet folder cards side by side — with colored icon circles matching design
final class SnippetGridRowView: NSView {
    private var leftMenu: NSMenu?
    private var rightMenu: NSMenu?

    init(left: SnippetNode, right: SnippetNode?,
         colWidth: CGFloat, height: CGFloat, totalWidth: CGFloat,
         target: AnyObject?) {
        super.init(frame: NSRect(x: 0, y: 0, width: totalWidth, height: height + 6))
        let leftCard = buildCard(node: left, x: 0, colWidth: colWidth, height: height, target: target, isLeft: true)
        addSubview(leftCard)
        if let right = right {
            let rightCard = buildCard(node: right, x: colWidth + 8, colWidth: colWidth, height: height, target: target, isLeft: false)
            addSubview(rightCard)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildCard(node: SnippetNode, x: CGFloat, colWidth: CGFloat,
                           height: CGFloat, target: AnyObject?, isLeft: Bool) -> SnippetCardView {
        let colors = iconColors(for: node.title)
        let card = SnippetCardView(frame: NSRect(x: x, y: 2, width: colWidth, height: height))
        card.isRightColumn = !isLeft
        card.wantsLayer = true
        LiquidGlassStyle.applyGlassLayer(card.layer, radius: 8, fill: LiquidGlassStyle.cardFill)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = LiquidGlassStyle.glassLineStrong.cgColor
        card.layer?.shadowOpacity = 0.06
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = CGSize(width: 0, height: -5)

        // Colored icon circle
        let iconSize: CGFloat = 26
        let iconBg = NSView(frame: NSRect(x: 8, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
        iconBg.wantsLayer = true
        iconBg.layer?.backgroundColor = colors.bg.cgColor
        iconBg.layer?.cornerRadius = iconSize / 2
        card.addSubview(iconBg)

        let customSvg = customSvgPath(for: node.title)
        if let svgPath = customSvg {
            let imgView = NSImageView(frame: NSRect(x: (iconSize - 11) / 2, y: (iconSize - 11) / 2, width: 11, height: 11))
            imgView.image = svgImage(pathData: svgPath, size: 11, color: colors.fg)
            imgView.imageScaling = .scaleProportionallyUpOrDown
            iconBg.addSubview(imgView)
        } else {
            let iconLabel = NSTextField(labelWithString: folderEmoji(for: node.title))
            iconLabel.frame = NSRect(x: 0, y: (iconSize - 14) / 2, width: iconSize, height: 14)
            iconLabel.font = .systemFont(ofSize: 11)
            iconLabel.alignment = .center
            iconLabel.textColor = colors.fg
            iconLabel.maximumNumberOfLines = 1
            iconBg.addSubview(iconLabel)
        }

        // Title
        let title = NSTextField(labelWithString: node.title)
        title.frame = NSRect(x: 42, y: (height - 16) / 2, width: colWidth - 62, height: 16)
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        card.addSubview(title)

        // Chevron
        let chev = NSTextField(labelWithString: "›")
        chev.frame = NSRect(x: colWidth - 20, y: (height - 20) / 2, width: 14, height: 20)
        chev.font = .systemFont(ofSize: 18, weight: .regular)
        chev.textColor = LiquidGlassStyle.softText.withAlphaComponent(0.48)
        card.addSubview(chev)

        // Store submenu for click
        if node.type == .folder {
            let sub = NSMenu(title: node.title)
            configureOpaqueSubmenu(sub)
            addWideSnippetSubmenuLockIfNeeded(to: sub, folderTitle: node.title)
            for child in node.children {
                let mi = NSMenuItem(title: child.title,
                                     action: #selector(AppDelegate.selectSnippetFromGrid(_:)),
                                     keyEquivalent: "")
                mi.target = target
                mi.representedObject = child.id.uuidString
                sub.addItem(mi)
            }
            card.menuToShow = sub
        }

        return card
    }

    private struct IconColors { let bg: NSColor; let fg: NSColor }

    private func iconColors(for title: String) -> IconColors {
        let t = title.lowercased()
        let dark = LiquidGlassStyle.isDark
        // In dark mode use transparent tinted fills; in light mode use light pastels.
        func bg(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            dark ? NSColor(red: r * 0.5, green: g * 0.5, blue: b * 0.5, alpha: 0.55)
                 : NSColor(red: r, green: g, blue: b, alpha: 1)
        }
        if t.contains("账号") || t.contains("account") { return IconColors(bg: bg(1, 0.95, 0.80), fg: .systemOrange) }
        if t.contains("联系") || t.contains("contact") { return IconColors(bg: bg(0.85, 0.95, 0.85), fg: .systemGreen) }
        if t.contains("希腊") || t.contains("greek")   { return IconColors(bg: bg(0.92, 0.90, 0.98), fg: .systemPurple) }
        if t.contains("标点") || t.contains("punct")   { return IconColors(bg: bg(1, 0.95, 0.88), fg: .systemOrange) }
        if t.contains("数字") || t.contains("number")  { return IconColors(bg: bg(0.92, 0.95, 1), fg: .systemBlue) }
        if t.contains("特殊") || t.contains("special") { return IconColors(bg: bg(1, 0.92, 0.92), fg: .systemRed) }
        if t.contains("email") || t.contains("mail")   { return IconColors(bg: bg(0.88, 0.95, 1), fg: .systemBlue) }
        if t.contains("url") || t.contains("link")     { return IconColors(bg: bg(0.85, 0.95, 0.85), fg: .systemGreen) }
        return IconColors(bg: dark ? NSColor.white.withAlphaComponent(0.10) : NSColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1),
                          fg: .secondaryLabelColor)
    }

    private func customSvgPath(for title: String) -> String? {
        let t = title.lowercased()
        if t.contains("标点") || t.contains("punct") { return svgBiaodian }
        if t.contains("希腊") || t.contains("greek") { return svgXila }
        if t.contains("账号") || t.contains("account") { return svgZhanghao }
        return nil
    }

    private func folderEmoji(for title: String) -> String {
        let t = title.lowercased()
        if t.contains("账号") || t.contains("account") { return "🔑" }
        if t.contains("联系") || t.contains("contact") { return "📞" }
        if t.contains("希腊") || t.contains("greek") { return "Α" }
        if t.contains("标点") || t.contains("punct") { return "，" }
        if t.contains("数字") || t.contains("number") { return "①" }
        if t.contains("特殊") || t.contains("special") { return "★" }
        if t.contains("email") || t.contains("mail") { return "✉️" }
        if t.contains("url") || t.contains("link") { return "🔗" }
        return "📁"
    }
}

// Clickable snippet card with hover + directional submenu
private final class SnippetCardView: NSView, HoverSubmenuPresenter {
    // Static registry for forced hover refresh after popup closes.
    private static let visibleCards = NSHashTable<SnippetCardView>.weakObjects()
    static func refreshAllVisible() {
        for card in visibleCards.allObjects { card.syncHoverVisual() }
    }

    var menuToShow: NSMenu?
    var isRightColumn: Bool = false
    private var trackRef: NSTrackingArea?
    private var isHovering = false
    private var hasPendingAutoShow = false
    private var hasShownForCurrentHover = false

    var hoverMenuToShow: NSMenu? { menuToShow }
    var hoverSourceView: NSView { self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { Self.visibleCards.remove(self) }
        else             { Self.visibleCards.add(self) }
    }

    override func updateTrackingAreas() {
        if let t = trackRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackRef = t
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        beginHover()
    }

    override func mouseMoved(with event: NSEvent) {
        beginHover()
    }

    private func beginHover() {
        isHovering = true
        applyHoverFeedback()
        if hasPendingAutoShow || hasShownForCurrentHover { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autoShow), object: nil)
        hasPendingAutoShow = true
        perform(#selector(autoShow), with: nil, afterDelay: 0.08)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hasPendingAutoShow = false
        hasShownForCurrentHover = false
        layer?.backgroundColor = LiquidGlassStyle.cardFill.cgColor
        layer?.borderColor = LiquidGlassStyle.glassLineStrong.cgColor
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autoShow), object: nil)
    }

    private func menuOrigin() -> NSPoint {
        if isRightColumn {
            return NSPoint(x: bounds.maxX + 4, y: bounds.maxY)
        } else {
            guard let menu = menuToShow else { return .zero }
            return NSPoint(x: -menu.size.width - 4, y: bounds.maxY)
        }
    }

    @objc private func autoShow() {
        hasPendingAutoShow = false
        HoverSubmenuCoordinator.shared.present(self)
    }

    override func mouseDown(with event: NSEvent) {
        hasPendingAutoShow = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autoShow), object: nil)
        guard menuToShow != nil else { return }
        HoverSubmenuCoordinator.shared.present(self)
    }

    func hoverMenuOrigin() -> NSPoint {
        menuOrigin()
    }

    func hoverMenuWillOpen() {
        hasPendingAutoShow = false
        hasShownForCurrentHover = true
        applyHoverFeedback()
    }

    func hoverMenuDidClose() {
        resetHoverStateIfMouseIsOutside()
        if !isHovering {
            layer?.backgroundColor = LiquidGlassStyle.cardFill.cgColor
            layer?.borderColor = LiquidGlassStyle.glassLineStrong.cgColor
        }
        reactivatePanel()
    }

    private func applyHoverFeedback() {
        layer?.backgroundColor = LiquidGlassStyle.hoverFill.cgColor
        layer?.borderColor = LiquidGlassStyle.glassLineStrong.cgColor
    }

    /// Recalculate isHovering from the current mouse position AND
    /// immediately update the visual state to match. Safe to call at any time.
    private func syncHoverVisual() {
        resetHoverStateIfMouseIsOutside()
        if isHovering {
            applyHoverFeedback()
        } else {
            layer?.backgroundColor = LiquidGlassStyle.cardFill.cgColor
            layer?.borderColor = LiquidGlassStyle.glassLineStrong.cgColor
        }
    }

    private func resetHoverStateIfMouseIsOutside() {
        guard let window else {
            isHovering = false
            hasShownForCurrentHover = false
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(pointInWindow, from: nil)
        if !bounds.contains(point) {
            isHovering = false
            hasShownForCurrentHover = false
        } else {
            isHovering = true
            applyHoverFeedback()
        }
    }
}

// MARK: - FooterButton
// Footer command button with muted style; danger variant turns red on hover
final class FooterButton: NSButton {
    private var isDanger: Bool = false
    private var isHovered: Bool = false {
        didSet { needsDisplay = true; updateStyle() }
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isDanger = title.contains("清除") || title.lowercased().contains("clear")
        updateStyle()
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        alignment = .center
        font = .systemFont(ofSize: 12.5, weight: .bold)
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 14
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    private func updateStyle() {
        if isDanger && isHovered {
            contentTintColor = .systemRed
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
            layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
            layer?.borderWidth = 0.7
        } else {
            contentTintColor = isDanger ? LiquidGlassStyle.softText : .labelColor
            layer?.backgroundColor = isHovered
                ? LiquidGlassStyle.hoverFill.cgColor
                : NSColor.clear.cgColor
            layer?.borderColor = isHovered ? LiquidGlassStyle.glassLine.cgColor : NSColor.clear.cgColor
            layer?.borderWidth = isHovered ? 0.7 : 0
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}
