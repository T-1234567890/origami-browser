import SwiftUI

struct SiteInformation: View {
    let store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var decisions: [SitePermission: PermissionDecision] = [:]
    @State private var reloadNotice: UUID?
    @State private var contentHeight: CGFloat = 320
    private let permissions: [(SitePermission, String)] = [
        (.camera, "Camera"), (.microphone, "Microphone"), (.popups, "Pop-ups"),
        (.autoplay, "Autoplay"), (.downloads, "Downloads")
    ]
    private var origin: String? { store.selectedTab?.url.flatMap(PermissionService.origin) }
    private var domain: String {
        guard let origin, let host = URL(string: origin)?.host else { return "Origami" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private var page: TabPage? { store.selectedTab.flatMap { store.loadedPage(for: $0.id) } }

    var body: some View {
        ScrollView {
            content
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(width: 340, height: min(contentHeight, 400))
        .scrollDisabled(contentHeight <= 400)
        .scrollBounceBehavior(.basedOnSize)
        .task(id: origin) { reloadNotice = nil; readDecisions() }
        .task(id: reloadNotice) {
            guard reloadNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            reloadNotice = nil
        }
        .onChange(of: page?.isLoading) { if page?.isLoading == true { reloadNotice = nil } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                if origin != nil { SiteIcon(store: store, url: store.selectedTab?.url, size: 18) }
                else { Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 18) }
                Text(domain).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .truncationMode(.middle).textSelection(.enabled).help(origin ?? "Origami")
                Spacer(minLength: 0)
            }.padding(.bottom, 2)

            if let origin {
                Divider()
                VStack(spacing: 0) {
                    ForEach(permissions, id: \.0) { permission, title in
                        HStack {
                            Text(title)
                            Spacer(minLength: 16)
                            Menu {
                                Picker(title, selection: Binding(get: { decisions[permission] ?? .ask }, set: {
                                    set($0, permission: permission, origin: origin)
                                })) {
                                    Text("Ask").tag(PermissionDecision.ask)
                                    Text("Allow").tag(PermissionDecision.allow)
                                    Text("Block").tag(PermissionDecision.block)
                                }.pickerStyle(.inline)
                            } label: {
                                Text((decisions[permission] ?? .ask).rawValue.capitalized)
                                    .frame(width: 42, alignment: .trailing)
                            }
                            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                            .accessibilityLabel(title)
                            .accessibilityValue((decisions[permission] ?? .ask).rawValue.capitalized)
                        }.frame(height: 28)
                    }
                }
            }

            Divider()
            VStack(spacing: 0) {
                navigationRow("Website Data", destination: .data)
                navigationRow("All Permissions & Apps", destination: .permissions)
            }

            if let origin {
                Divider()
                Button("Reset Site Permissions", role: .destructive) { reset(origin) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .frame(minHeight: 24, alignment: .leading)
                if reloadNotice != nil {
                    Text("Reload this page to apply the change.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.font(.system(size: 12))
    }

    private func navigationRow(_ title: String, destination: InternalPage) -> some View {
        Button { dismiss(); store.openInternal(destination) } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            }.frame(height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func readDecisions() {
        decisions = [:]
        guard let origin else { return }
        do {
            for (category, _) in permissions {
                decisions[category] = try store.services?.permissions.decision(category, origin: origin, profileID: store.session.profileID)
            }
        } catch { store.persistenceError = error.localizedDescription }
    }

    private func set(_ value: PermissionDecision, permission: SitePermission, origin: String) {
        guard value != (decisions[permission] ?? .ask) else { return }
        do {
            try store.services?.permissions.set(value, category: permission, origin: origin, profileID: store.session.profileID)
            decisions[permission] = value
            if permission == .autoplay { reloadNotice = UUID() }
        } catch { store.persistenceError = error.localizedDescription }
    }

    private func reset(_ origin: String) {
        let previousAutoplay = decisions[.autoplay] ?? .ask
        do {
            try store.services?.permissions.reset(profileID: store.session.profileID, origin: origin)
            readDecisions()
            if previousAutoplay != (decisions[.autoplay] ?? .ask) { reloadNotice = UUID() }
        } catch { store.persistenceError = error.localizedDescription }
    }
}
