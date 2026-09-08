import SwiftUI

struct JSONTreeNode: Identifiable, Sendable {
    let id: String
    let label: String
    let value: String
    let children: [JSONTreeNode]
    static func make(_ object: Any, path: String = "$", label: String = "$", depth: Int = 0) -> Self {
        var budget = 4000
        return build(object, path: path, label: label, depth: depth, budget: &budget)
    }
    private static func build(_ object: Any, path: String, label: String, depth: Int, budget: inout Int) -> Self {
        budget -= 1
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
        let value = data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        var children: [Self] = []
        if depth < 32 && budget > 0 {
            if let dictionary = object as? [String: Any] {
                for key in dictionary.keys.sorted().prefix(2000) where budget > 0 {
                    let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                    children.append(build(dictionary[key]!, path: path + "['" + escaped + "']", label: key, depth: depth + 1, budget: &budget))
                }
            } else if let array = object as? [Any] {
                for (index, value) in array.prefix(2000).enumerated() where budget > 0 { children.append(build(value, path: path + "[\(index)]", label: "[\(index)]", depth: depth + 1, budget: &budget)) }
            }
        }
        return Self(id: path, label: label, value: value, children: children)
    }
}
struct JSONReaderView: View {
    let raw: String
    let details: ResponseDetails?
    let close: () -> Void
    @State private var mode = "Pretty"
    @State private var query = ""
    @State private var root: JSONTreeNode?
    @State private var pretty = ""
    @State private var headers = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("JSON view", selection: $mode) { ForEach(["Pretty", "Tree", "Raw"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 230)
                TextField("Find in JSON", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Button("Copy JSON") { copy(raw) }
                Button("Response") { headers = true }.popover(isPresented: $headers) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let details {
                                Text("HTTP \(details.status)").font(.headline)
                                Text("\(raw.utf8.count) bytes decoded")
                                if let seconds = details.seconds { Text(String(format: "%.2f s navigation", seconds)) }
                                ForEach(details.headers.keys.sorted(), id: \.self) { key in
                                    Text(key + ": " + (details.headers[key] ?? "")).font(.caption).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }.frame(width: 330, height: 260)
                }
                Button(action: close) { Image(systemName: "xmark") }.help("Show Original Response")
            }.controlSize(.small)
            ScrollView([.horizontal, .vertical]) {
                if mode == "Tree", let root {
                    JSONNodeRow(node: root, query: query).frame(minWidth: 350, alignment: .leading)
                } else {
                    Text(highlight(mode == "Raw" ? raw : pretty)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(16).background(Color(nsColor: .textBackgroundColor))
        .task(id: raw) {
            guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return }
            root = JSONTreeNode.make(object)
            pretty = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        }
    }
    private func highlight(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let regex = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|\b(?:true|false|null|-?\d+(?:\.\d+)?)\b"#)
        for match in regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            if let range = Range(match.range, in: text), let r = Range(range, in: result) { result[r].foregroundColor = text[range].first == "\"" ? .green : .purple }
        }
        if !query.isEmpty {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: query, options: .caseInsensitive, range: search) {
                if let r = Range(range, in: result) { result[r].backgroundColor = .yellow.opacity(0.3) }
                search = range.upperBound..<text.endIndex
            }
        }
        return result
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
private struct JSONNodeRow: View {
    let node: JSONTreeNode
    let query: String
    @State private var expanded = false
    var body: some View {
        if query.isEmpty || node.label.localizedCaseInsensitiveContains(query) || node.value.localizedCaseInsensitiveContains(query) {
            Group {
                if node.children.isEmpty {
                    Text(node.label + ": " + String(node.value.prefix(400))).textSelection(.enabled)
                } else {
                    DisclosureGroup(isExpanded: Binding(get: { expanded || !query.isEmpty }, set: { expanded = $0 })) {
                        ForEach(node.children) { child in JSONNodeRow(node: child, query: query) }
                    } label: { Text(node.label + " · \(node.children.count) items") }
                }
            }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 2)
                .contextMenu {
                    Button("Copy Value") { copy(node.value) }
                    Button("Copy Object") { copy(node.value) }
                    Button("Copy JSONPath") { copy(node.id) }
                }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
