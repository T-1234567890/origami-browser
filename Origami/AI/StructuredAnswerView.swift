import SwiftUI

struct StructuredAnswerView: View {
    let answer: OrigamiAnswerV1
    let store: BrowserStore
    var visualsAllowed: Bool
    let referencePrefix: String
    let scrollToReference: (String) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(answer.summary).font(.system(size: 18, design: .serif)).textSelection(.enabled).modifier(AnswerReveal(index: 0))
            ForEach(Array(answer.blocks.enumerated()), id: \.offset) { index, block in
                StructuredBlockView(block: block, answer: answer, store: store, visualsAllowed: visualsAllowed) { id in
                    expanded = true
                    scrollToReference(referencePrefix + id)
                }
                    .modifier(AnswerReveal(index: index + 1))
            }
            if !answer.sources.isEmpty {
                Divider(); Text("References").font(.system(size: 22, weight: .medium, design: .serif))
                ForEach(Array(answer.sources.prefix(expanded ? answer.sources.count : 3))) { source in
                    HStack(alignment: .top) {
                        Text("\(answer.sourceNumber(source.id) ?? 0)").font(.caption).foregroundStyle(.secondary)
                        Button { open(source.url) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title)
                                Text([source.author, source.publisher, source.published_at, source.provenance].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Button { open(source.url) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("Visit reference in a new tab")
                    }.id(referencePrefix + source.id)
                }
                if answer.sources.count > 3 {
                    Button(expanded ? "Show less" : "Show more (\(answer.sources.count - 3))") { expanded.toggle() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Personalization.shared.accent)
                }
            }
        }.textSelection(.enabled)
    }
    private func open(_ raw: String) { if let url = AISource.safeURL(raw) { store.newTab(url: url) } }
}
private struct StructuredBlockView: View {
    let block: AnswerBlockV1
    let answer: OrigamiAnswerV1
    let store: BrowserStore
    let visualsAllowed: Bool
    let revealReference: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch block {
            case .heading(let value): Text(value.text).font(.system(size: value.level == 1 ? 25 : value.level == 2 ? 22 : 19, weight: .semibold, design: .serif))
            case .paragraph(let value): prose(value.text, citations: value.citations)
            case .callout(let value): prose(value.text, citations: value.citations).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            case .bullets(let value): list(value, numbered: false)
            case .numbered_list(let value), .steps(let value): list(value, numbered: true)
            case .table(let value):
                prose(value.title, citations: value.citations, font: .headline)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(value.columns.enumerated()), id: \.offset) { _, column in
                                Text(column).fontWeight(.semibold).frame(width: 180, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true).padding(10)
                            }
                        }.background(Color.primary.opacity(0.07))
                        ForEach(Array(value.rows.enumerated()), id: \.offset) { index, row in
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell).lineLimit(nil).frame(width: 180, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true).padding(10)
                                }
                            }.background(Color.primary.opacity(index.isMultiple(of: 2) ? 0.02 : 0.045))
                                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
                        }
                    }.font(.system(size: 14)).textSelection(.enabled)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)) }
                }
            case .comparison(let value):
                Text(value.title).font(.headline)
                ForEach(Array(value.items.enumerated()), id: \.offset) { _, item in VStack(alignment: .leading, spacing: 5) { Text(item.label).bold(); prose(item.text, citations: item.citations) } }
            case .timeline(let value):
                Text(value.title).font(.headline)
                ForEach(Array(value.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 14) { Text(item.date).font(.caption).frame(width: 85, alignment: .leading); VStack(alignment: .leading) { prose(item.label, citations: item.citations) } }
                }
            case .quote(let value):
                prose(value.text, citations: value.citations).italic().padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 2) }
                if let attribution = value.attribution { Text(attribution).font(.caption) }
            case .code(let value):
                prose(value.language.isEmpty ? "Code" : value.language, citations: value.citations, font: .caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) { Text(value.code).font(.system(size: 13, design: .monospaced)).textSelection(.enabled) }
            case .generated_visual(let value): if visualsAllowed { GeneratedVisualView(visual: value) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func prose(_ text: String, citations ids: [String] = [], font: Font = .system(size: 17, design: .serif)) -> some View {
        var content = AttributedString(text)
        for id in ids {
            guard let number = answer.sourceNumber(id) else { continue }
            var mark = AttributedString(" [\(number)]")
            mark.font = .system(size: 12)
            mark.foregroundColor = Personalization.shared.accent
            mark.link = URL(string: "origami-citation://reference/\(number)")
            content.append(mark)
        }
        return Text(content).font(font).lineSpacing(6).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "origami-citation", url.host == "reference",
                      let number = Int(url.lastPathComponent), answer.sources.indices.contains(number - 1) else { return .discarded }
                revealReference(answer.sources[number - 1].id)
                return .handled
            })
    }
    private func list(_ value: AnswerList, numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(value.items.enumerated()), id: \.offset) { index, item in HStack(alignment: .top) { Text(numbered ? "\(index + 1)." : "•"); VStack(alignment: .leading) { prose(item.text, citations: item.citations) } } }
        }
    }

}

private struct AnswerReveal: ViewModifier {
    let index: Int
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(visible || reduceMotion ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 5)
            .task {
                guard !visible else { return }
                if !reduceMotion {
                    do { try await Task.sleep(for: .milliseconds(min(index, 12) * 45)) } catch { return }
                }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { visible = true }
            }
    }
}
