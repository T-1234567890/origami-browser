import SwiftUI

@MainActor @Observable
final class InternalContentModel {
    let store: BrowserStore
    let tabID: UUID
    var error: String?
    init(store: BrowserStore, tabID: UUID) { self.store = store; self.tabID = tabID }
    @discardableResult func call(_ method: String, _ params: [String: Any] = [:]) async -> Any? {
        do { error = nil; return try await store.handleInternal(method, params: params, tabID: tabID) }
        catch { self.error = error.localizedDescription; return nil }
    }
    func rows(_ method: String, _ params: [String: Any] = [:]) async -> [[String: Any]] {
        await call(method, params) as? [[String: Any]] ?? []
    }
    func open(_ url: String) { store.page(for: tabID).load(URL(string: url) ?? InternalRoute.newTabURL) }
}

struct NativeInternalSurface: View {
    let store: BrowserStore
    let destination: InternalPage
    let tabID: UUID
    @Environment(\.colorScheme) private var colorScheme
    @State private var model: InternalContentModel
    init(store: BrowserStore, destination: InternalPage, tabID: UUID) {
        self.store = store; self.destination = destination; self.tabID = tabID
        _model = State(initialValue: InternalContentModel(store: store, tabID: tabID))
    }
    var body: some View {
        Group {
            switch destination {
            case .newtab: NativeNewTab(model: model)
            case .welcome: NativeWelcome(model: model)
            case .settings: NativeSettings(model: model)
            case .history: NativeHistory(model: model)
            case .bookmarks: NativeBookmarks(model: model)
            case .downloads: NativeDownloads(model: model)
            case .data: NativeWebsiteData(model: model)
            case .permissions: NativePermissions(model: model)
            case .references: ReferenceCollection(store: store)
            case .feeds: NativeFeeds(model: model)
            case .profiles: NativeProfiles(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(white: 0.10) : Color.white)
        .foregroundStyle(.primary)
        .popover(isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.error ?? "").fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { model.error = nil }
            }.padding(16).frame(width: 280)
        }
    }
}

/// Content only: navigation and window controls belong to ContentView.
struct InternalContent<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.title2.weight(.semibold))
                content()
            }.frame(maxWidth: 800, alignment: .leading).padding(32).frame(maxWidth: .infinity)
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String { self[key] as? String ?? "" }
    func number(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? 0 }
}
