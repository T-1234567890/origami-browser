import SwiftUI
import WebKit
import Observation

@MainActor @Observable final class WebHighlighterController: NSObject, WKScriptMessageHandler {
    struct Selection: Decodable {
        let anchor: HighlightAnchor
        let token: Int
        let existingID: UUID?
        let x: Double
        let y: Double
    }
    var selection: Selection?
    var error: String?
    var supported = true
    var busy = false
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var manager: HighlightManager?
    @ObservationIgnored var profile = BrowserProfile.defaultID
    @ObservationIgnored var allowed: (() -> Bool)?
    @ObservationIgnored private var documentID: String?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var records: [HighlightRecord] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func install(on webView: WKWebView, manager: HighlightManager?, profile: UUID) {
        self.webView = webView; self.manager = manager; self.profile = profile
        guard manager != nil else { return }
        let controller = webView.configuration.userContentController
        controller.add(self, contentWorld: HighlightScript.world, name: "origamiHighlight")
        controller.addUserScript(WKUserScript(source: HighlightScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: HighlightScript.world))
    }
    func reset() { selection = nil; error = nil; documentID = nil; url = nil; records = []; refreshTask?.cancel() }
    func dispose() {
        reset()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "origamiHighlight", contentWorld: HighlightScript.world)
        webView = nil; manager = nil; allowed = nil
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, allowed?() == true, let manager,
              let body = message.body as? [String: Any], let text = body["url"] as? String,
              let url = URL(string: text), HighlightStore.pageKey(url) != nil,
              webView?.url == url, message.frameInfo.request.url?.host == url.host,
              let document = body["documentID"] as? String, UUID(uuidString: document) != nil else { return }
        if body["kind"] as? String == "ready" {
            reset(); self.documentID = document; self.url = url
            supported = body["supported"] as? Bool == true; refresh(); return
        }
        guard documentID == document, self.url == url else { return }
        if body["kind"] as? String == "hide" { selection = nil; return }
        guard manager.enabled, supported, body["kind"] as? String == "selection",
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 80000,
              let selected = try? JSONDecoder().decode(Selection.self, from: data), selected.anchor.valid,
              selected.x.isFinite, selected.y.isFinite, (0...1).contains(selected.x), (0...1).contains(selected.y) else { selection = nil; return }
        selection = selected; error = nil
        if body["commit"] as? Bool == true {
            let tool = manager.tool
            Task { [weak self] in
                guard let self, self.selection?.token == selected.token, manager.tool == tool, manager.enabled else { return }
                switch tool {
                case .off: break
                case .highlight: await self.apply(style: manager.style, expectedTool: tool)
                case .eraser:
                    if selected.existingID != nil { await self.apply(style: nil, remove: true, expectedTool: tool) }
                }
            }
        }
    }
    func refresh() {
        refreshTask?.cancel(); selection = nil
        guard allowed?() == true, let webView, let manager else { return }
        guard let url, let documentID, webView.url == url else {
            // Native/internal history can temporarily detach a still-live webpage. Ask its
            // isolated world to identify itself again rather than retaining a stale selection.
            refreshTask = Task { [weak webView] in
                guard !Task.isCancelled, let webView else { return }
                _ = try? await webView.callAsyncJavaScript("window.__origamiHighlighter?.resume()", arguments: [:], in: nil, contentWorld: HighlightScript.world)
            }
            return
        }
        guard supported else { return }
        do {
            records = try manager.store.records(url: url, profile: profile)
            let objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
            let value: [String: Any] = ["documentID": documentID, "url": url.absoluteString, "enabled": manager.enabled && manager.tool != .off, "erasing": manager.tool == .eraser, "records": manager.enabled ? objects : []]
            refreshTask = Task { [weak self, weak webView] in
                guard !Task.isCancelled, let webView else { return }
                do { _ = try await webView.callAsyncJavaScript("window.__origamiHighlighter?.configure(value)", arguments: ["value": value], in: nil, contentWorld: HighlightScript.world) }
                catch { if !Task.isCancelled { self?.error = "Highlights couldn’t be displayed on this page." } }
            }
        } catch { self.error = "Saved highlights couldn’t be loaded." }
    }
    func apply(style: HighlightStyle?, remove: Bool = false, expectedTool: HighlightTool? = nil) async {
        guard !busy, let selected = selection, let manager, manager.enabled, allowed?() == true,
              let webView, let url, let documentID, webView.url == url else { return }
        busy = true; defer { busy = false }
        do {
            let raw = try await webView.callAsyncJavaScript("return window.__origamiHighlighter?.snapshot(token) ?? null", arguments: ["token": selected.token], in: nil, contentWorld: HighlightScript.world)
            guard self.documentID == documentID, self.url == url, webView.url == url, manager.enabled,
                  expectedTool == nil || manager.tool == expectedTool,
                  let raw = raw as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: raw),
                  let verified = try? JSONDecoder().decode(Selection.self, from: data), verified.anchor == selected.anchor,
                  verified.token == selected.token, verified.existingID == selected.existingID else { selection = nil; return }
            if let id = selected.existingID, var record = records.first(where: { $0.id == id }) {
                if remove { try manager.store.remove(id, url: url.absoluteString, profile: profile) }
                else { record.style = style ?? manager.style; try manager.store.save(record, profile: profile) }
            } else if !remove {
                let record = HighlightRecord(url: url.absoluteString, pageTitle: String((webView.title ?? "").prefix(300)), anchor: selected.anchor, style: style ?? manager.style)
                try manager.store.save(record, profile: profile)
            }
            manager.revision += 1; refresh()
        } catch { self.error = "The highlight couldn’t be saved. Try selecting the text again." }
    }
}

struct WebHighlighterToolbar: View {
    @Environment(\.profileAppearance) private var appearance
    let controller: WebHighlighterController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let manager = controller.manager, manager.enabled {
                HStack(spacing: 6) {
                    toolButton("Highlighter", symbol: "highlighter", tool: .highlight, manager: manager)
                    toolButton("Eraser", symbol: "eraser", tool: .eraser, manager: manager)
                    Divider().frame(height: 16).padding(.horizontal, 2)
                    ForEach(HighlightStyle.allCases) { style in
                        Button { manager.style = style } label: {
                            Circle().fill(color(style)).frame(width: 16, height: 16)
                                .overlay {
                                    if manager.style == style { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.7)) }
                                }.frame(width: 24, height: 26).contentShape(Circle())
                        }.help(style.title).accessibilityLabel(style.title + " highlight")
                            .accessibilityAddTraits(manager.style == style ? .isSelected : [])
                    }
                }
                .buttonStyle(.plain).font(.system(size: 13)).padding(.horizontal, 8).padding(.vertical, 4)
                .background {
                    if reduceTransparency { Capsule().fill(Color(nsColor: .windowBackgroundColor)) }
                    else if #available(macOS 26, *), appearance.glass != "Reduced" {
                        Color.clear.glassEffect(.regular, in: .capsule)
                    } else { Capsule().fill(.regularMaterial) }
                }
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .disabled(controller.busy || !controller.supported)
                .padding(.bottom, 12)
                .accessibilityElement(children: .contain).accessibilityLabel("Highlighter tools")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.manager?.enabled, initial: true) { controller.refresh() }
        .onChange(of: controller.manager?.tool) { controller.refresh() }
        .onChange(of: controller.manager?.revision) { controller.refresh() }
        .popover(isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.error ?? "")
                Button("Done") { controller.error = nil }
            }.padding(16).frame(width: 260)
        }
    }
    private func toolButton(_ title: String, symbol: String, tool: HighlightTool, manager: HighlightManager) -> some View {
        Button { manager.tool = manager.tool == tool ? .off : tool } label: {
            Image(systemName: symbol).frame(width: 26, height: 26)
                .foregroundStyle(manager.tool == tool ? appearance.accent : ((appearance.scheme ?? scheme) == .dark ? Color.white : Color.black))
                .background(manager.tool == tool ? appearance.accent.opacity(0.14) : .clear, in: Circle())
                .contentShape(Circle())
        }.help(title).accessibilityLabel(title)
            .accessibilityValue(manager.tool == tool ? "On" : "Off")
            .accessibilityAddTraits(manager.tool == tool ? .isSelected : [])
    }
    private func color(_ style: HighlightStyle) -> Color {
        switch style {
        case .yellow: Color(red: 0.86, green: 0.72, blue: 0.35)
        case .mint: Color(red: 0.38, green: 0.68, blue: 0.58)
        case .lavender: Color(red: 0.64, green: 0.54, blue: 0.78)
        }
    }
}

struct WebHighlighterSettings: View {
    @Bindable var manager: HighlightManager
    var body: some View {
        Section("Highlighter") {
            Toggle("Highlighter", isOn: $manager.enabled)
            Picker("Default highlight style", selection: $manager.style) {
                ForEach(HighlightStyle.allCases) { Text($0.title).tag($0) }
            }
            Text("Use the bottom panel to enable highlighting or erasing, then select text. Click a saved highlight to erase it. Turning Highlighter off hides saved highlights without deleting them. Private highlights last only for that private window.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
