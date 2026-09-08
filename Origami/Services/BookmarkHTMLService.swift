import Foundation

indirect enum ImportedBookmark { case folder(String, [ImportedBookmark]), bookmark(String, URL) }

final class BookmarkHTMLService {
    let repository: BookmarkRepository
    init(_ repository: BookmarkRepository) { self.repository = repository }
    func importHTML(_ data: Data, profileID: UUID) throws -> Int {
        guard data.count <= 20_000_000 else { throw RepositoryError.invalidInput }
        let document = try XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        guard let root = try document.nodes(forXPath: "//dl | //DL").first else { throw RepositoryError.invalidInput }
        func walk(_ list: XMLNode, depth: Int) throws -> [ImportedBookmark] {
            guard depth < 32 else { throw RepositoryError.invalidInput }
            var items: [ImportedBookmark] = []
            for child in list.children ?? [] {
                let tag = child.name?.lowercased()
                if tag == "dt" || tag == "dd" {
                    if let heading = child.children?.first(where: { $0.name?.lowercased() == "h3" }) {
                        let nested = child.children?.first(where: { $0.name?.lowercased() == "dl" })
                        items.append(.folder((heading.stringValue ?? "Imported Folder").trimmingCharacters(in: .whitespacesAndNewlines), try nested.map { try walk($0, depth: depth + 1) } ?? []))
                    } else if let anchor = child.children?.first(where: { $0.name?.lowercased() == "a" }) as? XMLElement,
                              let href = anchor.attribute(forName: "href")?.stringValue ?? anchor.attribute(forName: "HREF")?.stringValue,
                              let url = URL(string: href), let clean = PersistedURL.clean(url) {
                        items.append(.bookmark(anchor.stringValue ?? href, clean))
                    }
                } else if tag == "dl" { items += try walk(child, depth: depth + 1) }
            }
            return items
        }
        return try repository.importItems(walk(root, depth: 0), profileID: profileID)
    }
    func exportHTML(profileID: UUID) throws -> Data {
        let folders = try repository.folders(profileID: profileID)
        let bookmarks = try repository.list(profileID: profileID)
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func list(_ parent: UUID?, depth: Int) -> String {
            guard depth < 32 else { return "" }
            var html = "<DL><p>\n"
            for folder in folders.filter({ $0.parentID == parent }) {
                html += "<DT><H3>\(escape(folder.title))</H3>\n" + list(folder.id, depth: depth + 1)
            }
            for bookmark in bookmarks.filter({ $0.folderID == parent }) {
                html += "<DT><A HREF=\"\(escape(bookmark.url))\">\(escape(bookmark.title))</A>\n"
            }
            return html + "</DL><p>\n"
        }
        return Data(("<!DOCTYPE NETSCAPE-Bookmark-file-1><META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\"><TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>\n" + list(nil, depth: 0)).utf8)
    }
}
