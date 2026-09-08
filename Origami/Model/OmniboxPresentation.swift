import Foundation

enum OmniboxPresentation {
    static func editingValue(_ value: String) -> String {
        if let url = URL(string: value), InternalRoute.page(for: url) != nil { return "" }
        return value
    }
    static func schemeLength(_ value: String) -> Int {
        guard let scheme = URL(string: value)?.scheme,
              value.lowercased().hasPrefix(scheme.lowercased() + "://") else { return 0 }
        return (scheme as NSString).length + 3
    }
    static func displayValue(_ value: String) -> String {
        let text = editingValue(value)
        return String(text.dropFirst(schemeLength(text)))
    }
}
