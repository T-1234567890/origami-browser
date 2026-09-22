import SwiftUI
import WebKit

@main
struct OrigamiApp: App {
    @NSApplicationDelegateAdaptor(BrowserApplicationDelegate.self) private var delegate
    @State private var application: BrowserApplicationContext
    init() {
        let isolated = ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        _application = State(initialValue: BrowserApplicationContext(isolated: isolated))
    }
    var body: some Scene {
        WindowGroup("Origami", id: "browser", for: UUID.self) { id in
            BrowserWindowRoot(application: application, identity: id)
                .modifier(LiveLanguage())
                .onAppear { delegate.application = application }
        } defaultValue: {
            application.initialID
        }
        // SQLite owns normal-window restoration; SwiftUI must not archive private scenes.
        .restorationBehavior(.disabled)
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands { BrowserCommands(application: application); UpdateCommands(application: application) }
    }
}

private struct BrowserWindowRoot: View {
    let application: BrowserApplicationContext
    @Binding var identity: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var initialStore: BrowserStore
    private var store: BrowserStore { state.profileStore ?? initialStore }
    @State private var state = BrowserWindowState()
    @Environment(\.openWindow) private var openWindow
    init(application: BrowserApplicationContext, identity: Binding<UUID>) {
        self.application = application; _identity = identity
        _initialStore = State(initialValue: application.resolve(identity.wrappedValue))
    }
    var body: some View {
        ZStack {
            ContentView(store: store, windowState: state)
                .id(store.session.windowID)
                .transition(.opacity)
        }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.session.profileID)
            .background(BrowserWindowReader(state: state, layout: store.session.layout, savedFrame: store.session.windowFrame, onboarding: store.isShowingWelcome))
            .task(id: store.session.windowID) {
                identity = store.session.windowID
                if application.activeID == nil { application.activeID = store.session.windowID }
                application.states[store.session.windowID] = state
                application.openWindow = { openWindow(id: "browser", value: $0) }
                store.startLifecycleMonitoring()
                if !ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { application.startGlobalControls() }
            }
            .onChange(of: store.session.tabs.isEmpty, initial: true) { _, empty in
                guard empty else { return }
                state.closeIfEmpty(store)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                state.refreshFocus()
                if let window = notification.object as? NSWindow, window === state.window { application.activeID = store.session.windowID }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in state.refreshFocus() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { saveFrame($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { saveFrame($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let window = notification.object as? NSWindow, window === state.window else { return }
                saveFrame(notification); store.lifecycleTask?.cancel(); application.close(store.session.windowID)
            }
    }
    private func saveFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === state.window, !window.styleMask.contains(.fullScreen), !window.inLiveResize else { return }
        store.updateWindowFrame(NSStringFromRect(window.frame))
    }
}

private struct BrowserCommands: Commands {
    let application: BrowserApplicationContext
    private var store: BrowserStore? { application.activeStore }
    @Environment(\.openWindow) private var openWindow
    private func browser() -> BrowserStore {
        if let store { return store }
        let store = application.newWindow()
        if application.openWindow == nil { openWindow(id: "browser", value: store.session.windowID) }
        return store
    }
    @CommandsBuilder private var pageFileCommands: some Commands {
        CommandGroup(after: .saveItem) {
            Button(L10n.string("Save Page…")) { store?.saveCurrentPage() }
                .disabled(store?.canUsePageFileCommands != true)
        }
        CommandGroup(replacing: .printItem) {
            Button(L10n.string("Print…")) { store?.printCurrentPage() }
                .keyboardShortcut("p")
                .disabled(store?.canUsePageFileCommands != true)
        }
    }
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.string("Settings…")) { browser().openInternal(.settings) }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("New Tab")) { if let store { store.newTab() } else { _ = browser() } }.keyboardShortcut("t")
            Button(L10n.string("New Private Window")) { if let new = application.newPrivateWindow(), application.openWindow == nil { openWindow(id: "browser", value: new.session.windowID) } }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L10n.string("New Window")) { let new = application.newWindow(); if application.openWindow == nil { openWindow(id: "browser", value: new.session.windowID) } }.keyboardShortcut("n")
            Button(L10n.string("Reopen Closed Tab")) { browser().reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(store?.recentlyClosed.isEmpty != false)
            Button(L10n.string("Reopen Closed Window")) { application.reopenWindow() }
        }
        CommandGroup(replacing: .saveItem) {
            Button(L10n.string("Close Tab")) { if let id = store?.session.selectedTabID { store?.close(id) } }.keyboardShortcut("w").disabled(store?.selectedTab == nil)
            Button(L10n.string("Close Window")) { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        pageFileCommands
        CommandMenu(L10n.string("View")) {
            Button(L10n.string("Zoom In")) { store?.visiblePage?.zoom(increasing: true) }
                .keyboardShortcut("+")
                .disabled(store?.visiblePage?.canZoom != true || (store?.visiblePage?.zoomLevel ?? 1) >= 5)
            Button(L10n.string("Zoom Out")) { store?.visiblePage?.zoom(increasing: false) }
                .keyboardShortcut("-")
                .disabled(store?.visiblePage?.canZoom != true || (store?.visiblePage?.zoomLevel ?? 1) <= 0.25)
            Button(L10n.string("Actual Size")) { store?.visiblePage?.resetZoom() }
                .keyboardShortcut("0")
                .disabled(store?.visiblePage?.canZoom != true)
            if BrowserFeatureFlags.compactSidebar {
                Divider()
                Button(L10n.string("Toggle Compact Sidebar")) { store?.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .disabled(store?.session.layout != .vertical)
            }
        }
        CommandMenu(L10n.string("Navigate")) {
            Button(L10n.string("Open Location…")) { browser().focusOmnibox() }.keyboardShortcut("l")
            Button(L10n.string("Reload")) { store?.selectedPage?.reload() }.keyboardShortcut("r")
                .disabled(store?.selectedTab == nil)
            Button(L10n.string("Reload Without Cache")) { store?.visiblePage?.reload(withoutCache: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store?.visiblePage?.nativePage != nil || store?.visiblePage == nil)
            Button(L10n.string("Stop Loading")) { store?.selectedPage?.webView.stopLoading() }.keyboardShortcut(".")
            Button(L10n.string("Back")) { store?.selectedPage?.goBack() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(store?.visiblePage?.canGoBack != true)
            Button(L10n.string("Forward")) { store?.selectedPage?.goForward() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(store?.visiblePage?.canGoForward != true)
            Button(L10n.string("Next Tab")) { store?.cycleTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button(L10n.string("Previous Tab")) { store?.cycleTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button(L10n.string("Paste and Go")) { if let text = NSPasteboard.general.string(forType: .string) { browser().navigate(text) } }
            Button(L10n.string("Paste and Search")) { if let text = NSPasteboard.general.string(forType: .string) { browser().navigate(text, searchOnly: true) } }
        }
        CommandMenu(L10n.string("Develop")) {
            Button(L10n.string("Inspect in Safari…")) { store?.inspectInSafari() }.disabled(store?.visiblePage == nil || store?.visiblePage?.nativePage != nil)
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(L10n.string("Reload Without Cache")) { store?.visiblePage?.reload(withoutCache: true) }
                .disabled(store?.visiblePage == nil || store?.visiblePage?.nativePage != nil)
        }
        CommandGroup(after: .textEditing) {
            Button(L10n.string("Find on Page…")) { store?.showingFind = true }.keyboardShortcut("f")
                .disabled(store?.visiblePage == nil || store?.visiblePage?.nativePage != nil)
        }
        CommandMenu(L10n.string("Browse")) {
            Button(L10n.string("Close Peek")) { store?.dismissPeek() }.keyboardShortcut(.escape, modifiers: []).disabled(store?.peekPage == nil)
            Button(L10n.string("Reader Mode")) { store?.visiblePage?.readerVisible.toggle() }.disabled(store?.visiblePage?.article == nil)
            Button(L10n.string("JSON Reader")) { store?.visiblePage?.readerVisible = false; store?.visiblePage?.showsJSON = true }.disabled(store?.visiblePage?.jsonText == nil)
        }
        CommandMenu(L10n.string("Library")) {
            Button(L10n.string("Websites I Follow")) { browser().openInternal(.feeds) }
            Button(L10n.string("History")) { browser().openInternal(.history) }.keyboardShortcut("y")
            Button(L10n.string("Bookmarks")) { browser().openInternal(.bookmarks) }.keyboardShortcut("b", modifiers: [.command, .option])
            Button(L10n.string("Bookmark This Tab")) { store?.bookmarkCurrentTab() }.keyboardShortcut("d")
            Button(L10n.string("Bookmark All Tabs…")) { store?.bookmarkTabs(store?.session.tabs ?? [], name: "Saved Tabs") }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button(L10n.string("Show/Hide Bookmark Bar")) { store?.toggleBookmarkBar() }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button(L10n.string("Downloads")) { browser().openInternal(.downloads) }.keyboardShortcut("j", modifiers: [.command, .option])
            Button(L10n.string("Website Data")) { browser().openInternal(.data) }
            Button(L10n.string("Profiles")) { browser().openInternal(.profiles) }
        }
    }
}

@MainActor
final class BrowserApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var application: BrowserApplicationContext? {
        didSet { Task { @MainActor in await Task.yield(); self.deliverPendingURLs() } }
    }
    private var pendingURLs: [URL] = []
    func application(_ sender: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") })
        deliverPendingURLs()
    }
    private func deliverPendingURLs() {
        guard let application, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs; pendingURLs.removeAll()
        let store: BrowserStore
        if let active = application.activeStore, !active.isPrivate { store = active }
        else { store = application.newWindow() }
        for url in urls { store.newTab(url: url) }
        application.openWindow?(store.session.windowID)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        application?.globalControls?.stop()
        application?.quitting = true
        application?.stores.values.forEach { $0.save() }
        return .terminateNow
    }
}
