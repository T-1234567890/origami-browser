import SwiftUI

struct ClearDataButton: View {
    let model: InternalContentModel
    var historyOnly = false
    var completed: () async -> Void
    @State private var presented = false
    @State private var range = "hour"
    @State private var categories: Set<String> = ["history"]
    private let options = [("history", "History"), ("cookies", "Cookies"), ("cache", "Cache"), ("localStorage", "Local Storage"), ("indexedDB", "IndexedDB"), ("serviceWorkers", "Service Workers"), ("downloads", "Download History"), ("permissions", "Permissions")]
    var body: some View {
        Button(historyOnly ? "Clear History…" : "Clear Browsing Data…") { presented = true }
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(historyOnly ? "Clear History" : "Clear Browsing Data").font(.headline)
                    Picker("Time range", selection: $range) {
                        Text("Last Hour").tag("hour"); Text("Today").tag("today")
                        Text("Last 7 Days").tag("week"); Text("Everything").tag("all")
                    }
                    if !historyOnly {
                        ForEach(options, id: \.0) { key, title in
                            Toggle(title, isOn: Binding(get: { categories.contains(key) }, set: { if $0 { categories.insert(key) } else { categories.remove(key) } })).toggleStyle(.checkbox)
                        }
                    }
                    Text("Only the current profile is affected.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { presented = false }; Spacer()
                        Button("Continue…") {
                            presented = false
                            Task {
                                await Task.yield()
                                await model.call("data.clear", ["range": range, "categories": historyOnly ? ["history"] : Array(categories)])
                                await completed()
                            }
                        }.disabled(!historyOnly && categories.isEmpty)
                    }
                }.padding(16).frame(width: 280)
            }
    }
}
