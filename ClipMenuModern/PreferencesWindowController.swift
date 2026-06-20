import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

protocol PreferencesWindowControllerDelegate: AnyObject {
    func preferencesDidChange(settings: AppSettings, snippets: [SnippetNode])
}

final class PreferencesWindowController: NSWindowController {
    private static let snippetDragType = NSPasteboard.PasteboardType("com.local.ClipMenuModern.snippet-row")

    weak var delegate: PreferencesWindowControllerDelegate?
    private var settings: AppSettings
    private var snippets: [SnippetNode]

    private enum Pane: String, CaseIterable {
        case general = "General"
        case menu = "Menu"
        case type = "Type"
        case action = "Action"
        case snippet = "Snippet"
        case shortcuts = "Shortcuts"
        case updates = "Updates"

        func title(settings: AppSettings) -> String {
            switch self {
            case .general: return settings.text(en: "General", zh: "通用")
            case .menu: return settings.text(en: "Menu", zh: "菜单")
            case .type: return settings.text(en: "Type", zh: "类型")
            case .action: return settings.text(en: "Action", zh: "操作")
            case .snippet: return settings.text(en: "Snippet", zh: "片段")
            case .shortcuts: return settings.text(en: "Shortcuts", zh: "快捷键")
            case .updates: return settings.text(en: "Updates", zh: "更新")
            }
        }
    }

    private final class ToolbarItemView: NSView {
        let pane: Pane
        let imageView = NSImageView()
        let label = NSTextField(labelWithString: "")
        let button = NSButton(title: "", target: nil, action: nil)

        init(pane: Pane, image: NSImage, title: String) {
            self.pane = pane
            super.init(frame: NSRect(x: 0, y: 0, width: 78, height: 78))
            wantsLayer = true

            imageView.frame = NSRect(x: 18, y: 34, width: 42, height: 42)
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            addSubview(imageView)

            label.stringValue = title
            label.alignment = .center
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.frame = NSRect(x: 0, y: 8, width: 78, height: 18)
            addSubview(label)

            button.frame = bounds
            button.bezelStyle = .shadowlessSquare
            button.isBordered = false
            addSubview(button)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setSelected(_ selected: Bool) {
            layer?.cornerRadius = 8
            layer?.backgroundColor = selected ? NSColor.systemGreen.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
            label.textColor = selected ? NSColor.systemGreen : NSColor.secondaryLabelColor
            label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .medium)
        }

        func setTitle(_ title: String) {
            label.stringValue = title
        }
    }

    private let rootView = NSView()
    private let toolbarView = NSView()
    private let contentContainer = NSView()
    private let toolbarHeight: CGFloat = 92
    private let generalContentHeight: CGFloat = 660
    private let contentLeft: CGFloat = 104
    private let contentWidth: CGFloat = 760
    private let labelColumnWidth: CGFloat = 300
    private let controlColumnX: CGFloat = 430
    private let sectionTitleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    private let subsectionTitleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 14)
    private let secondaryFont = NSFont.systemFont(ofSize: 13)
    private let standardControlHeight: CGFloat = 32
    private var toolbarItems: [Pane: ToolbarItemView] = [:]
    private var currentPane: Pane = .general
    private var selectedTypeSegment = 1
    private let languagePopup = NSPopUpButton()

    private let maxHistoryField = NSTextField()
    private let previewHistoryField = NSTextField()
    private let pageSizeField = NSTextField()
    private let secondFolderSizeField = NSTextField()
    private let menuPreviewLengthField = NSTextField()
    private let showImagesInMenuButton = NSButton(checkboxWithTitle: "Show Image", target: nil, action: nil)
    private let imageWidthField = NSTextField()
    private let imageHeightField = NSTextField()
    private let captureTextButton = NSButton(checkboxWithTitle: "Capture text", target: nil, action: nil)
    private let captureImagesButton = NSButton(checkboxWithTitle: "Capture images", target: nil, action: nil)
    private let captureFilesButton = NSButton(checkboxWithTitle: "Capture file URLs", target: nil, action: nil)
    private let pasteAfterButton = NSButton(checkboxWithTitle: "Input \"⌘ + V\" after menu item selection", target: nil, action: nil)
    private let hotKeyButton = NSButton(checkboxWithTitle: "Enable global menu shortcut: Control + Option + Command + V", target: nil, action: nil)
    private let launchOnLoginButton = NSButton(checkboxWithTitle: "Launch on Login", target: nil, action: nil)
    private let saveHistoryOnQuitButton = NSButton(checkboxWithTitle: "Save clipboard history on quit", target: nil, action: nil)
    private let confirmClearButton = NSButton(checkboxWithTitle: "Show alert panel before clear history", target: nil, action: nil)
    private let enableActionsButton = NSButton(checkboxWithTitle: "Enable Action", target: nil, action: nil)
    private let invokeSingleActionButton = NSButton(checkboxWithTitle: "Invoke an action immediately if only one action was registered", target: nil, action: nil)
    private let markNumbersButton = NSButton(checkboxWithTitle: "Mark menu items with numbers", target: nil, action: nil)
    private let numberFromZeroButton = NSButton(checkboxWithTitle: "Menu items' title starts with 0", target: nil, action: nil)
    private let numericKeyButton = NSButton(checkboxWithTitle: "Add key equivalents to numeric keys", target: nil, action: nil)
    private let showLabelsButton = NSButton(checkboxWithTitle: "Show labels to indicate item types", target: nil, action: nil)
    private let addClearItemButton = NSButton(checkboxWithTitle: "Add a menu item to clear clipboard history", target: nil, action: nil)
    private let showToolTipButton = NSButton(checkboxWithTitle: "Show tool tip on a menu item", target: nil, action: nil)
    private let maxToolTipField = NSTextField()
    private let changeFontSizeButton = NSButton(checkboxWithTitle: "Change font size in the menu", target: nil, action: nil)
    private let fitFontRadio = NSButton(radioButtonWithTitle: "Fit to the icon size", target: nil, action: nil)
    private let selectFontRadio = NSButton(radioButtonWithTitle: "Select:", target: nil, action: nil)
    private let fontSizePopup = NSPopUpButton()
    private let showIconButton = NSButton(checkboxWithTitle: "Show Icon in the Menu", target: nil, action: nil)
    private let iconSizeField = NSTextField()
    private var iconModePopups: [NSPopUpButton] = []
    private var iconCodeFields: [NSTextField] = []
    private var customRuleNameFields: [NSTextField] = []
    private var customRuleFindFields: [NSTextField] = []
    private var customRuleReplaceFields: [NSTextField] = []

    private let sortOrderPopup = NSPopUpButton()
    private let autosavePopup = NSPopUpButton()
    private let exportAsPopup = NSPopUpButton()
    private let separatorPopup = NSPopUpButton()
    private let statusBarIconPopup = NSPopUpButton()
    private let snippetsPositionPopup = NSPopUpButton()
    private let intervalSlider = NSSlider(value: 1.0, minValue: 0.2, maxValue: 5.0, target: nil, action: nil)
    private let intervalValueLabel = NSTextField(labelWithString: "1 sec.")
    private let excludedAppsLabel = NSTextField(labelWithString: "No excluded applications")

    private let folderTable = SnippetTableView()
    private let titleTable = SnippetTableView()
    private let contentTextView = SnippetContentTextView()
    private var selectedFolderIndex: Int? = 0
    private var selectedSnippetIndex: Int? = 0
    private var isReloadingSnippetTables = false

    init(settings: AppSettings, snippets: [SnippetNode]) {
        self.settings = settings
        self.snippets = snippets
        let window = PreferencesWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: toolbarHeight + generalContentHeight),
                                       styleMask: [.titled, .closable, .miniaturizable],
                                       backing: .buffered,
                                       defer: false)
        window.title = Pane.general.title(settings: settings)
        window.minSize = NSSize(width: 820, height: 640)
        window.center()
        super.init(window: window)
        buildWindow()
        loadValues()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildWindow() {
        guard let window = window else { return }
        window.contentView = rootView
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        toolbarView.frame = NSRect(x: 0, y: rootView.bounds.height - toolbarHeight, width: rootView.bounds.width, height: toolbarHeight)
        toolbarView.autoresizingMask = [.width, .minYMargin]
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        rootView.addSubview(toolbarView)

        let bottomLine = NSBox(frame: NSRect(x: 0, y: 0, width: rootView.bounds.width, height: 1))
        bottomLine.boxType = .separator
        bottomLine.autoresizingMask = [.width, .minYMargin]
        toolbarView.addSubview(bottomLine)

        buildToolbar()

        contentContainer.frame = NSRect(x: 0, y: 0, width: rootView.bounds.width, height: rootView.bounds.height - toolbarHeight)
        contentContainer.autoresizingMask = [.width, .height]
        rootView.addSubview(contentContainer)
        showPane(.general)
    }

    private func buildToolbar() {
        let itemWidth: CGFloat = 78
        let spacing: CGFloat = 18
        let totalWidth = CGFloat(Pane.allCases.count) * itemWidth + CGFloat(Pane.allCases.count - 1) * spacing
        let availableWidth = window?.contentView?.bounds.width ?? 920
        let startX = max(CGFloat(18), (availableWidth - totalWidth) / 2)
        for (index, pane) in Pane.allCases.enumerated() {
            let item = ToolbarItemView(pane: pane, image: toolbarImage(for: pane), title: pane.title(settings: settings))
            item.frame.origin = NSPoint(x: startX + CGFloat(index) * (itemWidth + spacing), y: 8)
            item.button.tag = index
            item.button.target = self
            item.button.action = #selector(toolbarButtonClicked(_:))
            toolbarView.addSubview(item)
            toolbarItems[pane] = item
        }
        updateToolbarSelection()
    }

    private func paneColor(for pane: Pane) -> NSColor {
        switch pane {
        case .general: return NSColor.systemGreen
        case .menu: return NSColor.systemBlue
        case .type: return NSColor.systemTeal
        case .action: return NSColor.systemOrange
        case .snippet: return NSColor.systemPink
        case .shortcuts: return NSColor.systemPurple
        case .updates: return NSColor.systemYellow
        }
    }

    private func toolbarImage(for pane: Pane) -> NSImage {
        let imageName: NSImage.Name
        switch pane {
        case .general: imageName = NSImage.Name("NSPreferencesGeneral")
        case .menu: imageName = NSImage.Name("Menu")
        case .type: imageName = NSImage.Name("ComposingPreferences")
        case .action: imageName = NSImage.Name("ActionIconLarge")
        case .snippet: imageName = NSImage.Name("AddSnippet")
        case .shortcuts: imageName = NSImage.Name("PTKeyboardIcon")
        case .updates: imageName = NSImage.Name("SparkleIcon")
        }
        if let source = NSImage(named: imageName), let image = source.copy() as? NSImage {
            image.size = NSSize(width: 42, height: 42)
            return image
        }

        let symbolName: String
        switch pane {
        case .general: symbolName = "gearshape"
        case .menu: symbolName = "menubar.rectangle"
        case .type: symbolName = "doc.on.clipboard"
        case .action: symbolName = "wrench.and.screwdriver"
        case .snippet: symbolName = "square.and.pencil"
        case .shortcuts: symbolName = "keyboard"
        case .updates: symbolName = "sparkles"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
    }

    private func updateToolbarSelection() {
        for (pane, item) in toolbarItems {
            item.setTitle(pane.title(settings: settings))
            item.setSelected(pane == currentPane)
        }
    }

    @objc private func toolbarButtonClicked(_ sender: NSButton) {
        let panes = Pane.allCases
        guard sender.tag >= 0, sender.tag < panes.count else { return }
        showPane(panes[sender.tag])
    }

    private func showPane(_ pane: Pane) {
        applyCurrentTextEdit()
        currentPane = pane
        resizeWindow(for: pane)
        window?.title = pane.title(settings: settings)
        updateToolbarSelection()
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch pane {
        case .general: view = generalView()
        case .menu: view = menuView()
        case .type: view = typeView()
        case .action: view = actionView()
        case .snippet: view = snippetsView()
        case .shortcuts: view = shortcutsView()
        case .updates: view = updatesView()
        }
        view.frame = contentContainer.bounds
        view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(view)
    }

    private func resizeWindow(for pane: Pane) {
        let size: NSSize
        switch pane {
        case .general:
            size = NSSize(width: 920, height: toolbarHeight + generalContentHeight)
        case .menu:
            size = NSSize(width: 920, height: 900)
        case .type:
            size = NSSize(width: 920, height: 820)
        case .snippet:
            size = NSSize(width: 920, height: 820)
        case .action:
            size = NSSize(width: 920, height: 660)
        case .shortcuts, .updates:
            size = NSSize(width: 920, height: 560)
        }
        guard let window else { return }
        var frame = window.frame
        let oldTop = frame.maxY
        frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        frame.origin.y = oldTop - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    private func t(en: String, zh: String) -> String {
        settings.text(en: en, zh: zh)
    }

    private var optionMap: [String: String] {
        [
            "Chinese": "中文",
            "English": "English",
            "Date Created": "创建时间",
            "Last Used": "最近使用",
            "Never": "从不",
            "Every minute": "每分钟",
            "Every 5 minutes": "每 5 分钟",
            "Every 10 minutes": "每 10 分钟",
            "Every 30 minutes": "每 30 分钟",
            "Every hour": "每小时",
            "Every 3 hours": "每 3 小时",
            "Every 6 hours": "每 6 小时",
            "Every 12 hours": "每 12 小时",
            "Every day": "每天",
            "Single file": "单个文件",
            "Multiple files": "多个文件",
            "Tab": "制表符",
            "Space": "空格",
            "None": "无",
            "Default": "默认",
            "Clipboard": "剪贴板",
            "Scissors": "剪刀",
            "Below the clipboard history": "在剪贴板历史记录下方",
            "Above the clipboard history": "在剪贴板历史记录上方",
            "File type code": "文件类型代码",
            "File extension": "文件扩展名",
            "Pop up Action Menu": "弹出操作菜单",
            "Uppercase": "转为大写",
            "Lowercase": "转为小写",
            "Capitalize": "首字母大写",
            "Trim Whitespace": "去除首尾空白",
            "Remove Line Breaks": "移除换行",
            "Delete Empty Lines": "删除空行",
            "Merge Multiple Lines": "合并多行",
            "Clean DOI / PMID": "DOI / PMID 清理",
            "Replace Chinese Punctuation": "替换中文标点为英文标点",
            "Add Space Between Numbers and Units": "数字与单位之间加空格",
            "URL Encode": "URL 编码",
            "URL Decode": "URL 解码"
        ]
    }

    private func optionTitle(_ raw: String) -> String {
        settings.usesChinese ? (optionMap[raw] ?? raw) : raw
    }

    private func rawOption(_ display: String) -> String {
        if !settings.usesChinese { return display }
        return optionMap.first(where: { $0.value == display })?.key ?? display
    }

    private func refreshCurrentPane() {
        updateToolbarSelection()
        window?.title = currentPane.title(settings: settings)
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch currentPane {
        case .general: view = generalView()
        case .menu: view = menuView()
        case .type: view = typeView()
        case .action: view = actionView()
        case .snippet: view = snippetsView()
        case .shortcuts: view = shortcutsView()
        case .updates: view = updatesView()
        }
        view.frame = contentContainer.bounds
        view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(view)
        loadValues()
    }

    private func styleField(_ field: NSTextField) {
        field.font = bodyFont
        field.controlSize = .regular
    }

    private func stylePopup(_ popup: NSPopUpButton) {
        popup.font = bodyFont
        popup.controlSize = .regular
    }

    private func styleCheckbox(_ button: NSButton) {
        button.font = bodyFont
        button.controlSize = .regular
    }

    private func styleButton(_ button: NSButton) {
        button.font = bodyFont
        button.controlSize = .regular
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont? = nil, alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font ?? bodyFont
        label.alignment = alignment
        label.frame = NSRect(x: x, y: y, width: width, height: 22)
        return label
    }

    private func addSection(_ title: String, to view: NSView, y: CGFloat) {
        let titleLabel = label(title, x: contentLeft, y: y, width: contentWidth, font: sectionTitleFont)
        view.addSubview(titleLabel)
    }

    private func addDivider(to view: NSView, y: CGFloat) {
        let divider = NSBox(frame: NSRect(x: contentLeft, y: y, width: contentWidth, height: 1))
        divider.boxType = .separator
        view.addSubview(divider)
    }

    private func addFormLabel(_ text: String, to view: NSView, y: CGFloat, width: CGFloat? = nil) {
        view.addSubview(label(text, x: contentLeft, y: y + 4, width: width ?? labelColumnWidth))
    }

    private func addCard(to view: NSView, frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 0.75
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.16).cgColor
        view.addSubview(card)
        return card
    }

    private func generalView() -> NSView {
        let view = NSView()
        let contentHeight = generalContentHeight

        let pageW: CGFloat = 800
        let pageX = (contentContainer.bounds.width - pageW) / 2
        let gap: CGFloat = 18
        let colW = (pageW - gap) / 2
        let leftX = pageX
        let rightX = pageX + colW + gap
        let cardPad: CGFloat = 18

        func compactTitle(_ title: String, in card: NSView, y: CGFloat) {
            let field = label(title, x: cardPad, y: y, width: card.frame.width - cardPad * 2, font: sectionTitleFont)
            card.addSubview(field)
        }

        func compactLabel(_ text: String, in card: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
            let field = label(text, x: x, y: y + 4, width: width, font: bodyFont)
            card.addSubview(field)
        }

        func sectionCard(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSView {
            addCard(to: view, frame: NSRect(x: x, y: y, width: width, height: height))
        }

        let topY = contentHeight - 112
        let languageCard = sectionCard(x: leftX, y: topY, width: colW, height: 86)
        compactTitle(t(en: "Language", zh: "语言"), in: languageCard, y: 52)
        compactLabel(t(en: "Interface language:", zh: "界面语言："), in: languageCard, x: cardPad, y: 18, width: 140)
        languagePopup.frame = NSRect(x: 156, y: 16, width: colW - 174, height: standardControlHeight)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languageCard.addSubview(languagePopup)

        let behaviorCard = sectionCard(x: rightX, y: topY, width: colW, height: 86)
        compactTitle(t(en: "Behavior", zh: "行为"), in: behaviorCard, y: 52)
        launchOnLoginButton.frame = NSRect(x: cardPad, y: 28, width: colW - cardPad * 2, height: 22)
        behaviorCard.addSubview(launchOnLoginButton)
        pasteAfterButton.frame = NSRect(x: cardPad, y: 6, width: colW - cardPad * 2, height: 22)
        behaviorCard.addSubview(pasteAfterButton)

        let historyY: CGFloat = 206
        let historyCard = sectionCard(x: pageX, y: historyY, width: pageW, height: 320)
        compactTitle(t(en: "Clipboard History", zh: "剪贴板历史记录"), in: historyCard, y: 284)

        let labelX: CGFloat = cardPad
        let controlX: CGFloat = 390
        let controlW: CGFloat = 318
        var rowY: CGFloat = 240

        compactLabel(t(en: "Max clipboard history size:", zh: "剪贴板历史记录最大数量："), in: historyCard, x: labelX, y: rowY, width: 280)
        maxHistoryField.frame = NSRect(x: controlX, y: rowY, width: 88, height: standardControlHeight)
        historyCard.addSubview(maxHistoryField)
        historyCard.addSubview(label(t(en: "items", zh: "条"), x: controlX + 102, y: rowY + 4, width: 60))

        rowY -= 36
        compactLabel(t(en: "Sort history order by:", zh: "历史记录排序方式："), in: historyCard, x: labelX, y: rowY, width: 280)
        sortOrderPopup.frame = NSRect(x: controlX, y: rowY, width: controlW, height: standardControlHeight)
        sortOrderPopup.target = self
        sortOrderPopup.action = #selector(settingChanged(_:))
        historyCard.addSubview(sortOrderPopup)

        rowY -= 36
        compactLabel(t(en: "Autosaving clipboard history:", zh: "自动保存剪贴板历史记录："), in: historyCard, x: labelX, y: rowY, width: 280)
        autosavePopup.frame = NSRect(x: controlX, y: rowY, width: controlW, height: standardControlHeight)
        autosavePopup.target = self
        autosavePopup.action = #selector(settingChanged(_:))
        historyCard.addSubview(autosavePopup)

        rowY -= 32
        saveHistoryOnQuitButton.frame = NSRect(x: labelX, y: rowY, width: 360, height: 24)
        historyCard.addSubview(saveHistoryOnQuitButton)

        rowY -= 36
        compactLabel(t(en: "Export clipboard history as:", zh: "导出剪贴板历史记录为："), in: historyCard, x: labelX, y: rowY, width: 280)
        exportAsPopup.frame = NSRect(x: controlX, y: rowY, width: controlW, height: standardControlHeight)
        exportAsPopup.target = self
        exportAsPopup.action = #selector(settingChanged(_:))
        historyCard.addSubview(exportAsPopup)

        rowY -= 36
        compactLabel(t(en: "separator:", zh: "分隔符："), in: historyCard, x: labelX, y: rowY, width: 280)
        separatorPopup.frame = NSRect(x: controlX, y: rowY, width: controlW, height: standardControlHeight)
        separatorPopup.target = self
        separatorPopup.action = #selector(settingChanged(_:))
        historyCard.addSubview(separatorPopup)

        rowY -= 38
        let exportButton = NSButton(title: t(en: "Export…", zh: "导出…"), target: self, action: #selector(exportHistoryAction))
        styleButton(exportButton)
        exportButton.frame = NSRect(x: controlX, y: rowY, width: 120, height: standardControlHeight)
        historyCard.addSubview(exportButton)
        let importButton = NSButton(title: t(en: "Import…", zh: "导入…"), target: self, action: #selector(importHistoryAction))
        styleButton(importButton)
        importButton.frame = NSRect(x: controlX + 132, y: rowY, width: 120, height: standardControlHeight)
        historyCard.addSubview(importButton)

        let bottomCard = sectionCard(x: pageX, y: 34, width: pageW, height: 154)
        compactTitle(t(en: "Appearance", zh: "外观"), in: bottomCard, y: 118)
        compactLabel(t(en: "Status Bar icon style:", zh: "状态栏图标样式："), in: bottomCard, x: labelX, y: 80, width: 220)
        statusBarIconPopup.frame = NSRect(x: 210, y: 80, width: 180, height: standardControlHeight)
        statusBarIconPopup.target = self
        statusBarIconPopup.action = #selector(settingChanged(_:))
        bottomCard.addSubview(statusBarIconPopup)

        compactTitle(t(en: "Time interval", zh: "时间间隔"), in: bottomCard, y: 118)
        let timeTitle = bottomCard.subviews.last as? NSTextField
        timeTitle?.frame.origin.x = 430
        timeTitle?.frame.size.width = 220
        compactLabel(t(en: "Observe clipboard:", zh: "检查剪贴板："), in: bottomCard, x: 430, y: 80, width: 120)
        intervalSlider.frame = NSRect(x: 538, y: 83, width: 130, height: 24)
        intervalSlider.target = self
        intervalSlider.action = #selector(intervalSliderChanged(_:))
        bottomCard.addSubview(intervalSlider)
        intervalValueLabel.font = bodyFont
        intervalValueLabel.frame = NSRect(x: 680, y: 84, width: 62, height: 22)
        bottomCard.addSubview(intervalValueLabel)

        let line = NSBox(frame: NSRect(x: cardPad, y: 62, width: pageW - cardPad * 2, height: 1))
        line.boxType = .separator
        bottomCard.addSubview(line)

        compactTitle(t(en: "Exclude Applications", zh: "排除应用程序"), in: bottomCard, y: 28)
        let excludeButton = NSButton(title: t(en: "Define Exclude Options…", zh: "设置排除选项…"), target: self, action: #selector(excludeAppsAction))
        styleButton(excludeButton)
        let excludeButtonWidth: CGFloat = 220
        let excludeButtonX = (pageW - excludeButtonWidth) / 2
        excludeButton.frame = NSRect(x: excludeButtonX, y: 18, width: excludeButtonWidth, height: standardControlHeight)
        bottomCard.addSubview(excludeButton)
        excludedAppsLabel.font = secondaryFont
        excludedAppsLabel.textColor = .secondaryLabelColor
        excludedAppsLabel.frame = NSRect(x: excludeButtonX + excludeButtonWidth + 16, y: 24, width: 150, height: 22)
        bottomCard.addSubview(excludedAppsLabel)

        return view
    }

    private class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private func menuView() -> NSView {
        let contentHeight = contentContainer.bounds.height
        let contentWidth = contentContainer.bounds.width
        let innerView = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))

        var y = contentHeight - 64

        func checkbox(_ b: NSButton, indent: Bool = false, width: CGFloat = 470) {
            b.frame = NSRect(x: indent ? 130 : 103, y: y, width: width, height: 26)
            b.target = self
            b.action = #selector(settingChanged(_:))
            innerView.addSubview(b)
        }

        addFieldRow(t(en: "Number of items placed inline:", zh: "直接显示的条目数量："), field: previewHistoryField, suffix: t(en: "items", zh: "条"), to: innerView, y: y)
        y -= 40
        addFieldRow(t(en: "Number of items inside first folder:", zh: "第一个文件夹中的条目数量："), field: pageSizeField, suffix: t(en: "items", zh: "条"), to: innerView, y: y)
        y -= 40
        addFieldRow(t(en: "Number of items inside second folder:", zh: "第二个文件夹中的条目数量："), field: secondFolderSizeField, suffix: t(en: "items", zh: "条"), to: innerView, y: y)
        y -= 40
        addFieldRow(t(en: "Number of characters in the menu:", zh: "菜单中显示的字符数："), field: menuPreviewLengthField, suffix: t(en: "chars", zh: "字符"), to: innerView, y: y)

        y -= 42
        checkbox(markNumbersButton);                 y -= 30
        checkbox(numberFromZeroButton, indent: true); y -= 32
        checkbox(numericKeyButton);                  y -= 32
        checkbox(showLabelsButton);                  y -= 32
        checkbox(addClearItemButton);                y -= 30
        checkbox(confirmClearButton, indent: true);  y -= 32
        checkbox(showToolTipButton);                 y -= 38

        addFieldRow(t(en: "Max length of tool tip string:", zh: "工具提示最大长度："), field: maxToolTipField, suffix: t(en: "chars", zh: "字符"), to: innerView, y: y)
        y -= 44

        checkbox(changeFontSizeButton); y -= 30
        fitFontRadio.frame = NSRect(x: 145, y: y, width: 220, height: 22)
        fitFontRadio.target = self; fitFontRadio.action = #selector(fontModeChanged(_:))
        innerView.addSubview(fitFontRadio)
        y -= 30
        selectFontRadio.frame = NSRect(x: 145, y: y, width: 92, height: 22)
        selectFontRadio.target = self; selectFontRadio.action = #selector(fontModeChanged(_:))
        innerView.addSubview(selectFontRadio)
        fontSizePopup.frame = NSRect(x: 314, y: y - 4, width: 122, height: standardControlHeight)
        fontSizePopup.target = self; fontSizePopup.action = #selector(settingChanged(_:))
        innerView.addSubview(fontSizePopup)
        let ptLabel = NSTextField(labelWithString: t(en: "pt", zh: "磅"))
        ptLabel.font = secondaryFont
        ptLabel.frame = NSRect(x: 448, y: y, width: 30, height: 22)
        innerView.addSubview(ptLabel)
        y -= 44

        checkbox(showImagesInMenuButton); y -= 36
        let wLabel = NSTextField(labelWithString: t(en: "Width:", zh: "宽度："))
        wLabel.font = secondaryFont
        wLabel.frame = NSRect(x: 139, y: y, width: 88, height: 22)
        innerView.addSubview(wLabel)
        imageWidthField.frame = NSRect(x: 236, y: y - 4, width: 92, height: standardControlHeight)
        imageWidthField.alignment = .right
        imageWidthField.target = self; imageWidthField.action = #selector(settingChanged(_:))
        innerView.addSubview(imageWidthField)
        let wpx = NSTextField(labelWithString: t(en: "pixel", zh: "像素"))
        wpx.font = secondaryFont
        wpx.frame = NSRect(x: 335, y: y, width: 64, height: 22)
        innerView.addSubview(wpx)
        let hLabel = NSTextField(labelWithString: t(en: "Height:", zh: "高度："))
        hLabel.font = secondaryFont
        hLabel.frame = NSRect(x: 430, y: y, width: 88, height: 22)
        innerView.addSubview(hLabel)
        imageHeightField.frame = NSRect(x: 537, y: y - 4, width: 92, height: standardControlHeight)
        imageHeightField.alignment = .right
        imageHeightField.target = self; imageHeightField.action = #selector(settingChanged(_:))
        innerView.addSubview(imageHeightField)
        let hpx = NSTextField(labelWithString: t(en: "pixel", zh: "像素"))
        hpx.font = secondaryFont
        hpx.frame = NSRect(x: 636, y: y, width: 64, height: 22)
        innerView.addSubview(hpx)

        maxToolTipField.target = self; maxToolTipField.action = #selector(settingChanged(_:))

        return innerView
    }

    private func typeView() -> NSView {
        let view = NSView()
        let segWidth: CGFloat = 240
        let seg = NSSegmentedControl(labels: [t(en: "Type", zh: "类型"), t(en: "Icon", zh: "图标")], trackingMode: .selectOne,
                                     target: self, action: #selector(typeSegmentChanged(_:)))
        seg.frame = NSRect(x: (contentContainer.bounds.width - segWidth) / 2,
                           y: contentContainer.bounds.height - 56, width: segWidth, height: 30)
        seg.font = bodyFont
        seg.selectedSegment = selectedTypeSegment
        view.addSubview(seg)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentContainer.bounds.width,
                                             height: contentContainer.bounds.height - 80))
        container.autoresizingMask = [.width, .height]
        view.addSubview(container)
        typeSubContainer = container
        showTypeSubview(index: selectedTypeSegment)
        return view
    }

    private weak var typeSubContainer: NSView?

    @objc private func typeSegmentChanged(_ sender: NSSegmentedControl) {
        selectedTypeSegment = sender.selectedSegment
        showTypeSubview(index: sender.selectedSegment)
    }

    private func showTypeSubview(index: Int) {
        guard let container = typeSubContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let sub = index == 1 ? typeIconView() : typeCaptureView()
        sub.frame = container.bounds
        sub.autoresizingMask = [.width, .height]
        container.addSubview(sub)
    }

    private func typeCaptureView() -> NSView {
        let view = NSView()
        let h = typeSubContainer?.bounds.height ?? (contentContainer.bounds.height - 80)
        _ = addCard(to: view, frame: NSRect(x: contentLeft, y: h - 226, width: contentWidth, height: 160))
        let stack = verticalStack()
        stack.frame = NSRect(x: contentLeft + 36, y: h - 198, width: 520, height: 110)
        [captureTextButton, captureImagesButton, captureFilesButton].forEach {
            $0.target = self
            $0.action = #selector(settingChanged(_:))
            stack.addArrangedSubview($0)
        }
        view.addSubview(stack)
        let hint = NSTextField(labelWithString: t(en: "Only enabled clipboard types are recorded and shown in the menu.",
                                                  zh: "只记录并显示已启用的剪贴板类型。"))
        hint.font = secondaryFont
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: contentLeft, y: h - 258, width: contentWidth, height: 22)
        view.addSubview(hint)
        return view
    }

    private func typeIconView() -> NSView {
        let view = NSView()
        let h = typeSubContainer?.bounds.height ?? (contentContainer.bounds.height - 80)
        _ = addCard(to: view, frame: NSRect(x: contentLeft, y: 38, width: contentWidth, height: h - 88))

        var y = h - 92

        showIconButton.frame = NSRect(x: contentLeft + 36, y: y, width: 320, height: 26)
        showIconButton.target = self
        showIconButton.action = #selector(settingChanged(_:))
        view.addSubview(showIconButton)
        y -= 48

        let sizeLabel = NSTextField(labelWithString: t(en: "Icon size:", zh: "图标大小："))
        sizeLabel.font = bodyFont
        sizeLabel.alignment = .right
        sizeLabel.frame = NSRect(x: contentLeft + 120, y: y + 4, width: 100, height: 22)
        view.addSubview(sizeLabel)
        iconSizeField.frame = NSRect(x: contentLeft + 270, y: y, width: 118, height: standardControlHeight)
        iconSizeField.alignment = .right
        iconSizeField.target = self
        iconSizeField.action = #selector(settingChanged(_:))
        view.addSubview(iconSizeField)
        let pixel = NSTextField(labelWithString: t(en: "pixel", zh: "像素"))
        pixel.font = bodyFont
        pixel.frame = NSRect(x: contentLeft + 406, y: y + 4, width: 60, height: 22)
        view.addSubview(pixel)
        y -= 46

        let iconLabel = NSTextField(labelWithString: t(en: "Icon", zh: "图标"))
        iconLabel.font = subsectionTitleFont
        iconLabel.frame = NSRect(x: contentLeft + 36, y: y, width: 90, height: 24)
        view.addSubview(iconLabel)
        y -= 12

        let rowCount = settings.iconTypeSettings.count
        let rowH: CGFloat = 36
        let cardH = CGFloat(rowCount) * rowH + 24
        let card = addCard(to: view, frame: NSRect(x: contentLeft + 36, y: y - cardH, width: contentWidth - 72, height: cardH))

        iconModePopups.removeAll()
        iconCodeFields.removeAll()
        var ry = cardH - 40
        for setting in settings.iconTypeSettings {
            let lbl = NSTextField(labelWithString: setting.label + ":")
            lbl.font = bodyFont
            lbl.frame = NSRect(x: 52, y: ry + 4, width: 150, height: 22)
            card.addSubview(lbl)

            let popup = NSPopUpButton(frame: NSRect(x: 300, y: ry, width: 240, height: standardControlHeight))
            stylePopup(popup)
            popup.addItems(withTitles: ["File type code", "File extension"].map(optionTitle))
            popup.selectItem(withTitle: optionTitle(setting.mode))
            popup.target = self
            popup.action = #selector(settingChanged(_:))
            card.addSubview(popup)
            iconModePopups.append(popup)

            let field = NSTextField(frame: NSRect(x: 560, y: ry, width: 92, height: standardControlHeight))
            styleField(field)
            field.stringValue = setting.code
            field.alignment = .center
            field.target = self
            field.action = #selector(settingChanged(_:))
            card.addSubview(field)
            iconCodeFields.append(field)

            ry -= rowH
        }
        return view
    }

    private func actionView() -> NSView {
        let contentHeight = contentContainer.bounds.height
        let view = NSView(frame: NSRect(x: 0, y: 0, width: contentContainer.bounds.width, height: contentHeight))

        let leftX = contentLeft
        let top = contentHeight - 64
        addSectionTitle(t(en: "Action", zh: "操作"), to: view, x: leftX, y: top)

        enableActionsButton.frame = NSRect(x: leftX, y: top - 44, width: 280, height: 24)
        enableActionsButton.target = self
        enableActionsButton.action = #selector(settingChanged(_:))
        view.addSubview(enableActionsButton)

        invokeSingleActionButton.frame = NSRect(x: leftX, y: top - 78, width: 520, height: 24)
        invokeSingleActionButton.target = self
        invokeSingleActionButton.action = #selector(settingChanged(_:))
        view.addSubview(invokeSingleActionButton)

        // Action list — positioned directly below the two checkboxes
        let menuTitle = NSTextField(labelWithString: t(en: "Action Menu", zh: "快捷操作列表"))
        menuTitle.font = subsectionTitleFont
        menuTitle.frame = NSRect(x: leftX, y: top - 120, width: 220, height: 22)
        view.addSubview(menuTitle)

        let actions = TextAction.allActions(customRules: settings.customTextRules)
        let actionListHeight = max(CGFloat(actions.count) * 24 + 32, 220)
        let actionListTop = top - 144
        let actionList = addCard(to: view, frame: NSRect(x: leftX, y: actionListTop - actionListHeight, width: contentWidth, height: actionListHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 28, y: 22, width: actionList.frame.width - 56, height: actionList.frame.height - 44)
        stack.autoresizingMask = [.width, .height]

        for action in actions {
            let label = NSTextField(labelWithString: optionTitle(action.title))
            label.font = bodyFont
            label.frame.size.height = 22
            stack.addArrangedSubview(label)
        }

        actionList.addSubview(stack)

        return view
    }

    private func shortcutsView() -> NSView {
        let view = NSView()
        let label = NSTextField(labelWithString: t(en: "Shortcuts", zh: "快捷键"))
        label.font = sectionTitleFont
        label.frame = NSRect(x: contentLeft, y: contentContainer.bounds.height - 64, width: 200, height: 24)
        view.addSubview(label)
        hotKeyButton.frame = NSRect(x: contentLeft, y: contentContainer.bounds.height - 114, width: 560, height: 24)
        view.addSubview(hotKeyButton)
        let hint = NSTextField(labelWithString: t(en: "Default: Control + Option + Command + V", zh: "默认：Control + Option + Command + V"))
        hint.font = secondaryFont
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: contentLeft, y: contentContainer.bounds.height - 146, width: 420, height: 20)
        view.addSubview(hint)
        return view
    }

    private func updatesView() -> NSView {
        let view = NSView()
        let label = NSTextField(labelWithString: t(en: "Updates", zh: "更新"))
        label.font = sectionTitleFont
        label.frame = NSRect(x: contentLeft, y: contentContainer.bounds.height - 64, width: 200, height: 24)
        view.addSubview(label)
        let note = NSTextField(labelWithString: t(en: "This rebuilt version does not include automatic update integration by default.",
                                                  zh: "此重构版本默认不包含自动更新集成。"))
        note.font = secondaryFont
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: contentLeft, y: contentContainer.bounds.height - 114, width: 560, height: 22)
        view.addSubview(note)
        return view
    }

    private func snippetsView() -> NSView {
        let view = NSView()
        let top = contentContainer.bounds.height
        let winW = contentContainer.bounds.width   // 920

        // Symmetric left/right margins matching the visual feel of other tabs
        let margin: CGFloat = 40
        let gap: CGFloat = 12
        let available = winW - margin * 2          // 840

        // Proportions: folder(narrow) : title(medium) : content(wide) ≈ 1 : 1.3 : 2
        // folder ≈ 190, title ≈ 248, content ≈ 390, gaps = 24 → total 852... trim:
        let folderW:  CGFloat = 185
        let titleW:   CGFloat = 245
        let contentW: CGFloat = available - folderW - titleW - gap * 2  // 398
        let folderX  = margin
        let titleX   = folderX + folderW + gap
        let contentX = titleX + titleW + gap

        let positionLabel = NSTextField(labelWithString: t(en: "The position to show snippets in ClipMenu:",
                                                           zh: "片段在 ClipMenu 中的显示位置："))
        positionLabel.font = bodyFont
        positionLabel.frame = NSRect(x: margin, y: top - 70, width: 320, height: 24)
        view.addSubview(positionLabel)

        let popupX = margin + 326
        let popupW = winW - margin - popupX
        snippetsPositionPopup.frame = NSRect(x: popupX, y: top - 76, width: max(180, popupW), height: standardControlHeight)
        snippetsPositionPopup.target = self
        snippetsPositionPopup.action = #selector(settingChanged(_:))
        view.addSubview(snippetsPositionPopup)

        let separator = NSBox(frame: NSRect(x: 0, y: top - 112, width: contentContainer.bounds.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        view.addSubview(separator)

        let headerY = top - 150
        [headerLabel(t(en: "Folder:", zh: "文件夹："), x: folderX, y: headerY),
         headerLabel(t(en: "Title:", zh: "标题："), x: titleX, y: headerY),
         headerLabel(t(en: "Content:", zh: "内容："), x: contentX, y: headerY)].forEach { view.addSubview($0) }

        let tableY: CGFloat = 86
        let tableHeight = top - 178 - tableY
        let folderScroll = scrollView(x: folderX, y: tableY, width: folderW, height: tableHeight, table: folderTable)
        let titleScroll = scrollView(x: titleX, y: tableY, width: titleW, height: tableHeight, table: titleTable)
        let contentScroll = NSScrollView(frame: NSRect(x: contentX, y: tableY, width: contentW, height: tableHeight))
        contentScroll.hasVerticalScroller = true
        contentScroll.borderType = .lineBorder
        contentScroll.drawsBackground = true
        contentScroll.backgroundColor = .textBackgroundColor
        contentTextView.isEditable = true
        contentTextView.isRichText = false
        contentTextView.importsGraphics = false
        contentTextView.allowsUndo = true
        contentTextView.delegate = self
        contentTextView.font = bodyFont
        contentTextView.textContainerInset = NSSize(width: 10, height: 10)
        contentScroll.documentView = contentTextView
        [folderScroll, titleScroll, contentScroll].forEach { view.addSubview($0) }

        configureSnippetTables()

        let bottomY: CGFloat = 40
        let folderAdd = squareButton("+", action: #selector(addFolderAction))
        let folderDelete = squareButton("−", action: #selector(deleteFolderAction))
        folderAdd.frame = NSRect(x: folderX, y: bottomY, width: 46, height: 34)
        folderDelete.frame = NSRect(x: folderX + 52, y: bottomY, width: 46, height: 34)
        view.addSubview(folderAdd); view.addSubview(folderDelete)

        // Gear (import/export/reset) — kept within folderW, away from titleX
        let gearX = folderX + 104
        let gear = NSPopUpButton(frame: NSRect(x: gearX, y: bottomY, width: 66, height: 34), pullsDown: true)
        gear.font = bodyFont
        gear.controlSize = .regular
        gear.addItem(withTitle: "⚙")
        gear.addItem(withTitle: t(en: "Import Snippets…", zh: "导入片段…"))
        gear.addItem(withTitle: t(en: "Export Snippets…", zh: "导出片段…"))
        gear.addItem(withTitle: t(en: "Reset to Default Snippets", zh: "重置为默认片段"))
        gear.target = self
        gear.action = #selector(snippetGearAction(_:))
        view.addSubview(gear)

        let snippetAdd = squareButton("+", action: #selector(addSnippetAction))
        let snippetDelete = squareButton("−", action: #selector(deleteSnippetAction))
        snippetAdd.frame = NSRect(x: titleX, y: bottomY, width: 46, height: 34)
        snippetDelete.frame = NSRect(x: titleX + 52, y: bottomY, width: 46, height: 34)
        view.addSubview(snippetAdd); view.addSubview(snippetDelete)

        // Search field removed — not useful in current implementation

        reloadSnippetTables()
        return view
    }

    private func headerLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = subsectionTitleFont
        label.frame = NSRect(x: x, y: y, width: 240, height: 24)
        return label
    }

    private func squareButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: 17, weight: .medium)
        button.controlSize = .regular
        return button
    }

    private func scrollView(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: x, y: y, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        table.frame = scroll.bounds
        table.tableColumns.first?.width = width - 2
        scroll.documentView = table
        return scroll
    }

    private func configureSnippetTables() {
        if folderTable.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
            column.width = max(300, folderTable.bounds.width - 2)
            folderTable.addTableColumn(column)
            folderTable.headerView = nil
            folderTable.rowHeight = 32
            folderTable.delegate = self
            folderTable.dataSource = self
            folderTable.allowsEmptySelection = false
            folderTable.allowsMultipleSelection = false
            folderTable.registerForDraggedTypes([Self.snippetDragType])
            folderTable.setDraggingSourceOperationMask(.move, forLocal: true)
            folderTable.renameHandler = { [weak self] tableView, row in
                self?.beginSnippetRename(in: tableView, row: row)
            }
        }
        if titleTable.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
            column.width = max(300, titleTable.bounds.width - 2)
            titleTable.addTableColumn(column)
            titleTable.headerView = nil
            titleTable.rowHeight = 32
            titleTable.delegate = self
            titleTable.dataSource = self
            titleTable.allowsEmptySelection = false
            titleTable.allowsMultipleSelection = true
            titleTable.registerForDraggedTypes([Self.snippetDragType])
            titleTable.setDraggingSourceOperationMask(.move, forLocal: true)
            titleTable.renameHandler = { [weak self] tableView, row in
                self?.beginSnippetRename(in: tableView, row: row)
            }
        }
    }

    private func reloadSnippetTables() {
        isReloadingSnippetTables = true
        defer { isReloadingSnippetTables = false }

        if snippets.isEmpty { selectedFolderIndex = nil; selectedSnippetIndex = nil }
        else if selectedFolderIndex == nil { selectedFolderIndex = 0 }
        if let folderIndex = selectedFolderIndex, folderIndex >= snippets.count { selectedFolderIndex = snippets.count - 1 }

        folderTable.reloadData()
        if let folderIndex = selectedFolderIndex {
            folderTable.selectRowIndexes(IndexSet(integer: folderIndex + 1), byExtendingSelection: false)
            folderTable.scrollRowToVisible(folderIndex + 1)
        }

        titleTable.reloadData()
        let children = currentChildren()
        if children.isEmpty { selectedSnippetIndex = nil }
        else if selectedSnippetIndex == nil { selectedSnippetIndex = 0 }
        if let snippetIndex = selectedSnippetIndex, snippetIndex >= children.count { selectedSnippetIndex = children.count - 1 }
        if let snippetIndex = selectedSnippetIndex {
            titleTable.selectRowIndexes(IndexSet(integer: snippetIndex + 1), byExtendingSelection: false)
            titleTable.scrollRowToVisible(snippetIndex + 1)
        }

        if let snippetIndex = selectedSnippetIndex, snippetIndex < currentChildren().count { contentTextView.string = currentChildren()[snippetIndex].content }
        else { contentTextView.string = "" }
    }

    private func beginSnippetRename(in tableView: NSTableView, row: Int) {
        guard row > 0 else { return }
        if tableView == folderTable {
            guard snippets.indices.contains(row - 1) else { return }
            selectedFolderIndex = row - 1
            if folderTable.selectedRow != row {
                folderTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if tableView == titleTable {
            guard let folderIndex = selectedFolderIndex,
                  snippets.indices.contains(folderIndex),
                  snippets[folderIndex].children.indices.contains(row - 1) else { return }
            selectedSnippetIndex = row - 1
            if !titleTable.selectedRowIndexes.contains(row) {
                titleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            return
        }
        tableView.window?.makeFirstResponder(tableView)
        tableView.editColumn(0, row: row, with: nil, select: true)
    }

    private func currentChildren() -> [SnippetNode] {
        guard let folderIndex = selectedFolderIndex, folderIndex < snippets.count else { return [] }
        return snippets[folderIndex].children
    }

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func addSectionTitle(_ text: String, to view: NSView, x: CGFloat, y: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = sectionTitleFont
        label.frame = NSRect(x: x, y: y, width: 260, height: 26)
        view.addSubview(label)
    }

    private func addFieldRow(_ label: String, field: NSTextField, suffix: String, to view: NSView, y: CGFloat) {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = bodyFont
        labelView.frame = NSRect(x: 102, y: y, width: 520, height: 24)
        styleField(field)
        view.addSubview(labelView)

        field.frame = NSRect(x: 645, y: y - 4, width: 92, height: standardControlHeight)
        field.alignment = .right
        field.target = self
        field.action = #selector(settingChanged(_:))
        view.addSubview(field)

        let suffixLabel = NSTextField(labelWithString: suffix)
        suffixLabel.font = bodyFont
        suffixLabel.frame = NSRect(x: 746, y: y, width: 80, height: 24)
        view.addSubview(suffixLabel)
    }

    private func row(label: String, field: NSTextField) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = bodyFont
        labelView.alignment = .right
        labelView.frame.size.width = 180
        styleField(field)
        field.frame.size.width = 80
        let row = NSStackView(views: [labelView, field])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func configurePopups() {
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: [optionTitle("Chinese"), optionTitle("English")])
        sortOrderPopup.removeAllItems()
        sortOrderPopup.addItems(withTitles: ["Date Created", "Last Used"].map(optionTitle))
        autosavePopup.removeAllItems()
        autosavePopup.addItems(withTitles: ["Never", "Every minute", "Every 5 minutes", "Every 10 minutes", "Every 30 minutes", "Every hour", "Every 3 hours", "Every 6 hours", "Every 12 hours", "Every day"].map(optionTitle))
        exportAsPopup.removeAllItems()
        exportAsPopup.addItems(withTitles: ["Single file", "Multiple files"].map(optionTitle))
        separatorPopup.removeAllItems()
        separatorPopup.addItems(withTitles: ["LF", "CR+LF", "CR", "Tab", "Space", "None"].map(optionTitle))
        statusBarIconPopup.removeAllItems()
        statusBarIconPopup.addItems(withTitles: ["Default", "Clipboard", "Scissors", "None"].map(optionTitle))
        snippetsPositionPopup.removeAllItems()
        snippetsPositionPopup.addItems(withTitles: ["None", "Below the clipboard history", "Above the clipboard history"].map(optionTitle))
        fontSizePopup.removeAllItems()
        fontSizePopup.addItems(withTitles: ["10", "11", "12", "13", "14", "16", "18", "20", "24"])
    }

    private func loadValues() {
        applyLocalizedControlTitles()
        configurePopups()
        [maxHistoryField, previewHistoryField, pageSizeField, secondFolderSizeField, menuPreviewLengthField,
         imageWidthField, imageHeightField, maxToolTipField, iconSizeField].forEach { styleField($0) }
        (customRuleNameFields + customRuleFindFields + customRuleReplaceFields).forEach { styleField($0) }
        [languagePopup, sortOrderPopup, autosavePopup, exportAsPopup, separatorPopup, statusBarIconPopup,
         snippetsPositionPopup, fontSizePopup].forEach { stylePopup($0) }
        [showImagesInMenuButton, captureTextButton, captureImagesButton, captureFilesButton, pasteAfterButton,
         hotKeyButton, launchOnLoginButton, saveHistoryOnQuitButton, confirmClearButton, enableActionsButton,
         invokeSingleActionButton, markNumbersButton, numberFromZeroButton, numericKeyButton, showLabelsButton,
         addClearItemButton, showToolTipButton, changeFontSizeButton, fitFontRadio, selectFontRadio,
         showIconButton].forEach { styleCheckbox($0) }
        languagePopup.selectItem(withTitle: optionTitle(settings.language))
        maxHistoryField.stringValue = String(settings.maxHistory)
        previewHistoryField.stringValue = String(settings.previewHistoryCount)
        pageSizeField.stringValue = String(settings.pageSize)
        secondFolderSizeField.stringValue = String(settings.secondFolderSize)
        menuPreviewLengthField.stringValue = String(settings.menuPreviewLength)
        showImagesInMenuButton.state = settings.showImagesInMenu ? .on : .off
        imageWidthField.stringValue = String(settings.imagePreviewWidth)
        imageHeightField.stringValue = String(settings.imagePreviewHeight)
        captureTextButton.state = settings.captureText ? .on : .off
        captureImagesButton.state = settings.captureImages ? .on : .off
        captureFilesButton.state = settings.captureFiles ? .on : .off
        pasteAfterButton.state = settings.pasteAfterSelection ? .on : .off
        hotKeyButton.state = settings.hotKeyEnabled ? .on : .off
        launchOnLoginButton.state = settings.launchOnLogin ? .on : .off
        saveHistoryOnQuitButton.state = settings.saveHistoryOnQuit ? .on : .off
        confirmClearButton.state = settings.confirmBeforeClearHistory ? .on : .off
        enableActionsButton.state = settings.enableActions ? .on : .off
        invokeSingleActionButton.state = settings.invokeSingleActionImmediately ? .on : .off
        markNumbersButton.state = settings.markItemsWithNumbers ? .on : .off
        numberFromZeroButton.state = settings.numberItemsFromZero ? .on : .off
        numericKeyButton.state = settings.addNumericKeyEquivalents ? .on : .off
        showLabelsButton.state = settings.showLabels ? .on : .off
        addClearItemButton.state = settings.addClearHistoryItem ? .on : .off
        showToolTipButton.state = settings.showToolTip ? .on : .off
        maxToolTipField.stringValue = String(settings.maxToolTipLength)
        changeFontSizeButton.state = settings.changeFontSize ? .on : .off
        fitFontRadio.state = settings.fontSizeModeValue == .fit ? .on : .off
        selectFontRadio.state = settings.fontSizeModeValue == .select ? .on : .off
        fontSizePopup.selectItem(withTitle: String(settings.selectedFontSize))
        showIconButton.state = settings.showIconInMenu ? .on : .off
        iconSizeField.stringValue = String(settings.iconSize)
        sortOrderPopup.selectItem(withTitle: optionTitle(settings.sortHistoryOrderValue.rawValue))
        autosavePopup.selectItem(withTitle: optionTitle(settings.autosaveHistoryInterval))
        exportAsPopup.selectItem(withTitle: optionTitle(settings.exportHistoryFormatValue.rawValue))
        separatorPopup.selectItem(withTitle: optionTitle(settings.exportSeparatorValue.rawValue))
        let statusStyle: String
        switch settings.appIconStyle {
        case "Backup 1": statusStyle = "Clipboard"
        case "Backup 2": statusStyle = "Scissors"
        default: statusStyle = settings.appIconStyle
        }
        statusBarIconPopup.selectItem(withTitle: optionTitle(statusStyle))
        let snippetPosition = settings.snippetsPositionValue == .none ? "None" : settings.snippetsPositionValue.rawValue
        snippetsPositionPopup.selectItem(withTitle: optionTitle(snippetPosition))
        intervalSlider.doubleValue = settings.observeIntervalSeconds
        updateIntervalLabel()
        updateExcludedAppsLabel()
    }

    private func applyLocalizedControlTitles() {
        showImagesInMenuButton.title = t(en: "Show Image", zh: "显示图片")
        captureTextButton.title = t(en: "Capture text", zh: "记录文本")
        captureImagesButton.title = t(en: "Capture images", zh: "记录图片")
        captureFilesButton.title = t(en: "Capture file URLs", zh: "记录文件 URL")
        pasteAfterButton.title = t(en: "Input \"⌘ + V\" after menu item selection", zh: "选择菜单项后输入“⌘ + V”")
        hotKeyButton.title = t(en: "Enable global menu shortcut: Control + Option + Command + V", zh: "启用全局菜单快捷键：Control + Option + Command + V")
        launchOnLoginButton.title = t(en: "Launch on Login", zh: "登录时启动")
        saveHistoryOnQuitButton.title = t(en: "Save clipboard history on quit", zh: "退出时保存剪贴板历史记录")
        confirmClearButton.title = t(en: "Show alert panel before clear history", zh: "清除历史记录前显示确认提示")
        enableActionsButton.title = t(en: "Enable Action", zh: "启用操作")
        invokeSingleActionButton.title = t(en: "Invoke an action immediately if only one action was registered", zh: "只有一个操作时立即执行")
        markNumbersButton.title = t(en: "Mark menu items with numbers", zh: "为菜单项显示编号")
        numberFromZeroButton.title = t(en: "Menu items' title starts with 0", zh: "菜单项编号从 0 开始")
        numericKeyButton.title = t(en: "Add key equivalents to numeric keys", zh: "添加数字快捷键")
        showLabelsButton.title = t(en: "Show labels to indicate item types", zh: "显示类型标签")
        addClearItemButton.title = t(en: "Add a menu item to clear clipboard history", zh: "添加清除剪贴板历史记录菜单项")
        showToolTipButton.title = t(en: "Show tool tip on a menu item", zh: "在菜单项上显示工具提示")
        changeFontSizeButton.title = t(en: "Change font size in the menu", zh: "更改菜单字体大小")
        fitFontRadio.title = t(en: "Fit to the icon size", zh: "适配图标大小")
        selectFontRadio.title = t(en: "Select:", zh: "选择：")
        showIconButton.title = t(en: "Show Icon in the Menu", zh: "在菜单中显示图标")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func close() {
        applyAndNotify()
        super.close()
    }

    private func applyCurrentTextEdit() {
        guard let folderIndex = selectedFolderIndex, folderIndex < snippets.count,
              let snippetIndex = selectedSnippetIndex, snippetIndex < snippets[folderIndex].children.count else { return }
        snippets[folderIndex].children[snippetIndex].content = contentTextView.string
    }

    private func applyAndNotify() {
        applyCurrentTextEdit()
        settings.language = rawOption(languagePopup.titleOfSelectedItem ?? settings.language)
        settings.maxHistory = max(1, maxHistoryField.integerValue)
        settings.previewHistoryCount = max(0, min(settings.maxHistory, previewHistoryField.integerValue == 0 ? 0 : previewHistoryField.integerValue))
        settings.pageSize = max(1, pageSizeField.integerValue)
        settings.secondFolderSize = max(0, secondFolderSizeField.integerValue)
        settings.menuPreviewLength = max(8, menuPreviewLengthField.integerValue == 0 ? settings.menuPreviewLength : menuPreviewLengthField.integerValue)
        settings.showImagesInMenu = showImagesInMenuButton.state == .on
        settings.imagePreviewWidth = max(16, imageWidthField.integerValue == 0 ? settings.imagePreviewWidth : imageWidthField.integerValue)
        settings.imagePreviewHeight = max(16, imageHeightField.integerValue == 0 ? settings.imagePreviewHeight : imageHeightField.integerValue)
        settings.captureText = captureTextButton.state == .on
        settings.captureImages = captureImagesButton.state == .on
        settings.captureFiles = captureFilesButton.state == .on
        settings.pasteAfterSelection = pasteAfterButton.state == .on
        settings.hotKeyEnabled = hotKeyButton.state == .on
        settings.launchOnLogin = launchOnLoginButton.state == .on
        settings.saveHistoryOnQuit = saveHistoryOnQuitButton.state == .on
        settings.confirmBeforeClearHistory = confirmClearButton.state == .on
        settings.enableActions = enableActionsButton.state == .on
        settings.invokeSingleActionImmediately = invokeSingleActionButton.state == .on
        settings.markItemsWithNumbers = markNumbersButton.state == .on
        settings.numberItemsFromZero = numberFromZeroButton.state == .on
        settings.addNumericKeyEquivalents = numericKeyButton.state == .on
        settings.showLabels = showLabelsButton.state == .on
        settings.addClearHistoryItem = addClearItemButton.state == .on
        settings.showToolTip = showToolTipButton.state == .on
        settings.maxToolTipLength = max(10, maxToolTipField.integerValue == 0 ? settings.maxToolTipLength : maxToolTipField.integerValue)
        settings.changeFontSize = changeFontSizeButton.state == .on
        settings.fontSizeModeValue = selectFontRadio.state == .on ? .select : .fit
        if let sizeTitle = fontSizePopup.titleOfSelectedItem, let size = Int(sizeTitle) { settings.selectedFontSize = size }
        settings.showIconInMenu = showIconButton.state == .on
        settings.iconSize = max(8, iconSizeField.integerValue == 0 ? settings.iconSize : iconSizeField.integerValue)
        if iconModePopups.count == settings.iconTypeSettings.count, iconCodeFields.count == settings.iconTypeSettings.count {
            for i in settings.iconTypeSettings.indices {
                settings.iconTypeSettings[i].mode = rawOption(iconModePopups[i].titleOfSelectedItem ?? settings.iconTypeSettings[i].mode)
                settings.iconTypeSettings[i].code = iconCodeFields[i].stringValue
            }
        }
        settings.sortHistoryOrderValue = AppSettings.SortHistoryOrder(rawValue: rawOption(sortOrderPopup.titleOfSelectedItem ?? settings.sortHistoryOrder)) ?? .lastUsed
        settings.autosaveHistoryInterval = rawOption(autosavePopup.titleOfSelectedItem ?? settings.autosaveHistoryInterval)
        settings.exportHistoryFormatValue = AppSettings.ExportHistoryFormat(rawValue: rawOption(exportAsPopup.titleOfSelectedItem ?? settings.exportHistoryAs)) ?? .singleFile
        settings.exportSeparatorValue = AppSettings.ExportSeparator(rawValue: rawOption(separatorPopup.titleOfSelectedItem ?? settings.exportSeparator)) ?? .lf
        settings.appIconStyle = rawOption(statusBarIconPopup.titleOfSelectedItem ?? settings.appIconStyle)
        settings.observeIntervalSeconds = intervalSlider.doubleValue
        let snippetsRaw = rawOption(snippetsPositionPopup.titleOfSelectedItem ?? settings.snippetsPosition)
        settings.snippetsPositionValue = snippetsRaw == "None" ? .none : (AppSettings.SnippetsPosition(rawValue: snippetsRaw) ?? .belowHistory)
        applyLaunchOnLoginSetting()
        Storage.shared.saveSettings(settings)
        Storage.shared.saveSnippets(snippets)
        delegate?.preferencesDidChange(settings: settings, snippets: snippets)
    }

    private func applyLaunchOnLoginSetting() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if settings.launchOnLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showAlert(message: t(en: "Launch on Login", zh: "登录时启动"), informativeText: error.localizedDescription)
        }
    }

    @objc private func intervalSliderChanged(_ sender: NSSlider) {
        updateIntervalLabel()
        applyAndNotify()
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        settings.language = rawOption(sender.titleOfSelectedItem ?? settings.language)
        Storage.shared.saveSettings(settings)
        refreshCurrentPane()
        applyAndNotify()
    }

    @objc private func fontModeChanged(_ sender: NSButton) {
        settings.fontSizeModeValue = (sender == selectFontRadio) ? .select : .fit
        applyAndNotify()
    }

    private func updateIntervalLabel() {
        intervalValueLabel.stringValue = settings.text(en: String(format: "%.1f sec.", intervalSlider.doubleValue),
                                                       zh: String(format: "%.1f 秒", intervalSlider.doubleValue))
    }

    private func updateExcludedAppsLabel() {
        if settings.excludedApplications.isEmpty {
            excludedAppsLabel.stringValue = t(en: "No excluded applications", zh: "没有排除的应用")
        } else {
            excludedAppsLabel.stringValue = t(en: "\(settings.excludedApplications.count) excluded",
                                              zh: "已排除 \(settings.excludedApplications.count) 个")
        }
    }

    @objc private func settingChanged(_ sender: Any) {
        applyAndNotify()
        updateExcludedAppsLabel()
    }

    @objc private func exportHistoryAction() {
        switch settings.exportHistoryFormatValue {
        case .singleFile:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "clipboard-history.txt"
            panel.beginSheetModal(for: window!) { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try self.exportHistorySingleFile(to: url)
                } catch {
                    self.showAlert(message: self.t(en: "Export Failed", zh: "导出失败"), informativeText: error.localizedDescription)
                }
            }
        case .multipleFiles:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = t(en: "Export", zh: "导出")
            panel.beginSheetModal(for: window!) { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try self.exportHistoryMultipleFiles(to: url)
                } catch {
                    self.showAlert(message: self.t(en: "Export Failed", zh: "导出失败"), informativeText: error.localizedDescription)
                }
            }
        }
    }

    @objc private func importHistoryAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "txt")!]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let imported: [ClipItem]
                if url.pathExtension.lowercased() == "json" {
                    imported = try JSONDecoder().decode([ClipItem].self, from: data)
                } else {
                    let text = String(decoding: data, as: UTF8.self)
                    imported = text
                        .components(separatedBy: self.settings.exportSeparatorValue.value.isEmpty ? "\n" : self.settings.exportSeparatorValue.value)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .map { ClipItem(type: .text, text: $0) }
                }
                Storage.shared.saveHistoryItems(imported)
                HistoryStore.shared.loadFromDisk()   // reload so in-memory state reflects import
                self.showAlert(message: self.t(en: "Import Complete", zh: "导入完成"),
                               informativeText: self.t(en: "\(imported.count) history items imported.",
                                                       zh: "已导入 \(imported.count) 条历史记录。"))
                self.applyAndNotify()
            } catch {
                self.showAlert(message: self.t(en: "Import Failed", zh: "导入失败"), informativeText: error.localizedDescription)
            }
        }
    }

    private func exportHistorySingleFile(to url: URL) throws {
        let separator = settings.exportSeparatorValue.value
        let history = HistoryStore.shared.items
        let text = history.map { item -> String in
            switch item.type {
            case .text:
                return item.text ?? ""
            case .image:
                return t(en: "(Image)", zh: "(图像)")
            case .fileURLs:
                return (item.fileURLs ?? []).joined(separator: separator)
            }
        }.joined(separator: separator + separator)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportHistoryMultipleFiles(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let history = HistoryStore.shared.items
        for (index, item) in history.enumerated() {
            let prefix = String(format: "%03d", index + 1)
            switch item.type {
            case .text:
                try (item.text ?? "").write(to: directory.appendingPathComponent("\(prefix)-text.txt"), atomically: true, encoding: .utf8)
            case .image:
                if let fn = item.imageFileName,
                   let data = ImageStore.shared.originalData(for: fn) {
                    try data.write(to: directory.appendingPathComponent("\(prefix)-image.png"), options: .atomic)
                }
            case .fileURLs:
                let text = (item.fileURLs ?? []).joined(separator: "\n")
                try text.write(to: directory.appendingPathComponent("\(prefix)-files.txt"), atomically: true, encoding: .utf8)
            }
        }
        let indexData = try encoder.encode(history)
        try indexData.write(to: directory.appendingPathComponent("history-index.json"), options: .atomic)
    }

    @objc private func excludeAppsAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK else { return }
            let identifiers = panel.urls.map { url -> String in
                Bundle(url: url)?.bundleIdentifier ?? url.lastPathComponent
            }
            self.settings.excludedApplications = Array(Set(self.settings.excludedApplications + identifiers)).sorted()
            self.updateExcludedAppsLabel()
            self.applyAndNotify()
        }
    }

    @objc private func addFolderAction() {
        applyCurrentTextEdit()
        snippets.append(SnippetNode(type: .folder, title: t(en: "New Folder", zh: "新建文件夹"), content: "", children: []))
        selectedFolderIndex = snippets.count - 1
        selectedSnippetIndex = nil
        reloadSnippetTables()
        DispatchQueue.main.async { [weak self] in
            guard let self, let selectedFolderIndex = self.selectedFolderIndex else { return }
            self.folderTable.editColumn(0, row: selectedFolderIndex + 1, with: nil, select: true)
        }
        applyAndNotify()
    }

    @objc private func deleteFolderAction() {
        guard let idx = selectedFolderIndex, idx < snippets.count else { return }
        applyCurrentTextEdit()
        snippets.remove(at: idx)
        selectedFolderIndex = snippets.isEmpty ? nil : min(idx, snippets.count - 1)
        selectedSnippetIndex = nil
        reloadSnippetTables()
        applyAndNotify()
    }

    @objc private func addSnippetAction() {
        guard let folderIndex = selectedFolderIndex, folderIndex < snippets.count else { return }
        applyCurrentTextEdit()
        snippets[folderIndex].children.append(SnippetNode(type: .snippet,
                                                          title: t(en: "New Snippet", zh: "新建片段"),
                                                          content: t(en: "Snippet text", zh: "片段文本")))
        selectedSnippetIndex = snippets[folderIndex].children.count - 1
        reloadSnippetTables()
        DispatchQueue.main.async { [weak self] in
            guard let self, let selectedSnippetIndex = self.selectedSnippetIndex else { return }
            self.titleTable.editColumn(0, row: selectedSnippetIndex + 1, with: nil, select: true)
        }
        applyAndNotify()
    }

    @objc private func deleteSnippetAction() {
        guard let folderIndex = selectedFolderIndex, folderIndex < snippets.count else { return }
        applyCurrentTextEdit()

        let selectedIndexes = titleTable.selectedRowIndexes
            .filter { $0 > 0 }
            .map { $0 - 1 }
            .filter { $0 < snippets[folderIndex].children.count }

        let indexesToDelete: [Int]
        if selectedIndexes.isEmpty, let snippetIndex = selectedSnippetIndex, snippetIndex < snippets[folderIndex].children.count {
            indexesToDelete = [snippetIndex]
        } else {
            indexesToDelete = Array(Set(selectedIndexes)).sorted(by: >)
        }
        guard !indexesToDelete.isEmpty else { return }

        let nextSelection = indexesToDelete.min() ?? 0
        for index in indexesToDelete {
            snippets[folderIndex].children.remove(at: index)
        }
        selectedSnippetIndex = snippets[folderIndex].children.isEmpty ? nil : min(nextSelection, snippets[folderIndex].children.count - 1)
        reloadSnippetTables()
        applyAndNotify()
    }

    @objc private func snippetGearAction(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? ""
        sender.selectItem(at: 0)
        if title == t(en: "Import Snippets…", zh: "导入片段…") {
            importSnippetsAction()
        } else if title == t(en: "Export Snippets…", zh: "导出片段…") {
            exportSnippetsAction()
        } else if title == t(en: "Reset to Default Snippets", zh: "重置为默认片段") {
            snippets = SnippetNode.defaults()
            selectedFolderIndex = 0
            selectedSnippetIndex = 0
            reloadSnippetTables()
            applyAndNotify()
        }
    }

    @objc private func importSnippetsAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let imported: [SnippetNode]
                if url.pathExtension.lowercased() == "json" {
                    imported = try JSONDecoder().decode([SnippetNode].self, from: data)
                } else {
                    imported = try Self.decodeClipMenuSnippetsXML(data: data)
                }
                self.snippets = imported
                self.selectedFolderIndex = imported.isEmpty ? nil : 0
                self.selectedSnippetIndex = imported.first?.children.isEmpty == false ? 0 : nil
                self.reloadSnippetTables()
                self.applyAndNotify()
            } catch {
                self.showAlert(message: self.t(en: "Import Failed", zh: "导入失败"),
                               informativeText: self.t(en: "This file could not be imported. Please choose a ClipMenu snippets.xml file or a ClipMenuModern JSON file.\n\n",
                                                       zh: "无法导入此文件。请选择 ClipMenu snippets.xml 文件或 ClipMenuModern JSON 文件。\n\n") + error.localizedDescription)
            }
        }
    }

    @objc private func exportSnippetsAction() {
        applyCurrentTextEdit()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml, .json]
        panel.nameFieldStringValue = "snippets.xml"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data: Data
                if url.pathExtension.lowercased() == "json" {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    data = try encoder.encode(self.snippets)
                } else {
                    data = Self.encodeClipMenuSnippetsXML(self.snippets)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                self.showAlert(message: self.t(en: "Export Failed", zh: "导出失败"), informativeText: error.localizedDescription)
            }
        }
    }

    private static func decodeClipMenuSnippetsXML(data: Data) throws -> [SnippetNode] {
        let document = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        guard let root = document.rootElement(), root.name == "folders" else {
            throw NSError(domain: "ClipMenuModern", code: 1, userInfo: [NSLocalizedDescriptionKey: "The XML root element must be <folders>."])
        }
        return root.elements(forName: "folder").map { folderElement in
            let folderTitle = folderElement.elements(forName: "title").first?.stringValue ?? "Untitled Folder"
            let snippetsContainer = folderElement.elements(forName: "snippets").first
            let snippetElements = snippetsContainer?.elements(forName: "snippet") ?? folderElement.elements(forName: "snippet")
            let children = snippetElements.map { snippetElement in
                let title = snippetElement.elements(forName: "title").first?.stringValue ?? "Untitled Snippet"
                let content = snippetElement.elements(forName: "content").first?.stringValue ?? ""
                return SnippetNode(type: .snippet, title: title, content: content)
            }
            return SnippetNode(type: .folder, title: folderTitle, content: "", children: children)
        }
    }

    private static func encodeClipMenuSnippetsXML(_ snippets: [SnippetNode]) -> Data {
        let root = XMLElement(name: "folders")
        for folder in snippets {
            let folderElement = XMLElement(name: "folder")
            folderElement.addChild(XMLElement(name: "title", stringValue: folder.title))
            let snippetsElement = XMLElement(name: "snippets")
            for snippet in folder.children {
                let snippetElement = XMLElement(name: "snippet")
                snippetElement.addChild(XMLElement(name: "title", stringValue: snippet.title))
                snippetElement.addChild(XMLElement(name: "content", stringValue: snippet.content))
                snippetsElement.addChild(snippetElement)
            }
            folderElement.addChild(snippetsElement)
            root.addChild(folderElement)
        }
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private func showAlert(message: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window!)
    }
}

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == folderTable { return snippets.count + 1 }
        if tableView == titleTable { return currentChildren().count + 1 }
        return 0
    }

    func textDidChange(_ notification: Notification) {
        applyCurrentTextEdit()
        Storage.shared.saveSnippets(snippets)
        delegate?.preferencesDidChange(settings: settings, snippets: snippets)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloadingSnippetTables else { return }
        applyCurrentTextEdit()
        guard let table = notification.object as? NSTableView else { return }
        if table == folderTable {
            let row = folderTable.selectedRow
            guard row > 0 else {
                if let selectedFolderIndex {
                    folderTable.selectRowIndexes(IndexSet(integer: selectedFolderIndex + 1), byExtendingSelection: false)
                }
                return
            }
            selectedFolderIndex = row - 1
            selectedSnippetIndex = nil
            titleTable.reloadData()
            let children = currentChildren()
            if !children.isEmpty {
                selectedSnippetIndex = 0
                titleTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                contentTextView.string = children[0].content
            } else {
                contentTextView.string = ""
            }
        } else if table == titleTable {
            let row = titleTable.selectedRowIndexes.first(where: { $0 > 0 }) ?? titleTable.selectedRow
            guard row > 0 else {
                if let selectedSnippetIndex {
                    titleTable.selectRowIndexes(IndexSet(integer: selectedSnippetIndex + 1), byExtendingSelection: false)
                }
                return
            }
            selectedSnippetIndex = row - 1
            if let idx = selectedSnippetIndex, idx < currentChildren().count { contentTextView.string = currentChildren()[idx].content }
            else { contentTextView.string = "" }
        }
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        let actualRows = proposedSelectionIndexes.filter { $0 > 0 }
        if !actualRows.isEmpty { return IndexSet(actualRows) }
        if tableView == folderTable, let selectedFolderIndex {
            return IndexSet(integer: selectedFolderIndex + 1)
        }
        if tableView == titleTable, let selectedSnippetIndex {
            return IndexSet(integer: selectedSnippetIndex + 1)
        }
        return IndexSet()
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        let modelIndexes = rowIndexes
            .filter { $0 > 0 }
            .map { $0 - 1 }
            .sorted()
        guard !modelIndexes.isEmpty else { return false }

        let kind: String
        let folderIndex: Int?
        if tableView == folderTable {
            kind = "folder"
            folderIndex = nil
            guard modelIndexes.allSatisfy({ snippets.indices.contains($0) }) else { return false }
        } else if tableView == titleTable, let currentFolderIndex = selectedFolderIndex {
            kind = "snippet"
            folderIndex = currentFolderIndex
            guard snippets.indices.contains(currentFolderIndex),
                  modelIndexes.allSatisfy({ snippets[currentFolderIndex].children.indices.contains($0) }) else { return false }
        } else {
            return false
        }

        pasteboard.clearContents()
        pasteboard.setString(snippetDragPayload(kind: kind, folderIndex: folderIndex, indexes: modelIndexes),
                             forType: Self.snippetDragType)
        return true
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let payload = snippetDragPayload(from: info.draggingPasteboard) else { return [] }
        let validTarget: Bool
        if tableView == folderTable {
            validTarget = payload.kind == "folder"
        } else if tableView == titleTable {
            validTarget = payload.kind == "snippet" && payload.folderIndex == selectedFolderIndex
        } else {
            validTarget = false
        }
        guard validTarget else { return [] }

        let dropRow = max(1, min(row, tableView.numberOfRows))
        tableView.setDropRow(dropRow, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let payload = snippetDragPayload(from: info.draggingPasteboard) else { return false }
        applyCurrentTextEdit()

        if tableView == folderTable, payload.kind == "folder" {
            let targetIndex = max(0, min(row - 1, snippets.count))
            let oldSnippetIndex = selectedSnippetIndex
            let newIndexes = moveItems(in: &snippets, sourceIndexes: payload.indexes, to: targetIndex)
            guard let newFolderIndex = newIndexes.first else { return false }
            selectedFolderIndex = newFolderIndex
            if let oldSnippetIndex, snippets[newFolderIndex].children.indices.contains(oldSnippetIndex) {
                selectedSnippetIndex = oldSnippetIndex
            } else {
                selectedSnippetIndex = snippets[newFolderIndex].children.isEmpty ? nil : 0
            }
            reloadSnippetTables()
            applyAndNotify()
            return true
        }

        if tableView == titleTable,
           payload.kind == "snippet",
           let folderIndex = payload.folderIndex,
           folderIndex == selectedFolderIndex,
           snippets.indices.contains(folderIndex) {
            let targetIndex = max(0, min(row - 1, snippets[folderIndex].children.count))
            let newIndexes = moveItems(in: &snippets[folderIndex].children, sourceIndexes: payload.indexes, to: targetIndex)
            guard let firstSnippetIndex = newIndexes.first else { return false }
            selectedSnippetIndex = firstSnippetIndex
            reloadSnippetTables()
            isReloadingSnippetTables = true
            titleTable.selectRowIndexes(IndexSet(newIndexes.map { $0 + 1 }), byExtendingSelection: false)
            isReloadingSnippetTables = false
            applyAndNotify()
            return true
        }

        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier(tableView == folderTable ? "FolderCell" : "TitleCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        cell.subviews.forEach { $0.removeFromSuperview() }

        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.state = .on
        checkbox.isEnabled = false
        checkbox.frame = NSRect(x: 10, y: 5, width: 22, height: 22)
        cell.addSubview(checkbox)

        let imageView = NSImageView(frame: NSRect(x: 44, y: 5, width: 22, height: 22))
        let text: NSTextField = row == 0 ? NSTextField(labelWithString: "") : SnippetTitleTextField()
        text.font = bodyFont
        text.frame = NSRect(x: 74, y: 5, width: max(120, tableView.bounds.width - 86), height: 22)
        if row > 0 {
            text.isBordered = false
            text.drawsBackground = false
            text.isEditable = true
            text.isSelectable = true
            text.focusRingType = .none
            text.delegate = self
            text.target = self
            text.action = #selector(snippetTitleCommitted(_:))
            text.tag = row
            text.identifier = NSUserInterfaceItemIdentifier(tableView == folderTable ? "FolderTitleField" : "SnippetTitleField")
        }
        cell.addSubview(imageView)
        cell.addSubview(text)

        if tableView == folderTable {
            if row == 0 {
                imageView.isHidden = true
                text.frame.origin.x = 40
                text.stringValue = t(en: "Check All", zh: "全选")
            } else {
                let node = snippets[row - 1]
                imageView.image = NSImage(named: NSImage.folderName)
                text.stringValue = node.title
            }
        } else {
            if row == 0 {
                imageView.isHidden = true
                text.frame.origin.x = 40
                text.stringValue = t(en: "Check All", zh: "全选")
            } else {
                let node = currentChildren()[row - 1]
                imageView.image = NSImage(named: NSImage.multipleDocumentsName)
                text.stringValue = node.title
            }
        }
        return cell
    }

    @objc private func snippetTitleCommitted(_ sender: NSTextField) {
        updateSnippetTitle(from: sender)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field.identifier?.rawValue == "FolderTitleField" || field.identifier?.rawValue == "SnippetTitleField" else { return }
        updateSnippetTitle(from: field)
    }

    private func updateSnippetTitle(from field: NSTextField) {
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if field.identifier?.rawValue == "FolderTitleField" {
            let index = field.tag - 1
            guard snippets.indices.contains(index) else { return }
            snippets[index].title = title
        } else if field.identifier?.rawValue == "SnippetTitleField" {
            guard let folderIndex = selectedFolderIndex, snippets.indices.contains(folderIndex) else { return }
            let index = field.tag - 1
            guard snippets[folderIndex].children.indices.contains(index) else { return }
            snippets[folderIndex].children[index].title = title
        }
        Storage.shared.saveSnippets(snippets)
        delegate?.preferencesDidChange(settings: settings, snippets: snippets)
    }

    private func snippetDragPayload(kind: String, folderIndex: Int?, indexes: [Int]) -> String {
        let folder = folderIndex.map(String.init) ?? ""
        return "\(kind)|\(folder)|\(indexes.map(String.init).joined(separator: ","))"
    }

    private func snippetDragPayload(from pasteboard: NSPasteboard) -> (kind: String, folderIndex: Int?, indexes: [Int])? {
        guard let string = pasteboard.string(forType: Self.snippetDragType) else { return nil }
        let parts = string.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let indexes = parts[2]
            .split(separator: ",")
            .compactMap { Int($0) }
            .sorted()
        guard !indexes.isEmpty else { return nil }
        return (parts[0], Int(parts[1]), indexes)
    }

    private func moveItems<T>(in array: inout [T], sourceIndexes: [Int], to targetIndex: Int) -> [Int] {
        let sortedIndexes = Array(Set(sourceIndexes))
            .filter { array.indices.contains($0) }
            .sorted()
        guard !sortedIndexes.isEmpty else { return [] }

        let movingItems = sortedIndexes.map { array[$0] }
        for index in sortedIndexes.reversed() {
            array.remove(at: index)
        }

        var adjustedTarget = max(0, min(targetIndex, array.count + movingItems.count))
        for index in sortedIndexes where index < targetIndex {
            adjustedTarget -= 1
        }
        adjustedTarget = max(0, min(adjustedTarget, array.count))
        array.insert(contentsOf: movingItems, at: adjustedTarget)
        return Array(adjustedTarget..<(adjustedTarget + movingItems.count))
    }
}

private final class PreferencesWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let textView = firstResponder as? NSTextView,
           textView.handleStandardEditingShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SnippetTableView: NSTableView {
    var renameHandler: ((NSTableView, Int) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row > 0 else {
            super.rightMouseDown(with: event)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renameHandler?(self, row)
        }
    }
}

private final class SnippetTitleTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let editor = currentEditor() as? NSTextView,
           editor.handleStandardEditingShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SnippetContentTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleStandardEditingShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleStandardEditingShortcut(event) { return }
        super.keyDown(with: event)
    }
}

private extension NSTextView {
    func handleStandardEditingShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }

        switch (key, flags.contains(.shift)) {
        case ("x", false):
            cut(nil)
        case ("c", false):
            copy(nil)
        case ("v", false):
            paste(nil)
        case ("a", false):
            selectAll(nil)
        case ("z", false):
            undoManager?.undo()
        case ("z", true):
            undoManager?.redo()
        default:
            return false
        }
        return true
    }
}
