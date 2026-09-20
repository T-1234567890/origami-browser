import SwiftUI
import WebKit

struct MediaPopover: View {
    let store: BrowserStore
    @State private var contentHeight: CGFloat = 180
    @AppStorage(FloatingMediaPreference.key) private var floatingEnabled = false
    private var sessions: [TabPage] { MediaSessionSelection.pages(in: store) }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(sessions, id: \.tabID) { page in
                    MediaSessionControls(page: page)
                    if page.tabID != sessions.last?.tabID { Divider() }
                }
                Divider()
                Toggle(isOn: $floatingEnabled) {
                    Label("Floating Media Control", systemImage: "pip")
                }.toggleStyle(.switch).controlSize(.small)
            }.padding(14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(width: 360)
        .frame(height: min(340, contentHeight))
    }
}

struct MediaSessionControls: View {
    let page: TabPage
    var showsArtwork = true
    var transportOnly = false
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
            if !transportOnly {
                HStack(spacing: 12) {
                    if showsArtwork { MediaArtworkView(page: page) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.webView.title ?? "Media")
                            .font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: showsArtwork ? 56 : 0)
                progress
            }
            HStack(spacing: transportOnly ? 16 : 24) {
                transport("backward.end.fill", label: "Previous", action: "previoustrack", supported: state.hasPrevious)
                transport(state.isPlayingMedia ? "pause.fill" : "play.fill", label: state.isPlayingMedia ? "Pause" : "Play", action: state.isPlayingMedia ? "pause" : "play", primary: true)
                transport("forward.end.fill", label: "Next", action: "nexttrack", supported: state.hasNext)
            }.frame(maxWidth: .infinity)
            if actionFailed && !transportOnly { Text("Use the player on the website for this action.").font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: state.id) { seeking = false; seekSessionID = nil; actionFailed = false }
    }
    @ViewBuilder private var progress: some View {
        if state.isLive {
            ZStack {
                Capsule().fill(.tint).frame(height: 6)
                    .mask {
                        HStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 16)
                            Color.clear.frame(width: 32)
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 16)
                            Color.black
                        }
                    }
                Text("LIVE").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live media")
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
    private func transport(_ symbol: String, label: String, action: String, primary: Bool = false, supported: Bool = true) -> some View {
        Button { perform(action) } label: {
            Image(systemName: symbol).font(.system(size: primary ? 22 : 14))
                .contentTransition(.identity)
                .foregroundStyle(supported ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(actionPending || !supported).help(actionFailed ? L10n.string("Use the player on the website for this action.") : L10n.string(label)).accessibilityLabel(label)
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

/// Both presentations share URL cache, loading priority and fallback sizing.
struct MediaArtworkView: View {
    let page: TabPage
    var circular = false
    @State private var artwork: NSImage?
    @State private var loadedURL: URL?
    @State private var failedURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private var state: TabMediaState { page.mediaState }
    var body: some View {
        let url = state.artworkURL
        let image = url.flatMap { page.mediaArtwork.cached($0) } ?? (loadedURL == url ? artwork : nil)
        let phase = MediaImagePresentation.phase(hasArtworkURL: url != nil, hasImage: image != nil, failed: url != nil && failedURL == url)
        return ZStack {
            RoundedRectangle(cornerRadius: circular ? 22 : 6).fill(.quaternary.opacity(0.3))
            if phase == .artwork, let image {
                if circular {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 44, height: 44).clipShape(Circle())
                        .id(url).transition(.opacity)
                } else {
                let size = MediaImagePresentation.fitted(image.size)
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .id(url).transition(.opacity)
                }
            } else if phase == .loading || (!circular && page.favicon == nil && page.faviconLoading) {
                ProgressView().controlSize(.small).transition(.opacity)
            } else if !circular, let favicon = page.favicon {
                let size = MediaImagePresentation.faviconSize(favicon, scale: displayScale)
                Image(nsImage: favicon).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height).transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(.tertiary)
            }
        }.frame(width: circular ? 44 : 112, height: circular ? 44 : 64)
            .clipShape(RoundedRectangle(cornerRadius: circular ? 22 : 6)).accessibilityHidden(true)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: phase)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page.faviconLoading)
        .task(id: state.artworkURL) {
            if loadedURL != state.artworkURL { artwork = nil; loadedURL = nil; failedURL = nil }
            guard let url = state.artworkURL else { return }
            let image = await page.mediaArtwork.load(url)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                artwork = image; loadedURL = url
                if image == nil { failedURL = url }
            }
        }
    }
}
