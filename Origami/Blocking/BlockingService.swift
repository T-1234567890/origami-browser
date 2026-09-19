import WebKit
import Observation

/// Owns two independent compiled lists. Never removes another subsystem's rule lists.
@MainActor @Observable final class BlockingService {
    typealias Downloader = @Sendable (URL) async throws -> String
    var contentEnabled: Bool { didSet { preferences.contentBlocking = contentEnabled; changed() } }
    var adsEnabled: Bool { didSet {
        preferences.adBlocking = adsEnabled
        if !adsEnabled { updateTask?.cancel() }
        else { lastAttempt = nil }
        changed()
    } }
    var contentExcludedSites: [String] { preferences.blockingExceptions(.content) }
    func saveContentExcludedSites(_ text: String) throws {
        let hosts = Array(Set(text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
        guard hosts.count <= 500, hosts.allSatisfy(FilterConverter.validHost) else { throw FilterDownloads.Failure.invalidResponse }
        preferences.setBlockingExceptions(hosts, kind: .content)
        changed()
    }
    var contentDomains: [String] { preferences.contentBlockingDomains }
    func saveContentDomains(_ text: String) throws {
        let domains = Array(Set(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
        guard domains.count <= 500, domains.allSatisfy(FilterConverter.validHost) else { throw FilterDownloads.Failure.invalidResponse }
        preferences.contentBlockingDomains = domains; changed()
    }
    private(set) var status = "Off"
    private(set) var contentStatus = "Off"
    private(set) var updating = false
    private(set) var updateProgress: Double?
    private(set) var updateStage = ""
    func importContentRules(_ data: Data) throws {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw FilterDownloads.Failure.invalidResponse }
        try saveContentDomains((contentDomains + [text.replacingOccurrences(of: "\u{FEFF}", with: "")]).joined(separator: "\n"))
    }
    private(set) var revision = 0
    @ObservationIgnored private let preferences: BrowserPreferences
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let compiler: WKContentRuleListStore?
    @ObservationIgnored private let downloader: Downloader?
    @ObservationIgnored private let temporary: Bool
    @ObservationIgnored private var controllers = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private var lists: [BlockingKind: WKContentRuleList] = [:]
    @ObservationIgnored private var snapshot: FilterSnapshot?
    @ObservationIgnored private var readyTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAttempt: Date?

    init(preferences: BrowserPreferences, directory: URL? = nil, persistent: Bool = false,
         downloader: Downloader? = nil) {
        self.preferences = preferences; self.downloader = downloader
        contentEnabled = preferences.contentBlocking; adsEnabled = preferences.adBlocking
        temporary = directory == nil && !persistent
        self.directory = directory ?? (persistent
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Origami/DownloadedFilters")
            : FileManager.default.temporaryDirectory.appending(path: "OrigamiFilters-" + UUID().uuidString))
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.directory.appending(path: "Compiled"), withIntermediateDirectories: true)
        compiler = WKContentRuleListStore(url: self.directory.appending(path: "Compiled"))
        readyTask = Task { [weak self] in await self?.restore() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfNeeded() }
        }
    }
    deinit {
        timer?.invalidate(); readyTask?.cancel(); updateTask?.cancel(); rebuildTask?.cancel()
        if temporary { try? FileManager.default.removeItem(at: directory) }
    }
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        for (kind, list) in lists where enabled(kind) { controller.add(list) }
    }
    /// Navigation waits only for local restoration/compilation, never subscription downloads.
    func prepare() async { await readyTask?.value; await rebuildTask?.value }
    func enabled(_ kind: BlockingKind) -> Bool { kind == .content ? contentEnabled : adsEnabled }
    func allowsSite(_ host: String, kind: BlockingKind) -> Bool { preferences.blockingExceptions(kind).contains(host.lowercased()) }
    func setAllowed(_ allowed: Bool, host: String, kind: BlockingKind) {
        let host = host.lowercased()
        guard FilterConverter.validHost(host) else { return }
        var values = Set(preferences.blockingExceptions(kind))
        if allowed { guard values.count < 500 else { return }; values.insert(host) } else { values.remove(host) }
        preferences.setBlockingExceptions(values.sorted(), kind: kind); changed()
    }
    private func changed() {
        revision += 1
        for controller in controllers.allObjects {
            for (kind, list) in lists where !enabled(kind) { controller.remove(list) }
        }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            await readyTask?.value
            guard !Task.isCancelled else { return }
            await rebuild()
            refreshIfNeeded()
        }
    }
    private func restore() async {
        let file = directory.appending(path: "filters.json")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 80_000_000,
           let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(FilterSnapshot.self, from: data),
           cached.rules.count <= 120_000, cached.originals.count == 2 {
            snapshot = cached
        }
        await rebuild()
        // Compiled lists are disposable; the atomic JSON snapshot is the last-good source.
        if let compiler {
            let identifiers: [String] = await withCheckedContinuation { continuation in
                compiler.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
            }
            let active = Set(lists.values.map(\.identifier))
            for id in identifiers where id.hasPrefix("origami-") && !active.contains(id) {
                try? await compiler.removeContentRuleList(forIdentifier: id)
            }
        }
        refreshIfNeeded()
    }
    private func compile(_ rules: [BlockingRule], kind: BlockingKind) async throws -> WKContentRuleList {
        guard let compiler else { throw FilterDownloads.Failure.invalidResponse }
        let exceptions = preferences.blockingExceptions(kind).filter(FilterConverter.validHost).prefix(500).map { BlockingRule.exception(host: $0) }
        let input = rules + exceptions
        let json = try await Task.detached(priority: .utility) {
            String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        }.value
        guard let list = try await compiler.compileContentRuleList(forIdentifier: "origami-" + kind.rawValue + "-" + UUID().uuidString, encodedContentRuleList: json) else { throw FilterDownloads.Failure.invalidResponse }
        return list
    }
    private func discard(_ list: WKContentRuleList) { compiler?.removeContentRuleList(forIdentifier: list.identifier) { _ in } }
    private func install(_ list: WKContentRuleList, kind: BlockingKind) {
        let old = lists[kind]; lists[kind] = list
        for controller in controllers.allObjects {
            if let old { controller.remove(old) }
            if enabled(kind) { controller.add(list) }
        }
        if let old { discard(old) }
    }
    private func rebuild() async {
        let generation = revision
        if contentEnabled && !contentDomains.isEmpty {
            do {
                let list = try await compile(UserContentRules.rules(domains: contentDomains), kind: .content)
                guard generation == revision, !Task.isCancelled else { discard(list); return }
                install(list, kind: .content); contentStatus = "On — \(contentDomains.count) custom domains"
            } catch { contentStatus = "Content rules couldn’t be prepared." }
        } else {
            if let old = lists.removeValue(forKey: .content) {
                for controller in controllers.allObjects { controller.remove(old) }
                discard(old)
            }
            contentStatus = contentEnabled ? "No custom rules. Nothing is blocked." : "Off"
        }
        if adsEnabled, let snapshot {
            do {
                let list = try await compile(snapshot.rules, kind: .ads)
                guard generation == revision, !Task.isCancelled else { discard(list); return }
                install(list, kind: .ads)
                status = "Updated " + snapshot.updated.formatted(date: .abbreviated, time: .omitted) + ". Unsupported rules skipped: \(snapshot.skipped)."
            } catch { status = "Ad rules couldn’t be prepared. Existing rules remain active if available." }
        } else { status = adsEnabled ? "Preparing filter lists…" : "Off" }
    }
    func refreshIfNeeded(force: Bool = false) {
        guard adsEnabled, updateTask == nil,
              force || (Date().timeIntervalSince(snapshot?.updated ?? .distantPast) >= 86400 && Date().timeIntervalSince(lastAttempt ?? .distantPast) >= 3600) else { return }
        lastAttempt = Date(); updating = true; updateProgress = nil; updateStage = "Connecting…"
        updateTask = Task { [weak self] in
            guard let self else { return }
            var retryForChangedSettings = false
            defer {
                updating = false; updateTask = nil; updateProgress = nil
                if retryForChangedSettings || (adsEnabled && Task.isCancelled) { refreshIfNeeded(force: true) }
            }
            do {
                var originals: [String] = []
                for (index, url) in FilterDownloads.sources.enumerated() {
                    updateProgress = nil
                    updateStage = index == 0 ? "Downloading EasyList (1 of 2)…" : "Downloading EasyPrivacy (2 of 2)…"
                    if let downloader { originals.append(try await downloader(url)) }
                    else {
                        originals.append(try await FilterDownloads.fetch(url) { [weak self] fraction in
                            self?.updateProgress = fraction
                        })
                    }
                }
                updateProgress = nil; updateStage = "Converting filters…"
                let input = originals
                let conversion = try await Task.detached(priority: .utility) { try FilterConverter.convert(input) }.value
                let candidate = FilterSnapshot(originals: originals, rules: conversion.rules, updated: Date(), skipped: conversion.skipped, attribution: FilterDownloads.notice)
                // Compile first; a malformed update never replaces the last working snapshot.
                updateStage = "Compiling filters…"
                let generation = revision
                let list = try await compile(candidate.rules, kind: .ads)
                guard generation == revision, adsEnabled else {
                    discard(list); retryForChangedSettings = adsEnabled; return
                }
                do {
                    let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(candidate) }.value
                    guard generation == revision, adsEnabled, !Task.isCancelled else {
                        discard(list); retryForChangedSettings = adsEnabled; return
                    }
                    try data.write(to: directory.appending(path: "filters.json"), options: .atomic)
                } catch { discard(list); throw error }
                snapshot = candidate; install(list, kind: .ads)
                status = "Updated " + candidate.updated.formatted(date: .abbreviated, time: .omitted) + ". Unsupported rules skipped: \(candidate.skipped)."
            } catch {
                if adsEnabled { status = lists[.ads] == nil ? "Download or compilation failed. No ad rules are active yet." : "Update failed. Keeping the last working ad rules." }
            }
        }
    }
    func waitForUpdate() async { await updateTask?.value }
}
