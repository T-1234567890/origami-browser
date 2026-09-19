import SwiftUI
import UniformTypeIdentifiers

struct BlockingSettings: View {
    @Bindable var service: BlockingService
    @State private var importing = false
    @State private var importError: String?
    @State private var editing = false
    @State private var editingExclusions = false
    @State private var domains = ""
    @State private var error: String?
    var body: some View {
        Section("Blocking") {
            Toggle("Content Blocking", isOn: $service.contentEnabled)
            Button("Import Rules…") { importing = true }
                .help("Import a UTF-8 text file with one blocked domain per line.")
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
                        } catch { importError = "Choose a UTF-8 text file up to 1 MB, with one domain per line (maximum 500 total). Existing rules were kept." }
                    }
                }
            if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            Text("Off by default. Block domains you choose; excluded sites bypass your custom rules.").font(.caption).foregroundStyle(.secondary)
            Button("Edit Custom Rules…") { domains = service.contentDomains.joined(separator: "\n"); editingExclusions = false; error = nil; editing = true }
            HStack {
                Text("Excluded Sites")
                Spacer()
                Button("Edit…") {
                    domains = service.contentExcludedSites.joined(separator: "\n")
                    editingExclusions = true; error = nil; editing = true
                }.accessibilityLabel("Edit excluded sites")
            }
            Text("Content Blocking is disabled on these sites. This list also reflects changes made in Site Information.")
                .font(.caption).foregroundStyle(.secondary)
            if editing {
                Text(editingExclusions ? "One hostname per line, without https:// or a path. Matches the exact hostname, not its subdomains. Up to 500 sites." : "One domain per line, without https:// or a path. Includes subdomains. Up to 500 domains.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $domains).font(.body.monospaced()).frame(height: 120).accessibilityLabel(editingExclusions ? "Excluded sites" : "Blocked domains")
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button(editingExclusions ? "Save Exclusions" : "Save Rules") {
                        do {
                            if editingExclusions { try service.saveContentExcludedSites(domains) }
                            else { try service.saveContentDomains(domains) }
                            error = nil; editing = false
                        }
                        catch { self.error = "Enter valid domains only, one per line (maximum 500)." }
                    }
                    Button("Cancel") { error = nil; editing = false }
                }
            }
            if service.contentEnabled { Text(service.contentStatus).font(.caption).foregroundStyle(.secondary) }
            Toggle("Ad Blocking", isOn: $service.adsEnabled)
            Text("Downloads EasyList and EasyPrivacy from easylist.to when enabled. Supported network filters refresh daily; unsupported filters are skipped. No filter lists are bundled.")
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
            Text("Site exceptions are available from Site Information. Reload open pages after changing blocking settings.").font(.caption).foregroundStyle(.secondary)
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
            Text(isPrivate ? "Change saved site exceptions in a regular window." : "Applies to this hostname. Enable each blocker in Privacy settings first. Reload to apply changes.")
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
