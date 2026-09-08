import SwiftUI

struct NativeHistory: View {
    let model: InternalContentModel
    @State private var rows: [[String: Any]] = []
    @State private var recent: [[String: Any]] = []
    @State private var windows: [[String: Any]] = []
    @State private var selecting = false
    @State private var selected = Set<Int64>()
    @State private var query = ""
    @State private var domain = ""
    @State private var range = 0
    @State private var hasMore = false
    private var since: Double {
        switch range { case 1: Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        case 2: Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        case 3: Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970
        default: 0 }
    }
    var body: some View {
        InternalContent(title: "History") {
            AISearchHistory(store: model.store)
            HStack {
                TextField("Search history", text: $query).onSubmit { Task { await refresh() } }
                TextField("Domain", text: $domain).frame(maxWidth: 180).onSubmit { Task { await refresh() } }
                Picker("Date", selection: $range) { Text("All time").tag(0); Text("Today").tag(1); Text("This week").tag(2); Text("This month").tag(3) }.labelsHidden().frame(width: 130)
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button(selecting ? "Done Selecting" : "Select Visits") { selecting.toggle(); selected.removeAll() }
                if selecting {
                    Button("Delete Selected (\(selected.count))…") { Task {
                        let ids = selected
                        guard await model.store.confirm("Delete \(ids.count) selected history visits?", tabID: model.tabID) else { return }
                        for id in ids { await model.call("history.delete", ["id": NSNumber(value: id)]) }
                        selected.removeAll(); await refresh()
                    } }.disabled(selected.isEmpty)
                }
                Spacer()
                ClearDataButton(model: model, historyOnly: true) { selected.removeAll(); await refresh() }
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index == 0 || day(row) != day(rows[index - 1]) {
                        Text(day(row)).font(.headline).padding(.top, 12)
                    }
                    HStack(alignment: .top, spacing: 20) {
                        if selecting, let id = (row["id"] as? NSNumber)?.int64Value {
                            Toggle("Select visit", isOn: Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } })).labelsHidden().toggleStyle(.checkbox)
                        }
                        Text(Date(timeIntervalSince1970: row.number("time")).formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
                        Button { model.open(row.text("url")) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.text("title").isEmpty ? row.text("url") : row.text("title")).lineLimit(1)
                                Text(row.text("host")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Text("\(Int(row.number("visits"))) visits").font(.caption).foregroundStyle(.tertiary)
                        Button { Task { await model.call("history.delete", ["id": row["id"] ?? 0]); await refresh() } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Delete visit")
                    }.padding(.vertical, 5)
                }
            }
            if rows.isEmpty { Text("No matching visits.").foregroundStyle(.secondary) }
            if hasMore { Button("Load More") { Task { await refresh(more: true) } } }
            if !recent.isEmpty || !windows.isEmpty {
                Divider()
                Text("Recently Closed").font(.headline)
                ForEach(Array(recent.enumerated()), id: \.offset) { _, row in
                    Button { Task { await model.call("recent.reopen", ["id": row.text("id")]); recent = await model.rows("recent.list") } } label: {
                        HStack(spacing: 10) {
                            SiteIcon(store: model.store, url: URL(string: row.text("url")))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.text("title")).lineLimit(1)
                                Text(URL(string: row.text("url"))?.host ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                ForEach(Array(windows.enumerated()), id: \.offset) { _, row in
                    Button("Reopen Window · \(row.text("title"))") { Task { await model.call("windows.reopen", ["id": row.text("id")]); windows = await model.rows("windows.closed") } }.buttonStyle(.plain)
                }
            }
        }.onReceive(NotificationCenter.default.publisher(for: .origamiHistoryChanged)) { _ in
            Task { await refresh(); recent = await model.rows("recent.list") }
        }.task { await refresh(); recent = await model.rows("recent.list"); windows = await model.rows("windows.closed") }
            .onChange(of: range) { Task { await refresh() } }
    }
    private func day(_ row: [String: Any]) -> String {
        let date = Date(timeIntervalSince1970: row.number("time"))
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    private func refresh(more: Bool = false) async {
        var params: [String: Any] = ["text": query, "domain": domain, "since": since]
        if more, let last = rows.last { params["beforeTime"] = last["time"]; params["beforeID"] = last["id"] }
        let result = await model.rows("history.list", params)
        rows = more ? rows + result : result; hasMore = result.count == 100
    }
}
