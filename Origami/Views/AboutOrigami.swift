import SwiftUI
import AppKit

private final class AboutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class AboutOrigamiWindow: NSWindowController {
    static let shared = AboutOrigamiWindow()
    private init() {
        let window = AboutPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 490),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = L10n.string("About Origami")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutOrigamiView(open: { _ in }).modifier(LiveLanguage()))
        super.init(window: window)
    }
    required init?(coder: NSCoder) { nil }
    func present(open: @escaping (URL) -> Void) {
        window?.contentView = NSHostingView(rootView: AboutOrigamiView(open: { [weak self] url in
            self?.close(); open(url)
        }).modifier(LiveLanguage()))
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum OrigamiLinks {
    static let website = URL(string: "https://origami.1234567890.dev/")!
    static let repository = URL(string: "https://github.com/T-1234567890/origami-browser")!
    static let terms = website.appending(path: "terms/")
    static let privacy = website.appending(path: "privacy/")
}

struct AboutOrigamiView: View {
    let open: (URL) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let identity = ReleaseIdentity.from(info: Bundle.main.infoDictionary ?? [:])
    var body: some View {
        VStack(spacing: 14) {
            Image("AboutIcon").resizable().scaledToFit().frame(width: 88, height: 88).accessibilityHidden(true)
            Text("Origami").font(.system(size: 26, weight: .semibold))
            VStack(spacing: 4) {
                Text(identity.map { String($0.displayVersion.dropFirst("Origami ".count)) }
                     ?? "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0") — Development")
                Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")").font(.caption)
            }.foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 4)
            VStack(spacing: 10) {
                Button { open(InternalPage.credits.url) } label: { actionLabel("Credits & Licenses", symbol: "text.book.closed") }
                Button { open(OrigamiLinks.terms) } label: { actionLabel("Terms of Service", symbol: "doc.text") }
                Button { open(OrigamiLinks.privacy) } label: { actionLabel("Privacy Policy", symbol: "hand.raised") }
                Button { open(OrigamiLinks.repository) } label: { actionLabel("GitHub Repository", symbol: "chevron.left.forwardslash.chevron.right") }
                Button { open(OrigamiLinks.website) } label: { actionLabel("Website", symbol: "globe") }
            }.buttonStyle(.plain).controlSize(.large)
        }
        .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 28)
        .frame(width: 340, height: 490)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else if #available(macOS 26, *) { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 16)) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .environment(\.locale, L10n.locale)
        .ignoresSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            Button { AboutOrigamiWindow.shared.close() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22).background(.quaternary, in: Circle())
            }.buttonStyle(.plain).padding(12).accessibilityLabel("Close About Origami")
                .keyboardShortcut(.cancelAction)
        }
    }
    private func actionLabel(_ title: String, symbol: String) -> some View {
        Label(L10n.string(title), systemImage: symbol)
            .frame(maxWidth: .infinity).frame(height: 30)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
    }
}

struct CreditDocument: Identifiable {
    let title: String
    let resource: String
    let ext: String
    var id: String { resource }
    func text(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resource, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    static let all = [
        CreditDocument(title: "Third-party notices, Sparkle & filter data", resource: "THIRD_PARTY_NOTICES", ext: "md"),
        CreditDocument(title: "Mozilla Readability notices", resource: "LICENSE", ext: "md"),
        CreditDocument(title: "Apache License 2.0", resource: "Apache-2.0", ext: "txt"),
        CreditDocument(title: "GRDB.swift", resource: "GRDB", ext: "txt"),
        CreditDocument(title: "MarkdownUI", resource: "swift-markdown-ui", ext: "txt"),
        CreditDocument(title: "swift-cmark", resource: "swift-cmark", ext: "txt"),
        CreditDocument(title: "NetworkImage", resource: "NetworkImage", ext: "txt")
    ]
}

struct OrigamiCreditsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Set<String> = []
    var body: some View {
        InternalContent(title: "Credits & Licenses") {
            Text("Open-source component notices and optional downloaded filter-data licenses.").foregroundStyle(.secondary)
            ForEach(CreditDocument.all) { document in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(document.id) },
                    set: { value in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            if value { expanded.insert(document.id) } else { expanded.remove(document.id) }
                        }
                    }
                )) {
                    Text(document.text() ?? L10n.string("This notice is unavailable in this build."))
                        .font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: { Text(L10n.string(document.title)).font(.headline) }
            }
        }
    }
}

/// Only appearance and tab layout are profile-scoped settings; all other
/// settings pages currently change shared preferences.
enum SettingsScope {
    static func label(category: String, profile: BrowserProfile, defaultID: UUID = BrowserProfile.defaultID) -> String? {
        guard profile.id != defaultID else { return nil }
        let kind: ProfileDataKind? = category == "Appearance" ? .appearance : category == "Tabs" ? .layout : nil
        return kind.map { profile.sharing[$0] ? L10n.string("Synchronized with default profile") : profile.name } ?? L10n.string("Synchronized with default profile")
    }
}
