import SwiftUI

struct NativeNewTab: View {
    let model: InternalContentModel
    private var asking: Bool {
        get { model.store.loadedPage(for: model.tabID)?.isAsking ?? false }
        nonmutating set { model.store.loadedPage(for: model.tabID)?.isAsking = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if model.store.services?.ai.events[model.tabID] != nil {
                AskSurface(store: model.store, tabID: model.tabID) {
                    model.store.services?.ai.clear(model.tabID); asking = true
                    updateTitle()
                }.id(model.store.services?.ai.events[model.tabID]?.id)
                    .transition(reduceMotion ? .opacity : model.store.loadedPage(for: model.tabID)?.answerFromHistory == true ? .move(edge: .trailing).combined(with: .opacity) : .scale(scale: 0.97).combined(with: .opacity))
            } else { NativeSearchTab(model: model, asking: Binding(get: { asking }, set: { asking = $0 })).transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: model.store.services?.ai.events[model.tabID]?.id)
        .task { model.store.services?.ai.restore(tab: model.tabID, profile: model.store.session.profileID) }
        .onChange(of: model.store.services?.ai.events[model.tabID]?.query, initial: true) { _, query in
            if query != nil { asking = true }; updateTitle()
        }
        .onChange(of: asking) { updateTitle() }
        .onChange(of: model.store.services?.ai.events[model.tabID]?.needsSetup) { _, needed in if needed == true { model.store.showingAISetup = true } }
        .onChange(of: model.store.services?.ai.events[model.tabID]?.explorations?.last?.needsSetup) { _, needed in if needed == true { model.store.showingAISetup = true } }

    }
    private func updateTitle() {
        let title = model.store.services?.ai.events[model.tabID]?.query ?? (asking ? "Ask the Web" : "New Tab")
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            model.store.loadedPage(for: model.tabID)?.aiTitle = title
            if let index = model.store.session.tabs.firstIndex(where: { $0.id == model.tabID }), model.store.session.tabs[index].title != title { model.store.session.tabs[index].title = title; model.store.save() }
        }
    }
}

struct NativeSearchTab: View {
    let model: InternalContentModel
    @Binding var asking: Bool
    @State private var mode = AskMode.ask
    private var selectedModel: String {
        get { model.store.loadedPage(for: model.tabID)?.askModelSelections[AISettings.shared.provider] ?? "" }
        nonmutating set { model.store.loadedPage(for: model.tabID)?.askModelSelections[AISettings.shared.provider] = newValue }
    }
    @State private var showingTimeline = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestionAnchor = SuggestionAnchor()
    private var query: String {
        get { model.store.loadedPage(for: model.tabID)?.newTabDraft ?? "" }
        nonmutating set { model.store.loadedPage(for: model.tabID)?.newTabDraft = newValue }
    }
    @State private var searchFocusRequest = UUID()
    @State private var favorites: [[String: Any]] = []
    private var remoteSuggestionsAllowed: Bool {
        _ = model.store.preferencesRevision
        return model.store.preferences.allowsRemoteSuggestions(isPrivate: model.store.isPrivate)
    }
    private func submit(_ input: String, searchOnly: Bool = false) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if asking {
            guard AISettings.shared.setupComplete, AICredentialStore().contains(AISettings.shared.provider) else { model.store.showingAISetup = true; return }
            model.store.loadedPage(for: model.tabID)?.answerFromHistory = false
            model.store.services?.ai.start(AIRequest(query: String(input.prefix(12000)), mode: mode, action: .web, contexts: [], model: selectedModel.isEmpty ? AISettings.shared.routedModel(action: .web, mode: mode) : selectedModel), tab: model.tabID, profile: model.store.session.profileID)
        } else { model.store.navigate(input, searchOnly: searchOnly) }
    }
    var body: some View {
        GeometryReader { geometry in
            let height = max(540, geometry.size.height)
            ScrollView {
                ZStack {
                    Group {
                        if !asking, let data = Personalization.shared.titleImage, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: min(420, max(0, geometry.size.width - 48)), height: 95).accessibilityLabel("Origami")
                        } else {
                            Text(asking ? "Ask the Web" : "Origami").font(.system(size: 34, weight: .medium, design: asking ? .serif : .default))
                        }
                    }.frame(height: !asking && Personalization.shared.titleImage != nil ? 97 : 72).position(x: geometry.size.width / 2, y: height / 2 - 90)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Omnibox(store: model.store, allowRemote: !asking && remoteSuggestionsAllowed,
                                tabID: model.tabID, value: query, focusRequest: searchFocusRequest,
                                canFocus: false, suggestionsEnabled: !asking, suggestionAnchor: suggestionAnchor,
                                placeholder: asking ? "What do you want to know?" : "Search the Web…", fontSize: 16,
                                textChanged: { query = $0 }) { input, searchOnly in submit(input, searchOnly: searchOnly) }
                            .frame(height: 22)
                        Button { submit(query) } label: { Image(systemName: "arrow.right") }
                            .buttonStyle(.plain).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel(asking ? "Ask" : "Search")
                    }.padding(.horizontal, 18).frame(height: 48).modifier(ChromeSurface())
                        .environment(\.colorScheme, colorScheme)
                        .background(SuggestionAnchorView(anchor: suggestionAnchor))
                        .frame(width: max(100, min(500, geometry.size.width - 64)))
                        .position(x: geometry.size.width / 2, y: height / 2)
                    VStack(spacing: 18) {
                        if asking {
                            AskModeControl(mode: $mode)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 100))], spacing: 20) {
                                ForEach(Array((Personalization.shared.favorites ? favorites : []).enumerated()), id: \.offset) { _, site in
                                    Button { model.open(site.text("url")) } label: {
                                        VStack(spacing: 8) {
                                            SiteIcon(store: model.store, url: URL(string: site.text("url")), size: 24)
                                            Text(site.text("title")).font(.caption).lineLimit(1)
                                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                                    }.buttonStyle(.plain).help(site.text("url"))
                                }
                            }
                        }
                    }.frame(width: max(100, min(500, geometry.size.width - 64)), height: 180, alignment: .top)
                        .position(x: geometry.size.width / 2, y: height / 2 + 140)
                }.frame(height: height)
            }
        }
        .environment(\.colorScheme, !asking && Personalization.shared.wallpaper != nil ? (Personalization.shared.wallpaperIsDark ? .dark : .light) : colorScheme)
        .overlay(alignment: .bottomLeading) {
            if asking {
                HStack(spacing: 16) {
                    AskModelControl(selection: Binding(get: { selectedModel }, set: { selectedModel = $0 }), mode: mode)
                        .frame(maxWidth: 220, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                    Button { showingTimeline = true } label: {
                        Label("History", systemImage: "clock").font(.caption)
                    }.buttonStyle(.plain)
                        .popover(isPresented: $showingTimeline) { AskTimeline(store: model.store, tabID: model.tabID) }
                }.foregroundStyle(Color.secondary).padding(22)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { asking.toggle() } } label: {
                Label(asking ? "Search the Web" : "Ask the Web", systemImage: asking ? "magnifyingglass" : "text.magnifyingglass").font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
            }.buttonStyle(.plain).modifier(ChromeSurface()).environment(\.colorScheme, colorScheme).padding(22)
        }
        .background {
            if asking { (colorScheme == .dark ? Color(red: 0.115, green: 0.11, blue: 0.10) : Color(red: 0.985, green: 0.975, blue: 0.955)) }
            else if let data = Personalization.shared.wallpaper, let image = NSImage(data: data) {
                GeometryReader { geometry in
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.allowsHitTesting(false)
            }
        }.task(id: model.store.bookmarkRevision) {
            var seen = Set<String>()
            let pinned = model.store.session.tabs.filter(\.isPinned).compactMap { tab -> [String: Any]? in
                guard let url = tab.url, ["https", "http"].contains(url.scheme) else { return nil }
                return ["url": url.absoluteString, "title": tab.title]
            }
            let saved = await model.rows("bookmarks.list", ["favorites": true])
            favorites = Array((pinned + saved).filter { seen.insert($0.text("url")).inserted }.prefix(12))
        }
    }
}

struct NativeWelcome: View {
    let model: InternalContentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var layout = TabLayout.horizontal
    @State private var engine = SearchEngine.google
    @State private var strict = false
    @State private var defaultAsk = false
    private let titles = ["Origami", "Tabs", "Search Engine", "Default New Tab", "Privacy"]
    var body: some View {
        ZStack {
            BrowserChromeBackground().ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer(minLength: 0)
                Group {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }.frame(width: 64, height: 64).accessibilityHidden(true)
                Text(titles[step]).font(.system(size: 30, weight: .medium)).multilineTextAlignment(.center)
                Group {
                    switch step {
                    case 0:
                        Text("The open-source browser for Mac,\nbuilt for the AI era.")
                            .font(.system(size: 20)).lineSpacing(3)
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    case 1:
                        HStack(spacing: 24) {
                            OnboardingLayoutChoice(layout: .horizontal, selected: layout == .horizontal) { layout = .horizontal }
                            OnboardingLayoutChoice(layout: .vertical, selected: layout == .vertical) { layout = .vertical }
                        }
                    case 2:
                        Picker("Default search engine", selection: $engine) {
                            ForEach(SearchEngine.allCases) { Text($0.displayName).tag($0) }
                        }.pickerStyle(.radioGroup).labelsHidden()
                    case 3:
                        HStack(spacing: 24) {
                            OnboardingPrivacyChoice(title: "Search the Web", symbol: "magnifyingglass", selected: !defaultAsk) { defaultAsk = false }
                            OnboardingPrivacyChoice(title: "Ask the Web", symbol: "text.magnifyingglass", selected: defaultAsk) { defaultAsk = true }
                        }
                    case 4:
                        VStack(spacing: 18) {
                            HStack(spacing: 24) {
                                OnboardingPrivacyChoice(title: "Standard", symbol: "shield", selected: !strict) { strict = false }
                                OnboardingPrivacyChoice(title: "Strict", symbol: "lock.shield", selected: strict) { strict = true }
                            }.frame(maxWidth: 340)
                            Text(strict ? "Block website popups and autoplay by default." : "Ask before allowing website popups and autoplay.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                            Text("No account required. No telemetry.").font(.callout)
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    default: EmptyView()
                    }
                }.frame(maxWidth: 420, minHeight: step == 0 ? 60 : 100)
                Spacer(minLength: 0)
                HStack {
                    if step > 0 {
                        Button { step -= 1 } label: {
                            Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium))
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Previous").accessibilityLabel("Previous")
                    }
                    Spacer()
                    Button(step == 4 ? "Start Browsing" : "Continue") {
                        if step < 4 { step += 1 } else { Task {
                            guard await model.call("settings.write", ["layout": layout.rawValue, "search": engine.rawValue, "restore": model.store.session.restoreSession, "privacy": strict ? "strict" : "standard"]) != nil else { return }
                            Personalization.shared.defaultAsk = defaultAsk
                            await model.call("onboarding.complete")
                        } }
                    }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }.padding(32).animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
        }.task {
            defaultAsk = Personalization.shared.defaultAsk
            layout = model.store.session.layout; engine = model.store.session.searchEngine
            let values = await model.call("settings.read") as? [String: Any]
            strict = values?.text("privacy") == "strict"
        }
    }
}


private struct OnboardingPrivacyChoice: View {
    let title: String
    let symbol: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 30, weight: .light))
                    .frame(height: 36).accessibilityHidden(true)
                Text(title).font(.system(size: 15, weight: selected ? .medium : .regular))
                Capsule().fill(selected ? Personalization.shared.accent : .clear).frame(width: 32, height: 2)
            }
            .foregroundStyle(selected ? Personalization.shared.accent : .secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
