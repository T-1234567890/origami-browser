import Testing
import Foundation
import AppKit
@testable import Origami

@MainActor struct AppearancePreferenceTests {
    @Test func privateAppearanceOverridesWithoutChangingNormalPreference() {
        for mode in ["System", "Light", "Dark"] {
            #expect(WindowAppearanceBridge.resolvedMode(preference: mode, isPrivate: true) == "Dark")
            #expect(WindowAppearanceBridge.resolvedMode(preference: mode, isPrivate: false) == mode)
        }
    }

    @Test func windowAppearanceAppliesLatestModeAfterReconciliation() async {
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = WindowAppearanceBridge.AppearanceView()
        window.contentView = view
        view.mode = "Dark"; view.scheduleApply()
        view.mode = "Light"; view.scheduleApply()
        #expect(window.appearance == nil)
        await drainMainQueue()
        #expect(window.appearance?.name == .aqua)
        view.mode = "Dark"; view.scheduleApply()
        await drainMainQueue()
        #expect(window.appearance?.name == .darkAqua)
        view.mode = "System"; view.scheduleApply()
        await drainMainQueue()
        #expect(window.appearance == nil)
    }

    @Test func detachedAppearanceUpdateDoesNotChangeOldWindow() async {
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = WindowAppearanceBridge.AppearanceView()
        window.contentView = view
        view.mode = "Dark"; view.scheduleApply()
        window.contentView = nil
        await drainMainQueue()
        #expect(window.appearance == nil)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func gradientRetainsMainAccentAndCombinedFillPreference() throws {
        let name = "Origami.GradientTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Personalization(defaults: defaults)
        #expect(settings.hex == "55D4B3" && !settings.gradientEnabled && !settings.frameFill)
        settings.hex = "D65F78"; settings.gradientHex = "84A9F5"; settings.gradientEnabled = true
        settings.frameFill = true
        let restored = Personalization(defaults: defaults)
        #expect(restored.hex == "D65F78" && restored.gradientHex == "84A9F5" && restored.gradientEnabled)
        #expect(restored.frameFill)
        defaults.set(true, forKey: "appearance.sidebarTint")
        restored.frameFill = false
        let migrated = Personalization(defaults: defaults)
        #expect(migrated.frameFill)
        #expect(defaults.object(forKey: "appearance.sidebarTint") == nil)
        migrated.frameFill = false
        #expect(!Personalization(defaults: defaults).frameFill)
    }
}
