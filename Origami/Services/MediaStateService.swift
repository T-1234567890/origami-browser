import WebKit

struct TabMediaState: Equatable {
    enum Phase: String { case inactive, playing, paused }
    var id: String?
    var phase: Phase = .inactive
    var isLive = false
    var isMuted: Bool?
    var title: String?
    var source = ""
    var artworkURL: URL?
    var currentTime: Double?
    var duration: Double?
    var canSeek = false
    var hasPrevious = false
    var hasNext = false
    var activityAt: Double = 0
    var hasCapture = false
    var isPlayingMedia: Bool { phase == .playing }
    var isRelevant: Bool { id != nil && phase != .inactive }

    init() {}
    init(snapshot: [String: Any]) {
        guard let id = snapshot["id"] as? String, !id.isEmpty, id.count <= 200,
              let phaseText = snapshot["phase"] as? String, let phase = Phase(rawValue: phaseText), phase != .inactive else { return }
        self.id = id; self.phase = phase
        isLive = snapshot["live"] as? Bool ?? false
        isMuted = snapshot["muted"] as? Bool
        title = (snapshot["title"] as? String).map { String($0.prefix(512)) }
        source = String((snapshot["source"] as? String ?? "").prefix(253))
        if let text = snapshot["artwork"] as? String, text.count <= 4096, let url = URL(string: text),
           ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil { artworkURL = url }
        func finite(_ key: String) -> Double? {
            guard let number = snapshot[key] as? Double, number.isFinite, number >= 0 else { return nil }
            return number
        }
        currentTime = finite("currentTime")
        duration = isLive ? nil : finite("duration").flatMap { $0 > 0 ? $0 : nil }
        if let time = currentTime, let duration, time > duration { currentTime = nil }
        canSeek = !isLive && duration != nil && currentTime != nil && snapshot["canSeek"] as? Bool == true
        hasPrevious = snapshot["previous"] as? Bool ?? false
        hasNext = snapshot["next"] as? Bool ?? false
        activityAt = finite("activityAt") ?? 0
    }
}

@MainActor
struct MediaStateService {
    func sample(_ webView: WKWebView) async -> TabMediaState {
        let value = try? await webView.evaluateJavaScript("window.__origamiMedia?.snapshot()")
        var state = (value as? [String: Any]).map(TabMediaState.init(snapshot:)) ?? TabMediaState()
        state.hasCapture = webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
        return state
    }
}

/// Frame reports carry media information only. No browser data or privileged commands are exposed.
@MainActor
final class MediaFrameObserver: NSObject, WKScriptMessageHandler {
    private struct Report {
        var state: TabMediaState
        var frame: WKFrameInfo
        var received: Date
    }
    private var reports: [String: Report] = [:]
    weak var webView: WKWebView?
    var changed: (() -> Void)?
    var current: TabMediaState {
        reports.values.map(\.state).sorted {
            if $0.isPlayingMedia != $1.isPlayingMedia { return $0.isPlayingMedia }
            return $0.activityAt > $1.activityAt
        }.first ?? TabMediaState()
    }
    func frame(for id: String) -> WKFrameInfo? { reports.values.first { $0.state.id == id }?.frame }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView, message.webView === webView, let body = message.body as? [String: Any],
              let documentID = body["documentID"] as? String, UUID(uuidString: documentID) != nil else { return }
        var state = (body["media"] as? [String: Any]).map(TabMediaState.init(snapshot:)) ?? TabMediaState()
        state.source = message.frameInfo.securityOrigin.host.isEmpty ? webView.url?.host ?? "" : message.frameInfo.securityOrigin.host
        guard state.id == nil || state.id?.hasPrefix(documentID + ":") == true else { return }
        if state.isRelevant {
            guard reports[documentID] != nil || reports.count < 32 else { return }
            reports[documentID] = Report(state: state, frame: message.frameInfo, received: Date())
        } else { reports.removeValue(forKey: documentID) }
        changed?()
    }
    func expire() {
        reports = reports.filter { Date().timeIntervalSince($0.value.received) < 8 }
    }
    func reset() { reports.removeAll(); changed?() }
}
