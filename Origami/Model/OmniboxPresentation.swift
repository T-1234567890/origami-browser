import Foundation
import AppKit

enum OmniboxPresentation {
    static func editingValue(_ value: String) -> String {
        if let url = URL(string: value), InternalRoute.page(for: url) != nil { return "" }
        return value
    }
    static func shouldRefreshEditing(previous: String, current: String, text: String) -> Bool {
        previous != current && text == editingValue(previous)
    }
    static func schemeLength(_ value: String) -> Int {
        guard let scheme = URL(string: value)?.scheme,
              value.lowercased().hasPrefix(scheme.lowercased() + "://") else { return 0 }
        return (scheme as NSString).length + 3
    }
    static func isInsecure(_ value: String) -> Bool {
        URL(string: value)?.scheme?.lowercased() == "http" && schemeLength(value) > 0
    }
    static func attributedDisplay(_ value: String, font: NSFont, connectionWarning: Bool = false) -> NSAttributedString {
        let text = displayValue(value, connectionWarning: connectionWarning)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if isInsecure(text) || connectionWarning && schemeLength(text) > 0 {
            result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: schemeLength(text)))
        }
        return result
    }
    static func displayValue(_ value: String, connectionWarning: Bool = false) -> String {
        let text = editingValue(value)
        return isInsecure(text) || connectionWarning ? text : String(text.dropFirst(schemeLength(text)))
    }
}
