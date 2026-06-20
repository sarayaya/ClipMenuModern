import Cocoa

struct ClipItem: Codable, Identifiable, Equatable {
    enum ClipType: String, Codable { case text, image, fileURLs }
    var id: UUID = UUID()
    var type: ClipType
    var text: String?
    var imagePNG: Data?
    var imageFileName: String?
    var fileURLs: [String]?
    var createdAt: Date = Date()
    var isFavorite: Bool? = nil

    var preview: String {
        switch type {
        case .text:
            let raw = (text ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "(Empty Text)" : raw
        case .image:
            return "(Image)"
        case .fileURLs:
            if let first = fileURLs?.first { return URL(fileURLWithPath: first).lastPathComponent }
            return "(File)"
        }
    }

    var duplicateKey: String {
        switch type {
        case .text: return "text:" + (text ?? "")
        case .fileURLs: return "files:" + (fileURLs ?? []).joined(separator: "|")
        case .image:
            // Use the filename as the stable identity — same image always gets same name (UUID.png).
            // Fall back to data fingerprint only for legacy in-memory items during migration.
            if let fn = imageFileName { return "image:file:\(fn)" }
            guard let data = imagePNG else { return "image:0" }
            return "image:\(data.count):\(data.lightweightFingerprint)"
        }
    }
}

private extension Data {
    var lightweightFingerprint: Int {
        var hasher = Hasher()
        let prefixCount = Swift.min(4096, count)
        hasher.combine(self.prefix(prefixCount))
        if count > prefixCount {
            hasher.combine(self.suffix(Swift.min(4096, count - prefixCount)))
        }
        return hasher.finalize()
    }
}

struct SnippetNode: Codable, Identifiable, Equatable {
    enum NodeType: String, Codable { case folder, snippet }
    var id: UUID = UUID()
    var type: NodeType
    var title: String
    var content: String
    var children: [SnippetNode] = []

    static func defaults() -> [SnippetNode] {
        [
            SnippetNode(type: .folder, title: "E-mail", content: "", children: [
                SnippetNode(type: .snippet, title: "Address", content: "name@example.com"),
                SnippetNode(type: .snippet, title: "Signature", content: "Best regards,\n")
            ]),
            SnippetNode(type: .folder, title: "URL", content: "", children: [
                SnippetNode(type: .snippet, title: "Website", content: "https://www.example.com")
            ])
        ]
    }
}


struct CustomTextRule: Codable, Identifiable, Equatable {
    enum RuleType: String, Codable { case replace, regexReplace }

    var id: UUID = UUID()
    var name: String
    var find: String
    var replace: String
    var type: RuleType = .replace
    var isEnabled: Bool = true

    static func defaults() -> [CustomTextRule] { [] }

    func apply(to text: String) -> String {
        guard isEnabled, !find.isEmpty else { return text }
        switch type {
        case .replace:
            return text.replacingOccurrences(of: find, with: replace)
        case .regexReplace:
            guard let regex = try? NSRegularExpression(pattern: find, options: []) else { return text }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replace)
        }
    }
}

struct AppSettings: Codable {
    enum SortHistoryOrder: String, Codable {
        case lastUsed = "Last Used"
        case lastCopied = "Last Copied"
        case oldestFirst = "Oldest First"
    }

    enum ExportHistoryFormat: String, Codable {
        case singleFile = "Single file"
        case multipleFiles = "Multiple files"
    }

    enum ExportSeparator: String, Codable {
        case lf = "LF"
        case crlf = "CR+LF"
        case cr = "CR"
        case tab = "Tab"
        case space = "Space"
        case none = "None"

        var value: String {
            switch self {
            case .lf: return "\n"
            case .crlf: return "\r\n"
            case .cr: return "\r"
            case .tab: return "\t"
            case .space: return " "
            case .none: return ""
            }
        }
    }

    enum SnippetsPosition: String, Codable {
        case none = "Do not show snippets"
        case belowHistory = "Below the clipboard history"
        case aboveHistory = "Above the clipboard history"
    }

    enum FontSizeMode: String, Codable {
        case fit = "Fit"
        case select = "Select"
    }

    enum AppIconStyle: String, Codable {
        case `default` = "Default"
        case clipboard  = "Clipboard"
        case scissors   = "Scissors"
        case backup1    = "Backup 1"
        case backup2    = "Backup 2"
        case none       = "None"
    }

    var language: String = "Chinese"
    var maxHistory: Int = 80
    var previewHistoryCount: Int = 10
    var pageSize: Int = 40
    var secondFolderSize: Int = 30
    var menuPreviewLength: Int = 20
    var showImagesInMenu: Bool = true
    var imagePreviewWidth: Int = 40
    var imagePreviewHeight: Int = 28
    var captureText: Bool = true
    var captureImages: Bool = true
    var captureFiles: Bool = true
    var pasteAfterSelection: Bool = false
    var stripWhitespaceInMenu: Bool = true
    var hotKeyEnabled: Bool = true
    var hotKeyKeyCode: UInt32 = 9       // V
    var hotKeyModifiers: UInt32 = 3840 // control + option + command (Carbon)

    var launchOnLogin: Bool = false
    var saveHistoryOnQuit: Bool = true
    var sortHistoryOrder: String = "Last Used"
    var autosaveHistoryInterval: String = "Every 30 minutes"
    var exportHistoryAs: String = "Single file"
    var exportSeparator: String = "LF"
    var appIconStyle: String = "Default"
    var observeIntervalSeconds: Double = 1.0
    var excludedApplications: [String] = []
    var snippetsPosition: String = "Below the clipboard history"

    // Action pane
    var enableActions: Bool = true
    var invokeSingleActionImmediately: Bool = false
    var controlClickBehavior: String = "None"
    var shiftClickBehavior: String = "None"
    var optionClickBehavior: String = "None"
    var commandClickBehavior: String = "None"
    // Menu pane (numbering)
    var markItemsWithNumbers: Bool = true
    var numberItemsFromZero: Bool = false
    var addNumericKeyEquivalents: Bool = true
    // Menu pane (more, matching original ClipMenu)
    var showLabels: Bool = true
    var addClearHistoryItem: Bool = true
    var showToolTip: Bool = true
    var maxToolTipLength: Int = 200
    var changeFontSize: Bool = false
    var fontSizeMode: String = "Fit"      // "Fit" or "Select"
    var selectedFontSize: Int = 14
    // Clipboard history
    var confirmBeforeClearHistory: Bool = true
    // Type / Icon pane
    var showIconInMenu: Bool = true
    var iconSize: Int = 16
    var iconTypeSettings: [IconTypeSetting] = IconTypeSetting.defaults()
    var customTextRules: [CustomTextRule] = CustomTextRule.defaults()

    enum CodingKeys: String, CodingKey {
        case language
        case maxHistory, previewHistoryCount, pageSize, secondFolderSize, menuPreviewLength, showImagesInMenu, imagePreviewWidth, imagePreviewHeight
        case captureText, captureImages, captureFiles, pasteAfterSelection, stripWhitespaceInMenu
        case hotKeyEnabled, hotKeyKeyCode, hotKeyModifiers
        case launchOnLogin, saveHistoryOnQuit, sortHistoryOrder, autosaveHistoryInterval
        case exportHistoryAs, exportSeparator, appIconStyle, observeIntervalSeconds, excludedApplications, snippetsPosition
        case enableActions, invokeSingleActionImmediately, controlClickBehavior, shiftClickBehavior, optionClickBehavior, commandClickBehavior
        case markItemsWithNumbers, numberItemsFromZero, addNumericKeyEquivalents
        case showLabels, addClearHistoryItem, showToolTip, maxToolTipLength, changeFontSize, fontSizeMode, selectedFontSize
        case confirmBeforeClearHistory, showIconInMenu, iconSize, iconTypeSettings, customTextRules
    }

    init() {}

    var sortHistoryOrderValue: SortHistoryOrder {
        get { SortHistoryOrder(rawValue: sortHistoryOrder) ?? .lastUsed }
        set { sortHistoryOrder = newValue.rawValue }
    }

    var exportHistoryFormatValue: ExportHistoryFormat {
        get { ExportHistoryFormat(rawValue: exportHistoryAs) ?? .singleFile }
        set { exportHistoryAs = newValue.rawValue }
    }

    var exportSeparatorValue: ExportSeparator {
        get { ExportSeparator(rawValue: exportSeparator) ?? .lf }
        set { exportSeparator = newValue.rawValue }
    }

    var snippetsPositionValue: SnippetsPosition {
        get {
            if snippetsPosition == "None" { return .none }
            return SnippetsPosition(rawValue: snippetsPosition) ?? .belowHistory
        }
        set { snippetsPosition = newValue.rawValue }
    }

    var fontSizeModeValue: FontSizeMode {
        get { FontSizeMode(rawValue: fontSizeMode) ?? .fit }
        set { fontSizeMode = newValue.rawValue }
    }

    var appIconStyleValue: AppIconStyle {
        get { AppIconStyle(rawValue: appIconStyle) ?? .default }
        set { appIconStyle = newValue.rawValue }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "Chinese"
        maxHistory = try c.decodeIfPresent(Int.self, forKey: .maxHistory) ?? 80
        previewHistoryCount = try c.decodeIfPresent(Int.self, forKey: .previewHistoryCount) ?? 10
        pageSize = try c.decodeIfPresent(Int.self, forKey: .pageSize) ?? 40
        secondFolderSize = try c.decodeIfPresent(Int.self, forKey: .secondFolderSize) ?? 30
        menuPreviewLength = try c.decodeIfPresent(Int.self, forKey: .menuPreviewLength) ?? 20
        showImagesInMenu = try c.decodeIfPresent(Bool.self, forKey: .showImagesInMenu) ?? true
        imagePreviewWidth = try c.decodeIfPresent(Int.self, forKey: .imagePreviewWidth) ?? 40
        imagePreviewHeight = try c.decodeIfPresent(Int.self, forKey: .imagePreviewHeight) ?? 28
        captureText = try c.decodeIfPresent(Bool.self, forKey: .captureText) ?? true
        captureImages = try c.decodeIfPresent(Bool.self, forKey: .captureImages) ?? true
        captureFiles = try c.decodeIfPresent(Bool.self, forKey: .captureFiles) ?? true
        pasteAfterSelection = try c.decodeIfPresent(Bool.self, forKey: .pasteAfterSelection) ?? false
        stripWhitespaceInMenu = try c.decodeIfPresent(Bool.self, forKey: .stripWhitespaceInMenu) ?? true
        hotKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? true
        hotKeyKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyKeyCode) ?? 9
        hotKeyModifiers = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? 3840
        launchOnLogin = try c.decodeIfPresent(Bool.self, forKey: .launchOnLogin) ?? false
        saveHistoryOnQuit = try c.decodeIfPresent(Bool.self, forKey: .saveHistoryOnQuit) ?? true
        sortHistoryOrder = try c.decodeIfPresent(String.self, forKey: .sortHistoryOrder) ?? "Last Used"
        autosaveHistoryInterval = try c.decodeIfPresent(String.self, forKey: .autosaveHistoryInterval) ?? "Every 30 minutes"
        exportHistoryAs = try c.decodeIfPresent(String.self, forKey: .exportHistoryAs) ?? "Single file"
        exportSeparator = try c.decodeIfPresent(String.self, forKey: .exportSeparator) ?? "LF"
        appIconStyle = try c.decodeIfPresent(String.self, forKey: .appIconStyle) ?? "Default"
        observeIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .observeIntervalSeconds) ?? 1.0
        excludedApplications = try c.decodeIfPresent([String].self, forKey: .excludedApplications) ?? []
        snippetsPosition = try c.decodeIfPresent(String.self, forKey: .snippetsPosition) ?? "Below the clipboard history"
        enableActions = try c.decodeIfPresent(Bool.self, forKey: .enableActions) ?? true
        invokeSingleActionImmediately = try c.decodeIfPresent(Bool.self, forKey: .invokeSingleActionImmediately) ?? false
        controlClickBehavior = try c.decodeIfPresent(String.self, forKey: .controlClickBehavior) ?? "None"
        shiftClickBehavior = try c.decodeIfPresent(String.self, forKey: .shiftClickBehavior) ?? "None"
        optionClickBehavior = try c.decodeIfPresent(String.self, forKey: .optionClickBehavior) ?? "None"
        commandClickBehavior = try c.decodeIfPresent(String.self, forKey: .commandClickBehavior) ?? "None"
        markItemsWithNumbers = try c.decodeIfPresent(Bool.self, forKey: .markItemsWithNumbers) ?? true
        numberItemsFromZero = try c.decodeIfPresent(Bool.self, forKey: .numberItemsFromZero) ?? false
        addNumericKeyEquivalents = try c.decodeIfPresent(Bool.self, forKey: .addNumericKeyEquivalents) ?? true
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        addClearHistoryItem = try c.decodeIfPresent(Bool.self, forKey: .addClearHistoryItem) ?? true
        showToolTip = try c.decodeIfPresent(Bool.self, forKey: .showToolTip) ?? true
        maxToolTipLength = try c.decodeIfPresent(Int.self, forKey: .maxToolTipLength) ?? 200
        changeFontSize = try c.decodeIfPresent(Bool.self, forKey: .changeFontSize) ?? false
        fontSizeMode = try c.decodeIfPresent(String.self, forKey: .fontSizeMode) ?? "Fit"
        selectedFontSize = try c.decodeIfPresent(Int.self, forKey: .selectedFontSize) ?? 14
        confirmBeforeClearHistory = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeClearHistory) ?? true
        showIconInMenu = try c.decodeIfPresent(Bool.self, forKey: .showIconInMenu) ?? true
        iconSize = try c.decodeIfPresent(Int.self, forKey: .iconSize) ?? 16
        iconTypeSettings = try c.decodeIfPresent([IconTypeSetting].self, forKey: .iconTypeSettings) ?? IconTypeSetting.defaults()
        customTextRules = try c.decodeIfPresent([CustomTextRule].self, forKey: .customTextRules) ?? CustomTextRule.defaults()
    }
}

extension AppSettings {
    var usesChinese: Bool { language == "Chinese" }

    func text(en: String, zh: String) -> String {
        let languageFolder = usesChinese ? "zh-Hans" : "en"
        if let path = Bundle.main.path(forResource: languageFolder, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let fallback = usesChinese ? zh : en
            return bundle.localizedString(forKey: en, value: fallback, table: nil)
        }
        return usesChinese ? zh : en
    }
}

struct IconTypeSetting: Codable, Equatable {
    var label: String
    var mode: String   // "File type code" or "File extension"
    var code: String

    static func defaults() -> [IconTypeSetting] {
        [
            IconTypeSetting(label: "Plain Text", mode: "File type code", code: "TEXT"),
            IconTypeSetting(label: "RTF",        mode: "File extension", code: "rtf"),
            IconTypeSetting(label: "RTFD",       mode: "File extension", code: "rtfd"),
            IconTypeSetting(label: "PDF",        mode: "File extension", code: "pdf"),
            IconTypeSetting(label: "Filenames",  mode: "File type code", code: "clpu"),
            IconTypeSetting(label: "URL",        mode: "File type code", code: "gurl"),
            IconTypeSetting(label: "TIFF",       mode: "File extension", code: "tiff"),
            IconTypeSetting(label: "PICT",       mode: "File extension", code: "pict")
        ]
    }
}
