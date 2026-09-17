import SwiftUI
import WebKit

struct MediaPopover: View {
    let store: BrowserStore
    @State private var contentHeight: CGFloat = 180
    private var sessions: [TabPage] {
        let windows = store.application.map { Array($0.stores.values) } ?? [store]
        return windows.flatMap { window in window.session.tabs.compactMap { window.loadedPage(for: $0.id) } }
            .filter { $0.mediaState.isRelevant }
            .sorted { $0.mediaState.activityAt > $1.mediaState.activityAt }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(sessions, id: \.tabID) { page in
                    MediaSessionControls(page: page)
                    if page.tabID != sessions.last?.tabID { Divider() }
                }
            }.padding(14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(width: 360)
        .frame(height: min(340, contentHeight))
    }
}

private struct MediaSessionControls: View {
    let page: TabPage
    @State private var artwork: NSImage?
    @State private var loadedURL: URL?
    @State private var failedURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var seekPosition = 0.0
    @State private var seeking = false
    @State private var seekSessionID: String?
    @State private var actionPending = false
    @State private var actionFailed = false
    private var state: TabMediaState { page.mediaState }
    private var source: String {
        let host = state.source.lowercased().replacingOccurrences(of: "www.", with: "")
        for (domain, name) in [("youtube.com", "YouTube"), ("spotify.com", "Spotify"), ("soundcloud.com", "SoundCloud")] {
            if host == domain || host.hasSuffix("." + domain) { return name }
        }
        return host
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                artworkView
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.webView.title ?? "Media")
                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 56)
            progress
            HStack(spacing: 24) {
                if state.hasPrevious { transport("backward.end.fill", label: "Previous", action: "previoustrack") }
                transport(state.isPlayingMedia ? "pause.fill" : "play.fill", label: state.isPlayingMedia ? "Pause" : "Play", action: state.isPlayingMedia ? "pause" : "play", primary: true)
                if state.hasNext { transport("forward.end.fill", label: "Next", action: "nexttrack") }
            }.frame(maxWidth: .infinity)
            if actionFailed { Text("Use the player on the website for this action.").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: state.artworkURL) {
            artwork = nil; loadedURL = nil; failedURL = nil
            guard let url = state.artworkURL else { return }
            let image = await page.mediaArtwork.load(url)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                artwork = image; loadedURL = url
                if image == nil { failedURL = url }
            }
        }
    }
    private var artworkView: some View {
        let url = state.artworkURL
        let image = url.flatMap { page.mediaArtwork.cached($0) } ?? (loadedURL == url ? artwork : nil)
        let phase = MediaImagePresentation.phase(hasArtworkURL: url != nil, hasImage: image != nil, failed: url != nil && failedURL == url)
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3))
            if phase == .artwork, let image {
                let size = MediaImagePresentation.fitted(image.size)
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .id(url).transition(.opacity)
            } else if phase == .loading || (page.favicon == nil && page.faviconLoading) {
                ProgressView().controlSize(.small).transition(.opacity)
            } else if let favicon = page.favicon {
                let size = MediaImagePresentation.faviconSize(favicon, scale: displayScale)
                Image(nsImage: favicon).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height).transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(.tertiary)
            }
        }.frame(width: 112, height: 64).accessibilityHidden(true)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: phase)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page.faviconLoading)
    }
    @ViewBuilder private var progress: some View {
        if state.isLive {
            Text("● LIVE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(height: 34).accessibilityLabel("Live media")
        } else if let duration = state.duration, let current = state.currentTime {
            VStack(spacing: 3) {
                if state.canSeek {
                    Slider(value: Binding(get: { seeking ? seekPosition : current }, set: { seekPosition = $0 }), in: 0...duration) { editing in
                        if editing { seekPosition = current; seeking = true; seekSessionID = state.id }
                        else { seeking = false; perform("seekto", time: seekPosition, sessionID: seekSessionID) }
                    }.controlSize(.mini).accessibilityLabel("Playback position")
                } else {
                    ProgressView(value: current, total: duration).controlSize(.mini).accessibilityLabel("Playback progress")
                }
                HStack {
                    Text(MediaTime.label(seeking ? seekPosition : current)); Spacer(); Text(MediaTime.label(duration))
                }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
    private func transport(_ symbol: String, label: String, action: String, primary: Bool = false) -> some View {
        Button { perform(action) } label: {
            Image(systemName: symbol).font(.system(size: primary ? 22 : 14))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(actionPending).help(label).accessibilityLabel(label)
    }
    private func perform(_ action: String, time: Double? = nil, sessionID: String? = nil) {
        let expectedID = sessionID ?? state.id
        actionPending = true; actionFailed = false
        Task {
            actionFailed = !(await page.controlMedia(action, time: time, sessionID: expectedID))
            actionPending = false
        }
    }
}

enum MediaTime {
    static func label(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let value = Int(seconds), hours = value / 3600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, (value / 60) % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
