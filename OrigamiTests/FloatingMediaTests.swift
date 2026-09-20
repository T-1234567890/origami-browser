import Foundation
import Testing
@testable import Origami

@MainActor struct FloatingMediaTests {
    @Test func selectionFollowsPopoverActivityAndDropsUnavailableSessions() {
        let first = TabPage(), second = TabPage(), metadataOnly = TabPage()
        defer { first.dispose(); second.dispose(); metadataOnly.dispose() }
        first.mediaState = TabMediaState(snapshot: ["id": "first", "phase": "playing", "activityAt": 1.0])
        second.mediaState = TabMediaState(snapshot: ["id": "second", "phase": "paused", "activityAt": 2.0])
        metadataOnly.mediaState.title = "Not playable"
        #expect(MediaSessionSelection.ordered([first, metadataOnly, second]).first === second)
        second.mediaState = TabMediaState()
        #expect(MediaSessionSelection.ordered([second, first]).first === first)
        first.mediaState = TabMediaState()
        #expect(MediaSessionSelection.ordered([first, second, metadataOnly]).isEmpty)
    }

    @Test func equalActivityUsesStableOrderAcrossWindows() {
        let first = TabPage(), second = TabPage()
        defer { first.dispose(); second.dispose() }
        for page in [first, second] {
            page.mediaState = TabMediaState(snapshot: ["id": "session", "phase": "playing", "activityAt": 1.0])
        }
        #expect(MediaSessionSelection.ordered([first, second]).map(\.tabID) ==
                MediaSessionSelection.ordered([second, first]).map(\.tabID))
    }

    @Test func draggingSelectsNearestBottomCorner() {
        #expect(FloatingMediaPresentation.trailingCorner(startTrailing: true, translation: -100, width: 800))
        #expect(!FloatingMediaPresentation.trailingCorner(startTrailing: true, translation: -500, width: 800))
        #expect(FloatingMediaPresentation.trailingCorner(startTrailing: false, translation: 500, width: 800))
        #expect(!FloatingMediaPresentation.trailingCorner(startTrailing: false, translation: 100, width: 800))
    }

    @Test func accentRingTracksProgressAndUsesFullRingForLive() {
        var state = TabMediaState(snapshot: ["id":"track", "phase":"playing", "duration":100.0, "currentTime":25.0])
        #expect(FloatingMediaPresentation.progress(state) == 0.25)
        state.phase = .paused
        #expect(FloatingMediaPresentation.progress(state) == 0.25)
        state.isLive = true; state.duration = nil
        #expect(FloatingMediaPresentation.progress(state) == 1)
        state.isLive = false
        #expect(FloatingMediaPresentation.progress(state) == nil)
        #expect(FloatingMediaPresentation.progress(TabMediaState()) == nil)
    }

    @Test func preferenceDefaultsOffAndPersistsBetweenReaders() throws {
        let suite = "FloatingMediaTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!defaults.bool(forKey: FloatingMediaPreference.key))
        defaults.set(true, forKey: FloatingMediaPreference.key)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(reopened.bool(forKey: FloatingMediaPreference.key))
        reopened.set(false, forKey: FloatingMediaPreference.key)
        #expect(!defaults.bool(forKey: FloatingMediaPreference.key))
    }
}
