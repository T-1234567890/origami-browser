import SwiftUI

struct BrowserSettings: View {
    let store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Tab layout")
                Spacer(minLength: 12)
                Picker("Tab layout", selection: Binding(get: { store.session.layout }, set: { store.setLayout($0) })) {
                    Text("Horizontal").tag(TabLayout.horizontal)
                    Text("Vertical").tag(TabLayout.vertical)
                }.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false).frame(width: 190, alignment: .trailing)
            }
            if BrowserFeatureFlags.compactSidebar && store.session.layout == .vertical {
                HStack {
                    Text("Sidebar")
                    Spacer(minLength: 12)
                    Picker("Sidebar", selection: Binding(get: { store.sidebarBehavior }, set: { store.setSidebarBehavior($0) })) {
                        ForEach(SidebarBehavior.allCases) { behavior in Text(behavior.title).tag(behavior) }
                    }.pickerStyle(.menu).labelsHidden().fixedSize(horizontal: true, vertical: false).frame(width: 130, alignment: .trailing)
                }
            }
            HStack {
                Text("Search engine")
                Spacer(minLength: 12)
                Picker("Default search engine", selection: Binding(get: { store.session.searchEngine }, set: { store.setSearchEngine($0) })) {
                    ForEach(SearchEngine.allCases) { engine in Text(engine.displayName).tag(engine) }
                }.pickerStyle(.menu).labelsHidden().fixedSize(horizontal: true, vertical: false).frame(width: 130, alignment: .trailing)
                    .accessibilityIdentifier("searchEnginePicker")
            }
            HStack {
                Text("Restore previous session")
                Spacer(minLength: 12)
                Toggle("Restore previous session on launch", isOn: Binding(get: { store.session.restoreSession }, set: { store.setRestoreSession($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Divider()
            HStack(spacing: 12) {
                if !store.isPrivate { ProfileControl(store: store, actionSelected: { dismiss() }) }
                Spacer(minLength: 12)
                Button(action: changePrivateMode) {
                    Image(systemName: "macwindow")
                        .frame(width: 24, height: 24)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7, weight: .semibold))
                                .padding(2)
                                .background(.regularMaterial, in: Circle())
                                .offset(x: 2, y: 1)
                        }
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(store.isPrivate ? "Exit Private Browsing" : "New Private Window")
                    .disabled(store.application == nil)
                    .help(store.isPrivate ? "Close this Private Window and return to normal browsing" : "Open a separate Private Window")
                Button { dismiss(); store.openInternal(.settings) } label: {
                    Image(systemName: "gearshape").frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("All Settings").accessibilityLabel("All Settings")
            }
        }.font(.system(size: 12)).padding(16).frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func changePrivateMode() {
        guard let app = store.application else { return }
        dismiss()
        if store.isPrivate {
            // Never convert private tabs into persistent tabs. Closing follows normal private cleanup.
            if let normal = app.stores.values.first(where: { !$0.isPrivate && $0.session.profileID == store.session.profileID }),
               let window = normal.nativeWindow {
                window.makeKeyAndOrderFront(nil)
            } else {
                let normal = app.newWindow(profileID: store.session.profileID)
                if app.openWindow == nil { openWindow(id: "browser", value: normal.session.windowID) }
            }
            store.nativeWindow?.performClose(nil)
        } else if let window = app.newPrivateWindow(profileID: store.session.profileID), app.openWindow == nil {
            openWindow(id: "browser", value: window.session.windowID)
        }
    }

}
