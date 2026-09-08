import Foundation
import Observation

enum TabLifecycleState: String { case active, sleeping }
enum MemoryPressure { case normal, warning, critical }
struct TabActivity {
    var state: TabLifecycleState = .active
    var lastActive = Date()
    var userExempt = false
    var isPlayingMedia = false
    var hasDownload = false
    var hasCapture = false
    // WebKit does not report all WebRTC/data-channel activity, so eligibility is conservative.
    var backgroundActivityKnownSafe = false
}
@MainActor @Observable
final class TabLifecycleService {
    private(set) var memoryPressure: MemoryPressure = .normal
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressureSource = source
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let flags = pressureSource?.data ?? []
                memoryPressure = flags.contains(.critical) ? .critical : flags.contains(.warning) ? .warning : .normal
            }
        }
        source.resume()
    }
    deinit { pressureSource?.cancel() }
    func maySleep(_ activity: TabActivity, pinned: Bool, selected: Bool, now: Date = Date(), idleInterval: TimeInterval = 900) -> Bool {
        activity.state == .active && !selected && !pinned && !activity.userExempt && !activity.isPlayingMedia && !activity.hasDownload && !activity.hasCapture && activity.backgroundActivityKnownSafe && now.timeIntervalSince(activity.lastActive) >= idleInterval
    }
}
