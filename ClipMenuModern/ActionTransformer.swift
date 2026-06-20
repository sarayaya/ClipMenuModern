import Foundation

struct TextAction {
    let title: String
    let transform: (String) -> String

    static func allActions(customRules: [CustomTextRule]) -> [TextAction] {
        builtIns + customRules
            .filter { $0.isEnabled }
            .map { rule in
                TextAction(title: rule.name) { text in
                    rule.apply(to: text)
                }
            }
    }

    static func normalizedWhitespace(_ text: String) -> String {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let builtIns: [TextAction] = [
        TextAction(title: "Uppercase", transform: { $0.uppercased() }),
        TextAction(title: "Lowercase", transform: { $0.lowercased() }),
        TextAction(title: "Capitalize", transform: { $0.capitalized }),
        TextAction(title: "Trim Whitespace", transform: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
        TextAction(title: "Remove Line Breaks", transform: { $0.replacingOccurrences(of: "\n", with: " ") }),
        TextAction(title: "Delete Empty Lines", transform: TextAction.deleteEmptyLines),
        TextAction(title: "Merge Multiple Lines", transform: TextAction.mergeMultipleLines),
        TextAction(title: "Clean DOI / PMID", transform: TextAction.cleanDOIPMID),
        TextAction(title: "Replace Chinese Punctuation", transform: TextAction.replaceChinesePunctuation),
        TextAction(title: "Add Space Between Numbers and Units", transform: TextAction.addSpaceBetweenNumbersAndUnits),
        TextAction(title: "URL Encode", transform: { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }),
        TextAction(title: "URL Decode", transform: { $0.removingPercentEncoding ?? $0 })
    ]

    private static func deleteEmptyLines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    private static func mergeMultipleLines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanDOIPMID(_ text: String) -> String {
        var output = text
            .replacingOccurrences(of: #"(?i)\bdoi\s*[:：]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bpmid\s*[:：]\s*"#, with: "PMID: ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)https?://(?:dx\.)?doi\.org/"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bDOI\s*[:：]\s*"#, with: "", options: .regularExpression)
        output = output
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output
    }

    private static func replaceChinesePunctuation(_ text: String) -> String {
        let mapping: [Character: String] = [
            "，": ", ", "。": ". ", "；": "; ", "：": ": ", "？": "? ", "！": "! ",
            "（": "(", "）": ")", "【": "[", "】": "]", "《": "<", "》": ">",
            "“": "\"", "”": "\"", "‘": "'", "’": "'", "、": ", ", "—": "-", "～": "~",
            "…": "..."
        ]
        var output = ""
        for ch in text {
            output += mapping[ch] ?? String(ch)
        }
        return output
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ;", with: ";")
            .replacingOccurrences(of: " :", with: ":")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
    }

    private static func addSpaceBetweenNumbersAndUnits(_ text: String) -> String {
        let pattern = #"(?<=\d)(?=(?:mm|cm|m|km|mg|g|kg|ml|mL|L|℃|°C|%|ms|s|min|h|Hz|kHz|MHz|GHz|MB|GB|TB|px|pt|dpi)\b|[℃%])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
    }
}
