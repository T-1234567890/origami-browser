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
                .onAppear { delegate.application = application }
        } defaultValue: {
            application.initialID
        }
        // SQLite owns normal-window restoration; SwiftUI must not archive private scenes.
        .restorationBehavior(.disabled)
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands { BrowserCommands(application: application); UpdateCommands() }
    }
}

private struct BrowserWindowRoot: View {
    let application: BrowserApplicationContext
    @Binding var identity: UUID
    @State private var initialStore: BrowserStore
    private var store: BrowserStore { state.profileStore ?? initialStore }
    @State private var state = BrowserWindowState()
    @Environment(\.openWindow) private var openWindow
    init(application: BrowserApplicationContext, identity: Binding<UUID>) {
        self.application = application; _identity = identity
        _initialStore = State(initialValue: application.resolve(identity.wrappedValue))
    }
    var body: some View {
        ContentView(store: store, windowState: state)
            .id(store.session.windowID)
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
                // Finish tab persistence and view updates before using the normal window-close path.
                DispatchQueue.main.async {
                    guard store.session.tabs.isEmpty else { return }
                    state.window?.performClose(nil)
                }
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
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { browser().openInternal(.settings) }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { if let store { store.newTab() } else { _ = browser() } }.keyboardShortcut("t")
            Button("New Private Window") { if let new = application.newPrivateWindow(), application.openWindow == nil { openWindow(id: "browser", value: new.session.windowID) } }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Window") { let new = application.newWindow(); if application.openWindow == nil { openWindow(id: "browser", value: new.session.windowID) } }.keyboardShortcut("n")
            Button("Reopen Closed Tab") { browser().reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(store?.recentlyClosed.isEmpty != false)
            Button("Reopen Closed Window") { application.reopenWindow() }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { if let id = store?.session.selectedTabID { store?.close(id) } }.keyboardShortcut("w").disabled(store?.selectedTab == nil)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        if BrowserFeatureFlags.compactSidebar {
            CommandMenu("View") {
                Button("Toggle Compact Sidebar") { store?.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .disabled(store?.session.layout != .vertical)
            }
        }
        CommandMenu("Navigate") {
            Button("Open Location…") { browser().focusOmnibox() }.keyboardShortcut("l")
            Button("Reload") { store?.selectedPage?.reload() }.keyboardShortcut("r")
                .disabled(store?.selectedTab == nil)
            Button("Reload Without Cache") { store?.visiblePage?.reload(withoutCache: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store?.visiblePage?.nativePage != nil || store?.visiblePage == nil)
            Button("Stop Loading") { store?.selectedPage?.webView.stopLoading() }.keyboardShortcut(".")
            Button("Back") { store?.selectedPage?.goBack() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(store?.visiblePage?.canGoBack != true)
            Button("Forward") { store?.selectedPage?.goForward() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(store?.visiblePage?.canGoForward != true)
            Button("Next Tab") { store?.cycleTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { store?.cycleTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Paste and Go") { if let text = NSPasteboard.general.string(forType: .string) { browser().navigate(text) } }
            Button("Paste and Search") { if let text = NSPasteboard.general.string(forType: .string) { browser().navigate(text, searchOnly: true) } }
        }
        CommandMenu("Develop") {
            Button("Inspect in Safari…") { store?.inspectInSafari() }.disabled(store?.visiblePage == nil || store?.visiblePage?.nativePage != nil)
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Reload Without Cache") { store?.visiblePage?.reload(withoutCache: true) }
                .disabled(store?.visiblePage == nil || store?.visiblePage?.nativePage != nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find on Page…") { store?.showingFind = true }.keyboardShortcut("f")
                .disabled(store?.visiblePage == nil || store?.visiblePage?.nativePage != nil)
        }
        CommandMenu("Browse") {
            Button("Close Peek") { store?.dismissPeek() }.keyboardShortcut(.escape, modifiers: []).disabled(store?.peekPage == nil)
            Button("Reader Mode") { store?.visiblePage?.readerVisible.toggle() }.disabled(store?.visiblePage?.article == nil)
            Button("JSON Reader") { store?.visiblePage?.readerVisible = false; store?.visiblePage?.showsJSON = true }.disabled(store?.visiblePage?.jsonText == nil)
        }
        CommandMenu("Library") {
            Button("References") { browser().openInternal(.references) }
            Button("Websites I Follow") { browser().openInternal(.feeds) }
            Button("History") { browser().openInternal(.history) }.keyboardShortcut("y")
            Button("Bookmarks") { browser().openInternal(.bookmarks) }.keyboardShortcut("b", modifiers: [.command, .option])
            Button("Bookmark This Tab") { store?.bookmarkCurrentTab() }.keyboardShortcut("d")
            Button("Bookmark All Tabs…") { store?.bookmarkTabs(store?.session.tabs ?? [], name: "Saved Tabs") }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Show/Hide Bookmark Bar") { store?.toggleBookmarkBar() }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Downloads") { browser().openInternal(.downloads) }.keyboardShortcut("j", modifiers: [.command, .option])
            Button("Website Data") { browser().openInternal(.data) }
            Button("Profiles") { browser().openInternal(.profiles) }
        }
    }
}

@MainActor
final class BrowserApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var application: BrowserApplicationContext?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        application?.globalControls?.stop()
        application?.quitting = true
        application?.stores.values.forEach { $0.save() }
        return .terminateNow
    }
}
