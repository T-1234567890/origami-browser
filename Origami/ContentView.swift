import SwiftUI
import WebKit

struct ContentView: View {
    let store: BrowserStore
    @Bindable var windowState: BrowserWindowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestionAnchor = SuggestionAnchor()
    @State private var sidebarWidth: CGFloat = 240
    @State private var sidebarHover = SidebarHoverState()
    @State private var editingOmnibox = false
    @State private var resizingSidebar = false
    @State private var showingCommands = false
    @State private var sidebarPopover = false
    private var sidebarShown: Bool { vertical && (store.sidebarBehavior == .visible || store.sidebarBehavior == .compact && sidebarHover.isRevealed) }
    private var sidebarInteraction: Bool { editingOmnibox || resizingSidebar || sidebarPopover || windowState.showingPreferences }
    private var showsBookmarks: Bool { _ = store.preferencesRevision; return store.preferences.showBookmarkBar }
    private var remoteSuggestionsAllowed: Bool { _ = store.preferencesRevision; return store.preferences.allowsRemoteSuggestions(isPrivate: store.isPrivate) }
    private var showsContentFrame: Bool { _ = store.preferencesRevision; return Personalization.shared.frame != "Off" || (vertical && Personalization.shared.frameFill) }
    private var onboarding: Bool { store.isShowingWelcome }
    private var vertical: Bool { store.session.layout == .vertical }

    private var contentSurface: some View {
        // The content host stays at the same structural position in both layouts.
        HStack(spacing: 0) {
            // Only Visible reserves space. Hover reveal never changes the content host's frame.
            Color.clear.frame(width: onboarding ? 0 : store.sidebarBehavior.contentInset(layout: store.session.layout, width: sidebarWidth))
            VStack(spacing: 0) {
                if !onboarding && !vertical && windowState.isFullScreen {
                    HStack(spacing: 10) {
                        FullScreenWindowButtons().frame(width: 70, height: 28)
                        horizontalNavigation
                        addressField.frame(maxWidth: .infinity)
                        BrowserLibraryControls(store: store)
                    }.padding(.horizontal, 10).frame(height: 44)
                }
                if !onboarding && !vertical { TabBars(store: store, vertical: false) }
                if !onboarding && showsBookmarks { BookmarkBar(store: store).id(store.preferencesRevision) }
                browserContent
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showingCommands)
        .overlay(alignment: .topTrailing) {
            if store.isPrivate && !onboarding && vertical && !sidebarShown {
                privateBadge
                    .padding(.horizontal, 9).padding(.vertical, 5).background(.regularMaterial, in: Capsule())
                    .padding(8).allowsHitTesting(false).accessibilityLabel("Private browsing window")
            }
        }
        .overlay(alignment: .leading) {
            if vertical && !onboarding {
                verticalSidebar
                    .offset(x: sidebarShown ? 0 : -sidebarWidth)
                    .opacity(sidebarShown ? 1 : 0)
                    .allowsHitTesting(sidebarShown)
                    .accessibilityHidden(!sidebarShown)
                    .onHover { entered in
                        if store.sidebarBehavior == .compact { sidebarHover.sidebarChanged(entered) }
                    }
            }
        }
        .overlay(alignment: .leading) {
            if !onboarding && vertical && store.sidebarBehavior == .compact && !sidebarHover.isRevealed {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { sidebarHover.edgeChanged($0) }
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: sidebarShown)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: vertical)
        .task(id: sidebarHover.pending) {
            guard let transition = sidebarHover.pending else { return }
            do { try await Task.sleep(for: transition.delay) } catch { return }
            guard !Task.isCancelled, vertical, store.sidebarBehavior == .compact else { return }
            sidebarHover.finish(transition)
        }
        .onChange(of: store.sidebarBehavior) {
            sidebarHover.reset()
            if store.sidebarBehavior == .compact && sidebarInteraction {
                sidebarHover.revealForKeyboard()
                sidebarHover.interactionChanged(true)
            }
        }
        .onChange(of: onboarding) {
            sidebarHover.reset()
            windowState.showingPreferences = false
            editingOmnibox = false
            windowState.window?.makeFirstResponder(nil)
        }
        .onChange(of: vertical) { sidebarHover.reset(); editingOmnibox = false }
        .onChange(of: sidebarInteraction) { sidebarHover.interactionChanged(sidebarInteraction) }
        .onChange(of: store.focusRequest) {
            if vertical && store.sidebarBehavior == .compact { sidebarHover.revealForKeyboard() }
        }
        .task(id: store.selectedTab) { store.prepareSelectedPage() }
        .onDisappear { sidebarHover.reset(); store.resolveConfirmation(false) }
        .onChange(of: store.selectedTab?.url) { store.resolveConfirmation(false) }
        .ignoresSafeArea(.container, edges: vertical || onboarding || windowState.isFullScreen ? .top : [])
        .frame(minWidth: 760, minHeight: 500)
        .background {
            // Extend only the backdrop under the titlebar. AppKit owns the window's corner clipping.
            ZStack {
                BrowserChromeBackground()
                if !onboarding && vertical && Personalization.shared.frameFill {
                    Personalization.shared.accentFill.opacity(0.4)
                }
            }.ignoresSafeArea().allowsHitTesting(false)
        }
        .overlay { AISetupPrompt(store: store) }
    }

    var body: some View {
        contentSurface
        .tint(Personalization.shared.accent)
        .background(WindowAppearanceBridge(mode: Personalization.shared.mode))
        .windowToolbarFullScreenVisibility(.visible)
        .toolbar(windowState.isFullScreen ? .hidden : .automatic, for: .windowToolbar)
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            if !vertical && !onboarding {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .navigation) { horizontalNavigation }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { horizontalNavigation }
                }
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .principal) {
                        addressField.frame(minWidth: 240, idealWidth: 480, maxWidth: 680)
                    }
                    // The omnibox already supplies its own capsule material.
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        addressField.frame(minWidth: 240, idealWidth: 480, maxWidth: 680)
                    }
                }
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .automatic) {
                        BrowserLibraryControls(store: store, toolbar: true)
                            .modifier(ChromeSurface()).fixedSize()
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .automatic) { BrowserLibraryControls(store: store, toolbar: true) }
                }
            }
        }
        .onChange(of: store.session.tabs.isEmpty) { wasEmpty, isEmpty in
            if !wasEmpty && isEmpty { windowState.window?.performClose(nil) }
        }
        .onChange(of: store.session.selectedTabID) {
            store.resolveConfirmation(false)
            // End editing before reflecting another tab's address.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .popover(isPresented: Binding(get: { store.confirmationMessage != nil }, set: { if !$0 { store.resolveConfirmation(false) } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text(store.confirmationMessage ?? "").fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { store.resolveConfirmation(false) }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Confirm", role: .destructive) { store.resolveConfirmation(true) }
                }
            }.padding(16).frame(width: 300)
        }
        .popover(isPresented: Binding(get: { store.persistenceError != nil }, set: { if !$0 { store.persistenceError = nil } }), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Browser Notice").font(.headline)
                Text(store.persistenceError ?? "").fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("OK") { store.persistenceError = nil }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 320)
        }
    }
    private var privateBadge: some View {
        Label("Private", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("Private browsing window")
    }
    private var verticalSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if windowState.isFullScreen { FullScreenWindowButtons().frame(width: 70, height: 28) }
                navigationControls
            }
                .frame(maxWidth: .infinity, alignment: windowState.isFullScreen ? .leading : .center)
                 .overlay(alignment: .trailing) {
                    BookmarkPageButton(store: store, iconSize: 14).padding(.trailing, 10)
                }
                .buttonStyle(.plain).frame(height: 30).padding(.bottom, 7)
            addressField.padding(.horizontal, 10).padding(.vertical, 6)
            BrowserLibraryControls(store: store)
            TabBars(store: store, vertical: true, emptySpaceClicked: store.expandSidebarFromEmptySpace,
                    sidebarFooter: AnyView(HStack { settingsButton; Divider().frame(height: 16); commandButton; Spacer() }
                        .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 8)))
        }
        .onPreferenceChange(SidebarPopoverPreference.self) { sidebarPopover = $0 }
        .padding(.top, 1).frame(width: sidebarWidth)
        .background {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { store.expandSidebarFromEmptySpace() }
        }
        .background {
            if store.sidebarBehavior != .visible {
                BrowserChromeBackground(blendingMode: .withinWindow)
            }
        }
        .overlay(alignment: .trailing) {
            SidebarResizeHandle(width: $sidebarWidth, resizingChanged: { resizingSidebar = $0 }).frame(width: 8).frame(maxHeight: .infinity)
        }
    }

    private var horizontalNavigation: some View {
        HStack(spacing: 8) {
            settingsButton
            Divider().frame(height: 16)
            commandButton
            navigationControls
            if store.isPrivate { privateBadge }
        }
        .buttonStyle(.plain).font(.system(size: 14)).fixedSize()
    }

    private var navigationControls: some View {
        Group {
            Button { store.visiblePage?.goBack() } label: { Image(systemName: "chevron.left").frame(width: 20, height: 24) }
                .disabled(store.visiblePage?.canGoBack != true).help("Back (⌘⌥←)").accessibilityLabel("Back")
            Button { store.visiblePage?.goForward() } label: { Image(systemName: "chevron.right").frame(width: 20, height: 24) }
                .disabled(store.visiblePage?.canGoForward != true).help("Forward (⌘⌥→)").accessibilityLabel("Forward")
            Button {
                if store.visiblePage?.isLoading == true { store.visiblePage?.webView.stopLoading() }
                else { store.visiblePage?.reload() }
            } label: {
                Image(systemName: store.visiblePage?.isLoading == true ? "xmark" : "arrow.clockwise").frame(width: 20, height: 24)
            }
            .disabled(store.selectedTab?.url == nil)
            .help(store.visiblePage?.isLoading == true ? "Stop Loading" : "Reload (⌘R)")
            .accessibilityLabel(store.visiblePage?.isLoading == true ? "Stop Loading" : "Reload")
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Omnibox(store: store, allowRemote: remoteSuggestionsAllowed, tabID: store.session.selectedTabID, value: store.selectedTab?.url?.absoluteString ?? "", focusRequest: store.focusRequest, canFocus: !vertical || sidebarShown, suggestionAnchor: suggestionAnchor, editingChanged: { editingOmnibox = $0 }) {
                store.navigate($0, searchOnly: $1)
            }.frame(height: 18)
            if !vertical { BookmarkPageButton(store: store) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .modifier(ChromeSurface())
        .background(SuggestionAnchorView(anchor: suggestionAnchor))
    }

    private var commandButton: some View {
        Button { showingCommands.toggle() } label: {
            Image(systemName: "command").font(.system(size: 14)).frame(width: 20, height: 24)
        }.help("Quick Tools").accessibilityLabel("Quick Tools").keyboardShortcut("k", modifiers: [.command, .shift])
        .popover(isPresented: $showingCommands) { QuickTools(store: store) { showingCommands = false } }
    }

    private var settingsButton: some View {
        Button { windowState.showingPreferences.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 20, height: 24)
        }
        .help("Browser Settings").accessibilityLabel("Browser Settings").accessibilityIdentifier("tabLayoutMenu")
        .popover(isPresented: $windowState.showingPreferences, arrowEdge: vertical ? .bottom : .top) { BrowserSettings(store: store) }
    }

    private var browserContent: some View {
        BrowsingExperienceView(store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(store.session.activeSplit == nil ? Color(nsColor: .textBackgroundColor) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: onboarding ? 0 : BrowserChromeMetrics.contentCornerRadius))
            .overlay(alignment: .topTrailing) {
                if store.showingFind, let page = store.visiblePage, page.nativePage == nil {
                    PageFindBar(page: page) { store.showingFind = false }.id(page.tabID).padding(12)
                }
            }
            .padding(onboarding || (!showsContentFrame && store.session.activeSplit == nil) ? 0 : BrowserChromeMetrics.contentFrameWidth)

    }

}

struct BrowserContentView: View {
    let store: BrowserStore
    var tabID: UUID? = nil
    private var tab: BrowserTab? { tabID.flatMap { id in store.session.tabs.first { $0.id == id } } ?? store.selectedTab }
    private var page: TabPage? { tab.flatMap { store.loadedPage(for: $0.id) } }
    var body: some View {
        if let tab, let page {
            ZStack(alignment: .top) {
                if let destination = page.nativePage {
                    NativeInternalSurface(store: store, destination: destination, tabID: tab.id)
                        .id("\(tab.id)-\(destination.rawValue)-\(page.nativeRevision)")
                } else if page.readerVisible, let article = page.article {
                    ReaderView(article: article, url: page.currentURL, userAgent: page.webView.customUserAgent) { page.readerVisible = false }
                        .environment(\.openURL, OpenURLAction { url in
                            guard ["http", "https"].contains(url.scheme) else { return .discarded }
                            store.newTab(url: url); return .handled
                        })
                } else if page.showsJSON, let json = page.jsonText {
                    JSONReaderView(raw: json, details: page.responseDetails) { page.showsJSON = false }
                } else {
                    WebViewContainer(webView: page.webView, dismissDialog: page.dismissDialog, activated: { if store.session.activeSplit != nil { store.select(tab.id) } })
                        .overlay(alignment: .topTrailing) {
                            if page.jsonText != nil && !page.showsJSON {
                                Button { page.showsJSON = true } label: {
                                    Label("JSON Reader", systemImage: "curlybraces")
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding(12)
                                .help("Return to formatted JSON without reloading")
                            }
                        }
                }
                if page.isLoading { PageLoadingIndicator(progress: page.progress).id(tab.id) }
                if let message = page.errorMessage {
                    ContentUnavailableView {
                        Label("Unable to Open Page", systemImage: "exclamationmark.triangle")
                    } description: { Text(message) } actions: {
                        Button("Try Again") { if let url = tab.url { page.load(url) } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                }
            }
        } else if let tab, tab.isSleeping == true {
            ContentUnavailableView { Label("Sleeping Tab", systemImage: "moon") } description: { Text("This page will reload when you wake it.") } actions: { Button("Wake Tab") { store.wake(tab.id) } }
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
