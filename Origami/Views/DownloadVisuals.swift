import SwiftUI
import UniformTypeIdentifiers

struct DownloadFileIcon: View {
    let filename: String
    var failed = false
    static func symbol(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "pdf" { return "doc.richtext" }
        if ["dmg", "iso"].contains(ext) { return "externaldrive" }
        if ["pkg", "app"].contains(ext) { return "shippingbox" }
        if ["doc", "docx", "odt", "rtf", "pages"].contains(ext) { return "doc.text" }
        if ["xls", "xlsx", "csv", "numbers", "ods"].contains(ext) { return "tablecells" }
        if ["ppt", "pptx", "key", "odp"].contains(ext) { return "rectangle.on.rectangle" }
        guard let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) || ["json", "xml", "yaml", "yml"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.plaintext" }
        return "doc"
    }
    var body: some View {
        Image(systemName: Self.symbol(for: filename))
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.secondary).frame(width: 26, height: 28)
            .overlay(alignment: .bottomTrailing) {
                if failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .background(.background, in: Circle())
                }
            }.accessibilityHidden(true)
    }
}

struct DownloadActivityIcon: View {
    let running: Bool
    let starts: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: InternalPage.downloads.symbol)
            .foregroundStyle(running ? Color.accentColor : Color.secondary)
            .symbolEffect(.bounce.down, value: reduceMotion ? 0 : starts)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}
