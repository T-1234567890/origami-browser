import SwiftUI
import WebKit

/// Two native information layers in one fixed-size preview; no AI dependencies.
struct PeekCard: View {
    @Environment(\.profileAppearance) private var appearance
    let page: TabPage
    let url: URL
    let viewport: CGSize
    let mode: PeekMode
    let open: () -> Void
    let dismiss: () -> Void
    let swiping: (Bool) -> Void
    @State private var layer: PeekLayer
    @State private var preview: PeekPreview
    @State private var loading = true
    @State private var travel: CGFloat = 0
    @State private var hero: NSImage?
    @State private var assets = MediaArtworkService()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    init(page: TabPage, url: URL, viewport: CGSize, mode: PeekMode, open: @escaping () -> Void, dismiss: @escaping () -> Void, swiping: @escaping (Bool) -> Void) {
        self.page = page; self.url = url; self.viewport = viewport; self.mode = mode
        self.open = open; self.dismiss = dismiss; self.swiping = swiping
        _layer = State(initialValue: mode.initialLayer); _preview = State(initialValue: PeekPreview(url: url))
    }
    private var documentType: String? { PeekPreview.documentType(url) ?? PeekPreview.documentType(mime: page.responseDetails?.mime) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                layerButton("Preview", .normal)
                layerButton("Details", .structured)
                Spacer(minLength: 0)
                Button(action: open) { Image(systemName: "arrow.up.right").frame(width: 24, height: 24) }
                    .help("Open in a new tab").accessibilityLabel("Open preview in a new tab")
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .help("Close Peek").accessibilityLabel("Close Peek")
            }.buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8).frame(height: PeekLayout.headerHeight)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Group {
                        if documentType == nil {
                            let size = PeekLayout.previewSize(viewport: viewport,
                                available: CGSize(width: max(0, geometry.size.width - PeekLayout.contentInset * 2), height: max(0, geometry.size.height - PeekLayout.contentInset * 2)))
                            PeekThumbnail(page: page, viewport: viewport)
                                .frame(width: size.width, height: size.height)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        } else { content(structured: false) }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityHidden(layer != .normal).allowsHitTesting(layer == .normal)
                    content(structured: true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(layer != .structured).allowsHitTesting(layer == .structured)
                }
                .offset(x: (layer == .normal ? 0 : -geometry.size.width) + (reduceMotion ? 0 : boundedTravel(width: geometry.size.width)))
            }.clipped()
        }
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)) }
            else if #available(macOS 26, *), appearance.glass != "Reduced" {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 10))
            } else { RoundedRectangle(cornerRadius: 10).fill(.regularMaterial) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.16), lineWidth: 0.5).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .background(PeekSwipeMonitor(activity: swiping) { x, y, ended in
            if ended { finishSwipe(x, y) } else { travel = abs(x) > abs(y) * 1.4 ? x : 0 }
        })
        .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { value in
            swiping(true)
            travel = abs(value.translation.width) > abs(value.translation.height) * 1.4 ? value.translation.width : 0
        }.onEnded { value in
            finishSwipe(value.translation.width, value.translation.height)
            swiping(false)
        })
        .onChange(of: mode) { _, mode in switchLayer(mode.initialLayer) }
        .task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, loading else { return }
            loading = false
            if documentType == nil { page.webView.stopLoading() }
        }
        .task(id: "\(page.isLoading)-\(page.webView.url?.absoluteString ?? url.absoluteString)-\(documentType ?? "page")") {
            if let destination = page.webView.url, LinkPeekObserver.isVideoLink(destination) {
                dismiss(); return
            }
            if let documentType {
                let result = await PeekExtraction.document(PeekPreview.destinationURL(loaded: page.webView.url, requested: url), type: documentType)
                guard !Task.isCancelled else { return }; preview = result; loading = false
            } else {
                guard !page.isLoading else { return }
                // A second bounded pass covers metadata added just after DOM load.
                for delay in [0, 700] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    guard !Task.isCancelled else { return }
                    let result = await PeekExtraction.page(page, url: url)
                    guard !Task.isCancelled else { return }; preview = result; loading = false
                }
            }
        }
        .task(id: preview.imageURL) {
            hero = nil
            guard let imageURL = preview.imageURL else { return }
            let image = await assets.load(imageURL)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { hero = image }
        }
    }
    private func boundedTravel(width: CGFloat) -> CGFloat {
        layer == .normal ? max(-width, min(0, travel)) : min(width, max(0, travel))
    }
    private func finishSwipe(_ x: CGFloat, _ y: CGFloat) {
        switchLayer(layer.moved(horizontal: x, vertical: y))
    }
    private func switchLayer(_ next: PeekLayer) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) { layer = next; travel = 0 }
    }
    private func layerButton(_ title: String, _ value: PeekLayer) -> some View {
        Button { switchLayer(value) } label: {
            Text(title).padding(.horizontal, 7).padding(.vertical, 4)
                .background(layer == value ? Color.primary.opacity(0.08) : .clear, in: Capsule())
        }.accessibilityAddTraits(layer == value ? [.isSelected] : [])
            .help(value == .structured ? "Swipe horizontally for details" : "Show normal preview")
    }
    private func content(structured: Bool) -> some View {
        ZStack {
          if loading {
            ProgressView().controlSize(.small).accessibilityLabel("Loading preview")
          } else if structured && !preview.hasDetails {
            Text("No information available.").font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(12)
          } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 7) {
                    if let icon = page.favicon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 26, height: 26).accessibilityHidden(true)
                    } else {
                        Image(systemName: preview.fileType == nil ? "globe" : "doc.text").font(.system(size: 22)).frame(width: 26, height: 26).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preview.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Text(preview.source).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let file = preview.fileType {
                    HStack(spacing: 6) {
                        Text(file)
                        if let count = preview.pageCount { Text("\(count) pages") }
                        if let size = preview.fileSize { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                if structured {
                    if !preview.author.isEmpty { Label(preview.author, systemImage: "person").font(.system(size: 10, weight: .medium)) }
                    if let date = preview.formattedDate { Label(date, systemImage: "calendar").font(.system(size: 10)).foregroundStyle(.secondary) }
                    HStack(spacing: 6) {
                        if !preview.category.isEmpty { Label(preview.categoryTitle, systemImage: preview.categorySymbol).lineLimit(1) }
                        if let minutes = preview.minutes { Label("~\(minutes) min read", systemImage: "clock") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !preview.overview.isEmpty {
                    Text(preview.overview).font(.system(size: 11)).lineLimit(structured ? 5 : 3)
                }
                if structured && !preview.headings.isEmpty {
                    Text("On this page").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(preview.headings.enumerated()), id: \.offset) { _, title in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("•").accessibilityHidden(true)
                            Text(title).lineLimit(2)
                        }.font(.system(size: 11))
                    }
                }
                if let hero {
                    let size = PeekPreview.imageSize(hero.size)
                    Image(nsImage: hero).resizable().scaledToFit().frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                }

            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
          }.scrollIndicators(.hidden)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Receive two-finger horizontal scrolling without stealing vertical content scrolling.
struct PeekSwipeMonitor: NSViewRepresentable {
    let activity: (Bool) -> Void
    let swipe: (CGFloat, CGFloat, Bool) -> Void
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.swipe = swipe; view.activity = activity }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.removeMonitor() }
    final class Monitor: NSView {
        var swipe: ((CGFloat, CGFloat, Bool) -> Void)?
        var activity: ((Bool) -> Void)?
        private var token: Any?
        private var x: CGFloat = 0, y: CGFloat = 0
        private var axis: Bool?
        private var active = false
        private var owned = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func removeMonitor() { if let token { NSEvent.removeMonitor(token) }; token = nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); removeMonitor()
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let inside = self.bounds.contains(self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
                if !event.momentumPhase.isEmpty { return self.owned && self.axis == true ? nil : event }
                if event.phase.contains(.began) || event.phase.isEmpty || !self.active {
                    self.x = 0; self.y = 0; self.axis = nil
                    self.owned = inside; self.active = true
                }
                guard self.owned else { return event }
                self.x += event.scrollingDeltaX; self.y += event.scrollingDeltaY
                if self.axis == nil && max(abs(self.x), abs(self.y)) > 0 {
                    self.axis = abs(self.x) > abs(self.y) * 1.4
                }
                let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.phase.isEmpty
                if ended { self.active = false }
                if self.axis == true {
                    self.activity?(!ended)
                    self.swipe?(event.phase.contains(.cancelled) ? 0 : self.x, self.y, ended)
                    return nil
                }
                return event
            }
        }
        deinit { if let token { NSEvent.removeMonitor(token) } }
    }
}
