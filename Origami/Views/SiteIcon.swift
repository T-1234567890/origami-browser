import SwiftUI

struct SiteIcon: View {
    let store: BrowserStore
    let url: URL?
    var size: CGFloat = 16
    private var icon: NSImage? {
        guard let url, let origin = FaviconService.origin(url) else { return nil }
        if let tab = store.session.tabs.first(where: { FaviconService.origin($0.url) == origin }),
           let image = store.loadedPage(for: tab.id)?.favicon { return image }
        return store.services?.favicons.cached(url, profile: store.session.profileID)
    }
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
            .task(id: url) { if let url { _ = await store.services?.favicons.load(url, profile: store.session.profileID) } }
    }
}
