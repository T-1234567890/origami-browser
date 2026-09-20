import Foundation
import SwiftUI
import Observation

/// Persisted identifiers are independent of translated display names.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .system: L10n.string("System Default")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
    static func resolve(_ selection: AppLanguage, preferred: [String]) -> AppLanguage {
        guard selection == .system else { return selection }
        for identifier in preferred {
            let tag = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if tag == "en" || tag.hasPrefix("en-") { return .english }
            if tag == "zh" || tag == "zh-hans" || tag.hasPrefix("zh-hans-") || tag == "zh-cn" || tag == "zh-sg" { return .simplifiedChinese }
        }
        return .english
    }
}

@MainActor @Observable final class LanguageManager {
    static let shared = LanguageManager()
    private let defaults: UserDefaults
    var selection: AppLanguage {
        didSet {
            defaults.set(selection.rawValue, forKey: "app.language")
            // Keep system-owned UI consistent on the next launch; Origami-owned
            // UI observes selection and updates immediately without replacing tabs.
            if selection == .system { defaults.removeObject(forKey: "AppleLanguages") }
            else { defaults.set([selection.rawValue], forKey: "AppleLanguages") }
        }
    }
    var resolvedLanguage: AppLanguage { AppLanguage.resolve(selection, preferred: L10n.systemLanguages) }
    var locale: Locale { Locale(identifier: resolvedLanguage.rawValue) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = AppLanguage(rawValue: defaults.string(forKey: "app.language") ?? "") ?? .system
        selection = saved
    }
}

/// Shared by SwiftUI's dynamic labels, AppKit, and service errors. Unknown keys
/// fall back to English; webpage content and user-created names never enter here.
enum L10n {
    // Read global preferences rather than the launch-time per-app AppleLanguages override.
    static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
    }
    static var language: AppLanguage {
        // View reads participate in Observation. Background service lookups use
        // thread-safe defaults and never synchronously wait for the main actor.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { LanguageManager.shared.resolvedLanguage }
        }
        let selection = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "") ?? .system
        return AppLanguage.resolve(selection, preferred: systemLanguages)
    }
    static var locale: Locale { Locale(identifier: language.rawValue) }
    static func string(_ key: String, language: AppLanguage? = nil, bundle: Bundle = .main) -> String {
        let resolved = AppLanguage.resolve(language ?? self.language, preferred: systemLanguages)
        let code = resolved.rawValue
        guard let path = bundle.path(forResource: code, ofType: "lproj"), let localized = Bundle(path: path) else { return key }
        return localized.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}

/// For window roots and SwiftUI surfaces hosted separately by AppKit.
struct LiveLanguage: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.locale, LanguageManager.shared.locale)
    }
}
