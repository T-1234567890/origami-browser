import SwiftUI

struct NativeDownloads: View {
    let model: InternalContentModel
    @State private var rows: [[String: Any]] = []
    @State private var limit = 100
    var body: some View {
        InternalContent(title: "Downloads") {
            LazyVStack(spacing: 16) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(row.text("filename")).lineLimit(1)
                            Spacer(); Text(row.text("state").capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        if row.text("state") == "running" {
                            if row.number("expected") > 0 { ProgressView(value: min(1, row.number("received") / row.number("expected"))) }
                            Text(ByteCountFormatter.string(fromByteCount: Int64(row.number("received")), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        if !row.text("error").isEmpty { Text(row.text("error")).font(.caption).foregroundStyle(.secondary) }
                        HStack(spacing: 16) {
                            if row.text("state") == "completed" {
                                action("Open", "open", row); action("Show in Finder", "reveal", row)
                            } else if ["failed", "cancelled", "interrupted"].contains(row.text("state")) { action("Retry", "retry", row) }
                            else { action("Cancel", "cancel", row) }
                            action("Copy URL", "copy", row)
                            if ["completed", "failed", "cancelled", "interrupted"].contains(row.text("state")) { action("Remove", "remove", row) }
                        }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                        Divider()
                    }
                }
            }
            if rows.isEmpty { Text("No downloads yet.").foregroundStyle(.secondary) }
            if rows.count == limit { Button("Load More") { limit += 100; Task { await refresh() } } }
            Button("Clear Completed") { Task { await model.call("downloads.clear"); await refresh() } }.disabled(rows.isEmpty)
        }.task {
            while !Task.isCancelled { await refresh(); do { try await Task.sleep(for: .seconds(1)) } catch { return } }
        }
    }
    private func action(_ title: String, _ action: String, _ row: [String: Any]) -> some View {
        Button(title) { Task { await model.call("downloads.action", ["id": row.text("id"), "action": action]); await refresh() } }
    }
    private func refresh() async {
        var result: [[String: Any]] = []
        for offset in stride(from: 0, to: limit, by: 100) {
            let batch = await model.rows("downloads.list", ["offset": offset]); result += batch
            if batch.count < 100 { break }
        }
        rows = result
    }
}
