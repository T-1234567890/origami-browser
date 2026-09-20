import SwiftUI

enum FloatingMediaPreference {
    static let key = "media.floatingControlEnabled"
}

/// The popover and floating surface use the same application-wide session order.
@MainActor enum MediaSessionSelection {
    static func pages(in store: BrowserStore) -> [TabPage] {
        let windows = store.application.map { Array($0.stores.values) } ?? [store]
        return ordered(windows.flatMap { window in
            window.session.tabs.compactMap { window.loadedPage(for: $0.id) }
        })
    }

    static func ordered(_ pages: [TabPage]) -> [TabPage] {
        pages.filter { $0.mediaState.isRelevant }.sorted {
            if $0.mediaState.activityAt != $1.mediaState.activityAt {
                return $0.mediaState.activityAt > $1.mediaState.activityAt
            }
            return $0.tabID.uuidString < $1.tabID.uuidString
        }
    }
}

enum FloatingMediaPresentation {
    static func progress(_ state: TabMediaState) -> Double? {
        guard state.isRelevant else { return nil }
        if state.isLive { return 1 }
        guard let duration = state.duration, let time = state.currentTime,
              duration.isFinite, time.isFinite, duration > 0 else { return nil }
        return min(1, max(0, time / duration))
    }
    static func trailingCorner(startTrailing: Bool, translation: CGFloat, width: CGFloat) -> Bool {
        (startTrailing ? width : 0) + translation >= width / 2
    }
}

struct FloatingMediaControl: View {
    let store: BrowserStore
    @AppStorage(FloatingMediaPreference.key) private var enabled = false
    @AppStorage("media.floatingControlTrailing") private var trailing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let showsWebContent = store.visiblePage.map { $0.nativePage == nil } ?? false
            let page = enabled && showsWebContent ? MediaSessionSelection.pages(in: store).first : nil
            ZStack(alignment: trailing ? .bottomTrailing : .bottomLeading) {
                if let page {
                    FloatingMediaPanel(page: page, trailing: trailing)
                        .id(page.tabID)
                        .offset(x: drag.width, y: min(0, max(-geometry.size.height + 80, drag.height)))
                        .simultaneousGesture(DragGesture(minimumDistance: 8)
                            .updating($drag) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                trailing = FloatingMediaPresentation.trailingCorner(startTrailing: trailing,
                                    translation: value.translation.width, width: max(1, geometry.size.width - 80))
                            })
                        .transition(.opacity)
                        .padding(12)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: trailing ? .bottomTrailing : .bottomLeading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page?.tabID)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: trailing)
        }
    }
}

private struct FloatingMediaPanel: View {
    let page: TabPage
    let trailing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.profileAppearance) private var appearance
    @State private var hovered = false
    @State private var expanded = false
    // Clicking keeps the controls available for keyboard/accessibility users.
    @State private var pinned = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 28, style: .continuous) }

    var body: some View {
        HStack(spacing: 0) {
            if trailing { controls }
            Button {
                pinned.toggle()
                expanded = pinned || hovered
            } label: {
                MediaArtworkView(page: page, circular: true)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Circle().strokeBorder(appearance.accent.opacity(0.2), lineWidth: 2)
                        if let progress = FloatingMediaPresentation.progress(page.mediaState) {
                            Circle().trim(from: 0, to: progress)
                                .stroke(appearance.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90)).padding(1)
                                .animation(reduceMotion || !page.mediaState.isPlayingMedia ? nil : .linear(duration: 0.8), value: progress)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Show media controls")
            .accessibilityLabel("Show media controls")
            .accessibilityValue(expanded ? L10n.string("Expanded") : L10n.string("Collapsed"))

            if !trailing { controls }
        }
        // The row never compresses. Reveal it from the artwork's anchored edge
        // instead of animating an HStack child and its parent's width together.
        .frame(width: 196, height: 48)
        .frame(width: expanded ? 196 : 48, height: 48, alignment: trailing ? .trailing : .leading)
        .clipped()
        .padding(4)
        .background {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26, *), appearance.glass != "Reduced" {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .contentShape(shape)
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: expanded)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                // Test the visible capsule, not the unclipped row or docking frame.
                let bounds = CGRect(x: 0, y: 0, width: expanded ? 204 : 56, height: 56)
                let inside = shape.path(in: bounds).contains(location)
                hovered = inside
                if inside { expanded = true }
                else { pinned = false }
            case .ended:
                hovered = false
                pinned = false
            }
        }
        .task(id: hovered) {
            guard !hovered else { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, !hovered, !pinned else { return }
            expanded = false
        }
        .onExitCommand { pinned = false; expanded = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating Media Control")
        // Keep the outer docking geometry fixed during the entire animation.
        .frame(width: 204, height: 56, alignment: trailing ? .trailing : .leading)
    }
    private var controls: some View {
        MediaSessionControls(page: page, showsArtwork: false, transportOnly: true)
            .frame(width: 136, height: 48)
            .frame(width: 148, height: 48)
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
    }

}
