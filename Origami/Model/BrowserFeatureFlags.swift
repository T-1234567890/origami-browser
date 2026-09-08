import Foundation

/// Internal launch flags; intentionally absent from user preferences and onboarding.
enum BrowserFeatureFlags {
    static let compactSidebar = compactSidebarEnabled(environment: ProcessInfo.processInfo.environment)

    static func compactSidebarEnabled(environment: [String: String]) -> Bool {
        environment["ORIGAMI_ENABLE_COMPACT_SIDEBAR"] == "1"
    }

    static func sidebarBehavior(_ saved: SidebarBehavior, enabled: Bool = compactSidebar) -> SidebarBehavior {
        enabled ? saved : .visible
    }
}
