import SwiftUI
import AppKit

struct NativeWebsiteData: View {
    let model: InternalContentModel
    @State private var rows: [[String: Any]] = []
    @State private var query = ""
    @State private var selectedSites: Set<String> = []
    @State private var selectionAnchor: String?
    @State private var choosingData = false
    @State private var clearing = false
    @State private var categories: Set<String> = []
    private let options = [("all", "All website data"), ("cookies", "Cookies"), ("cache", "Cache"), ("permissions", "Reset permissions")]
    private var visibleSites: [String] {
        rows.map { $0.text("name") }.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        InternalContent(title: choosingData ? "Choose Data to Clear" : "Website Data") {
            if choosingData {
                Text("\(selectedSites.count) websites selected").foregroundStyle(.secondary)
                Text(selectedSites.sorted().joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(options, id: \.0) { key, title in
                        Toggle(title, isOn: Binding(get: { categories.contains(key) }, set: { selected in
                            if selected {
                                if key == "all" { categories.subtract(["cookies", "cache"]) }
                                if key == "cookies" || key == "cache" { categories.remove("all") }
                                categories.insert(key)
                            } else { categories.remove(key) }
                        })).toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Button("Back") { choosingData = false }
                    Spacer()
                    Button("Clear Selected Data…", role: .destructive) {
                        let names = selectedSites.sorted()
                        let selected = Array(categories)
                        clearing = true
                        Task {
                            let cleared = await model.call("data.remove", ["names": names, "categories": selected]) as? Bool == true
                            if cleared {
                                await refresh()
                                selectedSites.removeAll()
                                selectionAnchor = nil
                                categories.removeAll()
                                choosingData = false
                            }
                            clearing = false
                        }
                    }.disabled(categories.isEmpty || selectedSites.isEmpty)
                }
            } else {
                TextField("Find a site", text: $query).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Select All") { selectedSites.formUnion(visibleSites); selectionAnchor = nil }.disabled(visibleSites.isEmpty)
                    Button("Deselect All") { selectedSites.removeAll(); selectionAnchor = nil }.disabled(selectedSites.isEmpty)
                    Spacer()
                    Text("\(selectedSites.count) selected").foregroundStyle(.secondary)
                    Button("Next") { choosingData = true }.disabled(selectedSites.isEmpty)
                }
                LazyVStack(spacing: 0) {
                    ForEach(visibleSites, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { selectedSites.contains(name) }, set: {
                            selectSite(name, selected: $0)
                        }))
                        .toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }.disabled(clearing).task { await refresh() }
            .onChange(of: query) { selectionAnchor = nil }
    }
    private func selectSite(_ name: String, selected: Bool) {
        let sites = visibleSites
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
           let selectionAnchor, let start = sites.firstIndex(of: selectionAnchor),
           let end = sites.firstIndex(of: name) {
            // Extend through the visible ordering in either direction; keep other selections.
            selectedSites.formUnion(sites[min(start, end)...max(start, end)])
        } else {
            if selected { selectedSites.insert(name) } else { selectedSites.remove(name) }
            selectionAnchor = name
        }
    }
    private func refresh() async {
        rows = await model.rows("data.list").sorted { $0.text("name") < $1.text("name") }
        selectedSites.formIntersection(rows.map { $0.text("name") })
        if let selectionAnchor, !visibleSites.contains(selectionAnchor) { self.selectionAnchor = nil }
    }
}

struct NativePermissions: View {
    let model: InternalContentModel
    @State private var rows: [[String: Any]] = []
    @State private var protocols: [[String: Any]] = []
    @State private var rules: [[String: Any]] = []
    @State private var origin = ""
    @State private var category = "camera"
    @State private var decision = "ask"
    private let categories = ["camera", "microphone", "popups", "autoplay", "downloads", "externalProtocol"]
    var body: some View {
        InternalContent(title: "Website Permissions") {
            Form {
                TextField("Website origin", text: $origin, prompt: Text("https://example.com"))
                Picker("Permission", selection: $category) { ForEach(categories, id: \.self) { Text($0.capitalized).tag($0) } }
                decisionPicker($decision)
                Button("Save Decision") { Task { await model.call("permissions.set", ["origin": origin, "category": category, "decision": decision]); await refresh() } }.disabled(origin.isEmpty)
            }.formStyle(.columns)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(row.text("origin")); Text(row.text("category").capitalized).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    decisionPicker(Binding(get: { row.text("decision") }, set: { value in Task { await model.call("permissions.set", ["origin": row.text("origin"), "category": row.text("category"), "decision": value]); await refresh() } })).labelsHidden().frame(width: 100)
                    Button("Reset Site") { Task { await model.call("permissions.reset", ["origin": row.text("origin")]); await refresh() } }
                }
            }
            if !protocols.isEmpty {
                Divider(); Text("External Apps").font(.headline)
                ForEach(Array(protocols.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.text("origin")); Text(row.text("scheme") + ":").foregroundStyle(.secondary); Spacer()
                        decisionPicker(Binding(get: { row.text("decision") }, set: { value in Task { await model.call("protocols.set", ["origin": row.text("origin"), "scheme": row.text("scheme"), "decision": value]); await refresh() } })).labelsHidden().frame(width: 100)
                    }
                }
            }
            if !rules.isEmpty {
                Divider(); Text("Site Exceptions").font(.headline)
                ForEach(Array(rules.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.text("origin"))
                        ForEach(["muted", "never_sleep"], id: \.self) { rule in
                            Toggle(rule == "muted" ? "Mute site" : "Never sleep this site", isOn: Binding(get: { row[rule] as? Bool ?? false }, set: { value in Task {
                                await model.call("rules.set", ["origin": row.text("origin"), "rule": rule, "value": value]); await refresh()
                            } }))
                        }
                    }
                }
            }
        }.task { await refresh() }
    }
    private func decisionPicker(_ binding: Binding<String>) -> some View {
        Picker("Decision", selection: binding) { Text("Allow").tag("allow"); Text("Ask").tag("ask"); Text("Block").tag("block") }
    }
    private func refresh() async { rows = await model.rows("permissions.list"); protocols = await model.rows("protocols.list"); rules = await model.rows("rules.list") }
}
