import Foundation

struct TabDestinationHistory {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        var url: URL
    }
    private(set) var entries: [Entry] = []
    private(set) var index = -1
    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }
    @discardableResult mutating func visit(_ url: URL) -> Entry {
        entries = Array(entries.prefix(index + 1))
        let entry = Entry(id: UUID(), url: url)
        entries.append(entry); index = entries.count - 1
        return entry
    }
    mutating func select(_ id: UUID, url: URL? = nil) {
        guard let position = entries.firstIndex(where: { $0.id == id }) else { return }
        index = position
        if let url { entries[position].url = url }
    }
    mutating func move(_ offset: Int) -> Entry? {
        guard entries.indices.contains(index + offset) else { return nil }
        index += offset; return entries[index]
    }
}
