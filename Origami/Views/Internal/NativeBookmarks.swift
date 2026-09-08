import SwiftUI
import UniformTypeIdentifiers

struct NativeBookmarks: View {
    let model: InternalContentModel
    @State private var rows: [[String: Any]] = []
    @State private var folders: [[String: Any]] = []
    @State private var folder = ""
    @State private var query = ""
    @State private var editing = false
    @State private var editingFolder = false
    @State private var selected: [String: Any] = [:]
    @State private var title = ""
    @State private var url = ""
    @State private var parent = ""
    @State private var favorite = false
    @State private var position = 0
    @State private var more = false
    private var compact: Bool { _ = model.store.preferencesRevision; return model.store.preferences.compactBookmarks }
    var body: some View {
        InternalContent(title: "Bookmarks") {
            HStack {
                TextField("Search bookmarks", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await refresh() } }
                Picker("Folder", selection: $folder) {
                    Text("Bookmarks").tag("")
                    ForEach(Array(folders.enumerated()), id: \.offset) { _, row in Text(folderName(row)).tag(row.text("id")) }
                }.frame(maxWidth: 260)
            }
            HStack(spacing: 18) {
                Toggle("Compact View", isOn: Binding(get: { compact }, set: { model.store.preferences.compactBookmarks = $0; model.store.preferencesRevision += 1 }))
                Button("Add Bookmark") { edit([:]) }
                Button("New Folder") { editFolder([:]) }
                if !folder.isEmpty {
                    Button("Edit Folder") { editFolder(folders.first { $0.text("id") == folder } ?? [:]) }
                    Menu("Open Folder") {
                        Button("As Tabs") { Task { await model.call("folders.open", ["id": folder]) } }
                        Button("As Tab Group") { Task { await model.call("folders.open", ["id": folder, "grouped": true]) } }
                    }
                }
            }.buttonStyle(.plain)
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        SiteIcon(store: model.store, url: URL(string: row.text("url")))
                        Button { model.open(row.text("url")) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.text("title")).lineLimit(1)
                                if !compact { Text(row.text("url")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { edit(row) } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit bookmark")
                        Button { Task { await model.call("bookmarks.delete", ["id": row.text("id")]); await refresh() } } label: { Image(systemName: "xmark") }.accessibilityLabel("Delete bookmark")
                    }.buttonStyle(.plain).padding(.vertical, compact ? 6 : 10)
                        .draggable(row.text("id"))
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first, UUID(uuidString: id) != nil else { return false }
                            Task { await model.call("bookmarks.reorder", ["id": id, "before": row.text("id")]); await refresh() }; return true
                        }
                }
            }
            if rows.isEmpty { Text("No bookmarks here.").foregroundStyle(.secondary) }
            if more { Button("Load More") { Task { await refresh(append: true) } } }
            HStack(spacing: 18) {
                Button("Import HTML…") { Task { await model.call("bookmarks.import"); await refresh() } }
                Button("Export HTML…") { Task { await model.call("bookmarks.export") } }
            }.buttonStyle(.plain)
        }.task { await refresh() }.onChange(of: folder) { Task { await refresh() } }
            .popover(isPresented: $editing) { editor }
            .popover(isPresented: $editingFolder) { folderEditor }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selected.isEmpty ? "Add Bookmark" : "Edit Bookmark").font(.headline)
            TextField("Title", text: $title); TextField("URL", text: $url)
            folderPicker
            Toggle("Show on New Tab", isOn: $favorite)
            HStack { Button("Cancel") { editing = false }; Spacer(); Button("Save") { Task {
                var id = selected.text("id")
                if id.isEmpty { id = await model.call("bookmarks.create", ["title": title, "url": url, "folderID": parent]) as? String ?? "" }
                guard !id.isEmpty, await model.call("bookmarks.edit", ["id": id, "title": title, "url": url, "folderID": parent, "favorite": favorite]) != nil else { return }
                editing = false; await refresh()
            } }.keyboardShortcut(.defaultAction) }
        }.textFieldStyle(.roundedBorder).padding(16).frame(width: 300)
    }
    private var folderEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selected.isEmpty ? "New Folder" : "Edit Folder").font(.headline)
            TextField("Folder name", text: $title)
            folderPicker
            if !selected.isEmpty { Stepper("Position: \(position + 1)", value: $position, in: 0...10000) }
            HStack {
                if !selected.isEmpty { Button("Delete…") { Task { editingFolder = false; await model.call("folders.delete", ["id": selected.text("id")]); folder = ""; await refresh() } } }
                Spacer(); Button("Save") { Task {
                    var params: [String: Any] = ["title": title, "folderID": parent, "position": position]
                    if !selected.isEmpty { params["id"] = selected.text("id") }
                    if await model.call(selected.isEmpty ? "folders.create" : "folders.edit", params) != nil { editingFolder = false; await refresh() }
                } }.disabled(title.isEmpty)
            }
        }.textFieldStyle(.roundedBorder).padding(16).frame(width: 300)
    }
    private var folderPicker: some View {
        Picker("Folder", selection: $parent) {
            Text("None").tag("")
            ForEach(Array(folders.enumerated()), id: \.offset) { _, row in
                if !editingFolder || row.text("id") != selected.text("id") { Text(folderName(row)).tag(row.text("id")) }
            }
        }
    }
    private func edit(_ row: [String: Any]) { selected = row; title = row.text("title"); url = row.text("url"); parent = row.text("folderID").isEmpty ? folder : row.text("folderID"); favorite = row["favorite"] as? Bool ?? false; editing = true }
    private func editFolder(_ row: [String: Any]) { selected = row; title = row.text("title"); parent = row.isEmpty ? folder : row.text("parentID"); position = 0; editingFolder = true }
    private func folderName(_ row: [String: Any]) -> String {
        var names = [row.text("title")], parent = row.text("parentID"), seen = Set([row.text("id")])
        while !parent.isEmpty, seen.insert(parent).inserted, let ancestor = folders.first(where: { $0.text("id") == parent }) { names.insert(ancestor.text("title"), at: 0); parent = ancestor.text("parentID") }
        return names.joined(separator: " / ")
    }
    private func refresh(append: Bool = false) async {
        folders = await model.rows("bookmarks.folders")
        let result = await model.rows("bookmarks.list", ["text": query, "folderID": folder, "offset": append ? rows.count : 0])
        rows = append ? rows + result : result; more = result.count == 100
    }
}
