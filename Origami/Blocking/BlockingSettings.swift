import SwiftUI
import UniformTypeIdentifiers

struct BlockingSettings: View {
    @Bindable var service: BlockingService
    @State private var importing = false
    @State private var importError: String?
    @State private var editing = false
    @State private var domains = ""
    @State private var error: String?
    var body: some View {
        Section {
            Toggle("Content Blocking", isOn: $service.contentEnabled)
            Button(L10n.string("Import Rules…")) { importing = true }
                .help(L10n.string("Import a UTF-8 text file with one blocked domain per line."))
                .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
                    Task {
                        do {
                            guard let url = try result.get().first else { return }
                            let data = try await Task.detached(priority: .userInitiated) {
                                let scoped = url.startAccessingSecurityScopedResource()
                                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                                let handle = try FileHandle(forReadingFrom: url)
                                defer { try? handle.close() }
                                return try handle.read(upToCount: 1_048_577) ?? Data()
                            }.value
                            try service.importContentRules(data); importError = nil
                        } catch { importError = L10n.string("Choose a UTF-8 text file up to 1 MB, with one domain per line (maximum 500 total). Existing rules were kept.") }
                    }
                }
            if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            Text(L10n.string("Off by default. Block domains you choose; excluded sites bypass your custom rules.")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.string("Rules format: UTF-8 plain text (.txt), one domain per line, such as example.com. Do not include https://, paths, or filter syntax. Subdomains are included. Maximum 1 MB and 500 domains."))
                .font(.caption).foregroundStyle(.secondary)
            if service.contentEnabled { Text(service.contentStatus).font(.caption).foregroundStyle(.secondary) }
        }
        Section {
            HStack {
                Text("Excluded Sites")
                Spacer()
                Button(editing ? "Save" : "Edit…") {
                    if editing {
                        do {
                            try service.saveContentExcludedSites(domains)
                            error = nil; editing = false
                        } catch {
                            self.error = L10n.string("Enter valid domains only, one per line (maximum 500).")
                        }
                    } else {
                        domains = service.contentExcludedSites.joined(separator: "\n")
                        error = nil; editing = true
                    }
                }.accessibilityLabel(editing ? "Save Exclusions" : "Edit excluded sites")
            }
            Text(L10n.string("Add sites here or turn off Content Blocking in the site privacy popover. Both update the same exclusion list."))
                .font(.caption).foregroundStyle(.secondary)
            if editing {
                Text(L10n.string("One hostname per line, without https:// or a path. Matches the exact hostname, not its subdomains. Up to 500 sites."))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $domains).font(.body.monospaced()).frame(height: 120).accessibilityLabel("Excluded sites")
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } else if !service.contentExcludedSites.isEmpty {
                Text(verbatim: service.contentExcludedSites.joined(separator: "\n"))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        Section {
            Toggle("Ad Blocking", isOn: $service.adsEnabled)
            Text(L10n.string("Downloads EasyList and EasyPrivacy from easylist.to when enabled. Supported network filters refresh daily; unsupported filters are skipped. No filter lists are bundled."))
                .font(.caption).foregroundStyle(.secondary)
            if service.adsEnabled {
                HStack {
                    if service.updating {
                        FilterUpdateProgress(fraction: service.updateProgress)
                    }
                    Text(service.updating ? service.updateStage : service.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Update Now") { service.refreshIfNeeded(force: true) }.disabled(service.updating)
                }
            }
            Text(L10n.string("Site exceptions are available from Site Information. Reload open pages after changing blocking settings.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct SiteBlockingControls: View {
    let service: BlockingService
    let host: String
    let isPrivate: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(BlockingKind.allCases, id: \.self) { kind in
                Toggle(kind == .content ? "Content Blocking" : "Ad Blocking", isOn: Binding(
                    get: { _ = service.revision; return service.enabled(kind) && !service.allowsSite(host, kind: kind) },
                    set: { service.setAllowed(!$0, host: host, kind: kind) }
                )).disabled(!service.enabled(kind) || isPrivate)
            }
            Text(isPrivate ? L10n.string("Change saved site exceptions in a regular window.") : L10n.string("Applies to this hostname. Enable each blocker in Privacy settings first. Reload to apply changes."))
                .font(.caption).foregroundStyle(.secondary)
        }.toggleStyle(.switch)
    }
}

private struct FilterUpdateProgress: View {
    let fraction: Double?
    var body: some View {
        Group {
            if let fraction {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.2), lineWidth: 2)
                    Circle().trim(from: 0, to: fraction).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Filter download progress")
                .accessibilityValue("\(Int(fraction * 100)) percent")
                .help("\(Int(fraction * 100))%")
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Preparing filters")
            }
        }.frame(width: 16, height: 16)
    }
}
