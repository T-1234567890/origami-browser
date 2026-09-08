import SwiftUI
import AppKit

struct ReaderView: View {
    let article: ReaderArticle
    let url: URL?
    let close: () -> Void
    @AppStorage("reader.font") private var font = "Serif"
    @AppStorage("reader.size") private var size = 18.0
    @AppStorage("reader.width") private var width = 640.0
    @AppStorage("reader.spacing") private var spacing = 7.0
    @AppStorage("reader.appearance") private var appearance = "System"
    @State private var controls = false
    @State private var copied = false
    @Environment(\.colorScheme) private var systemScheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(article.title).font(.largeTitle.weight(.semibold))
                Text([article.author, article.date, "\(article.minutes) min read"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(article.markdown.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    let heading = paragraph.prefix(while: { $0 == "#" }).count
                    let text = heading > 0 ? String(paragraph.dropFirst(heading)).trimmingCharacters(in: .whitespaces) : paragraph
                    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)).font(.system(size: heading > 0 ? size + 5 : size, weight: heading > 0 ? .semibold : .regular, design: font == "Serif" ? .serif : .default))
                        .lineSpacing(spacing).textSelection(.enabled)
                }
            }.frame(maxWidth: width, alignment: .leading).padding(32).padding(.bottom, 60).frame(maxWidth: .infinity)
        }
        .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
        .background((appearance == "Dark" || (appearance == "System" && systemScheme == .dark)) ? Color(white: 0.10) : Color.white)
        .environment(\.colorScheme, appearance == "System" ? systemScheme : appearance == "Dark" ? .dark : .light)
        .overlay(alignment: .bottom) {
            HStack(spacing: 16) {
                Button { controls = true } label: { Image(systemName: "textformat.size") }.help("Reading Options")
                    .popover(isPresented: $controls) {
                        Form {
                            Picker("Font", selection: $font) { Text("Serif").tag("Serif"); Text("Sans Serif").tag("Sans") }
                            LabeledContent("Font size") { Slider(value: $size, in: 14...28) }
                            LabeledContent("Line width") { Slider(value: $width, in: 420...820) }
                            LabeledContent("Line spacing") { Slider(value: $spacing, in: 2...16) }
                            Picker("Appearance", selection: $appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                        }.padding(16).frame(width: 290)
                    }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("# \(article.title)\n\n\(article.markdown)", forType: .string); copied = true } label: { if copied { Label("Copied", systemImage: "checkmark") } else { Image(systemName: "doc.on.doc") } }.help("Copy as Markdown")
                Button(action: printArticle) { Image(systemName: "printer") }.help("Print Article")
                if let url { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.help("Share Article") }
                Button(action: close) { Image(systemName: "xmark") }.help("Close Reader")
            }.buttonStyle(.plain).padding(12).background(.regularMaterial, in: Capsule()).padding(12)
        }
    }
    private func printArticle() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 750))
        text.string = article.title + "\n\n" + article.author + "\n\n" + article.markdown
        text.font = NSFont.systemFont(ofSize: 12)
        text.isVerticallyResizable = true
        text.sizeToFit()
        let operation = NSPrintOperation(view: text)
        operation.run()
    }
}
