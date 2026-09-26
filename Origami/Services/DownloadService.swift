import AppKit
import WebKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class DownloadService: NSObject, WKDownloadDelegate, NSOpenSavePanelDelegate {
    private struct Transfer {
        let download: WKDownload
        let sourceWebView: WKWebView?
        var record: DownloadRecord
        var observation: NSKeyValueObservation?
        var lastWrite = Date.distantPast
        var originURL: URL?
        var downloadURL: URL?
        var accessURL: URL?
        var stagingURL: URL?
        var cancelled = false
        var panel: NSSavePanel?
        var destinationReply: ((URL?) -> Void)?
    }
    private let preferences: BrowserPreferences?
    private let repository: DownloadRepository
    @ObservationIgnored private var transfers: [ObjectIdentifier: Transfer] = [:] {
        didSet {
            let previous = Set(oldValue.values.filter { $0.record.state == .running }.map { $0.record.id })
            for transfer in transfers.values where transfer.record.state == .running && !previous.contains(transfer.record.id) {
                startsByProfile[transfer.record.profileID, default: 0] += 1
            }
            let profiles = Set(transfers.values.filter { $0.record.state == .running }.map { $0.record.profileID })
            if profiles != runningProfiles { runningProfiles = profiles }
        }
    }
    private(set) var startsByProfile: [UUID: Int] = [:]
    private(set) var runningProfiles: Set<UUID> = []
    @ObservationIgnored private var retryRequests: [UUID: (profile: UUID, request: URLRequest)] = [:]
    @ObservationIgnored private var retryOrder: [UUID] = []
    var onError: ((String) -> Void)?
    var destinationSelector: ((String) async -> URL?)?
    var windowForTab: ((UUID) -> NSWindow?)?
    init(repository: DownloadRepository, preferences: BrowserPreferences? = nil) { self.repository = repository; self.preferences = preferences }
    func accept(_ download: WKDownload, profileID: UUID, tabID: UUID, sourceWebView: WKWebView? = nil) {
        guard transfers[ObjectIdentifier(download)] == nil else { return }
        let record = DownloadRecord(profileID: profileID, tabID: tabID, url: DownloadQuarantine.metadataURL(download.originalRequest?.url)?.absoluteString ?? "")
        if let request = download.originalRequest {
            retryRequests[record.id] = (profileID, request); retryOrder.append(record.id)
            if retryOrder.count > 100 { retryRequests.removeValue(forKey: retryOrder.removeFirst()) }
        }
        transfers[ObjectIdentifier(download)] = Transfer(download: download, sourceWebView: sourceWebView ?? download.webView, record: record, originURL: DownloadQuarantine.metadataURL((sourceWebView ?? download.webView)?.url), downloadURL: DownloadQuarantine.metadataURL(download.originalRequest?.url))
        download.delegate = self
        persist(record)
    }
    /// Signed query strings and request details stay in memory only. Persisted
    /// history remains sanitized; after relaunch Retry restarts the saved URL.
    func retryRequest(for record: DownloadRecord) -> URLRequest? {
        if let request = retryRequests[record.id]?.request, ["http", "https"].contains(request.url?.scheme) { return request }
        guard let url = URL(string: record.url), ["http", "https"].contains(url.scheme) else { return nil }
        return URLRequest(url: url)
    }
    func hasActiveDownload(tabID: UUID) -> Bool { transfers.values.contains { $0.record.tabID == tabID } }
    func cancel(profileID: UUID) {
        retryRequests = retryRequests.filter { $0.value.profile != profileID }
        retryOrder.removeAll { retryRequests[$0] == nil }
        for id in transfers.values.filter({ $0.record.profileID == profileID }).map({ $0.record.id }) { cancel(id) }
    }
    func cancelAll() {
        retryRequests.removeAll(); retryOrder.removeAll()
        for id in transfers.values.map({ $0.record.id }) { cancel(id) }
    }
    func cancel(_ id: UUID) {
        guard let key = transfers.first(where: { $0.value.record.id == id })?.key,
              var transfer = transfers[key], !transfer.cancelled else { return }
        transfer.cancelled = true
        let reply = transfer.destinationReply
        transfer.destinationReply = nil
        transfers[key] = transfer
        transfer.panel?.cancel(nil)
        reply?(nil)
        // Retain the service and scoped access until WebKit acknowledges cancellation.
        transfer.download.cancel { [self] _ in finish(transfer.download, state: .cancelled) }
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard var transfer = transfers[ObjectIdentifier(download)], !transfer.cancelled else {
            completionHandler(nil); finish(download, state: .cancelled); return
        }
        transfer.record.filename = Self.filename(suggestedFilename, mime: response.mimeType)
        transfer.downloadURL = DownloadQuarantine.metadataURL(response.url) ?? transfer.downloadURL
        transfer.record.expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        transfers[ObjectIdentifier(download)] = transfer
        persist(transfer.record)
        if preferences?.askDownloadDestination == false, let data = preferences?.downloadDirectoryBookmark {
            do {
                var stale = false
                let directory = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                guard !stale, directory.startAccessingSecurityScopedResource() else { throw RepositoryError.invalidInput }
                transfer.accessURL = directory
                let reserved = Set(transfers.values.compactMap { $0.record.destination })
                let url = Self.availableDestination(directory: directory, filename: transfer.record.filename, reserved: reserved)
                transfer.record.filename = url.lastPathComponent
                transfer.record.destination = url.path; transfer.record.state = .running
                transfer.observation = observeProgress(download)
                transfers[ObjectIdentifier(download)] = transfer; persist(transfer.record); completionHandler(url); return
            } catch { onError?(L10n.string("Choose a download folder again to allow access.")) }
        }
        transfers[ObjectIdentifier(download)]?.destinationReply = completionHandler
        if let destinationSelector {
            let name = transfer.record.filename
            Task { @MainActor [self] in
                completeDestination(await destinationSelector(name), download: download)
            }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = transfer.record.filename
        panel.canCreateDirectories = true
        panel.delegate = self
        transfers[ObjectIdentifier(download)]?.panel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            self?.completeDestination(result == .OK ? panel.url : nil, download: download)
        }
        if let window = download.webView?.window ?? transfer.record.tabID.flatMap({ windowForTab?($0) }), window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            // Downloads outlive their source tab. A standalone panel also avoids
            // trying to attach a second save sheet during concurrent downloads.
            panel.begin(completionHandler: completion)
        }
    }
    func panel(_ sender: Any, validate url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              !transfers.values.contains(where: { $0.record.destination == url.path }) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                          userInfo: [NSLocalizedDescriptionKey: L10n.string("Choose a filename that does not already exist.")])
        }
    }
    private func completeDestination(_ selected: URL?, download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard var transfer = transfers[key], let reply = transfer.destinationReply else { return }
        transfer.destinationReply = nil; transfer.panel = nil
        transfers[key] = transfer
        guard let selected, !transfer.cancelled else {
            reply(nil); finish(download, state: .cancelled); return
        }
        if selected.startAccessingSecurityScopedResource() { transfer.accessURL = selected }
        let reserved = Set(transfers.values.compactMap { $0.record.destination })
        guard !reserved.contains(selected.path), !FileManager.default.fileExists(atPath: selected.path) else {
            transfer.accessURL?.stopAccessingSecurityScopedResource()
            reply(nil); finish(download, state: .failed, error: L10n.string("Choose a filename that does not already exist.")); return
        }
        // The save panel grants access to this exact URL, not arbitrary siblings.
        // Stage in our container and move without replacing any existing file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OrigamiDownload-" + UUID().uuidString)
        transfer.stagingURL = url
        transfer.record.filename = selected.lastPathComponent
        transfer.record.destination = selected.path
        transfer.record.state = .running
        transfer.observation = observeProgress(download)
        transfers[key] = transfer
        persist(transfer.record)
        reply(url)
    }
    static func filename(_ suggested: String, mime: String?) -> String {
        let leaf = (suggested as NSString).lastPathComponent
        let safe = leaf.components(separatedBy: .controlCharacters).joined().replacingOccurrences(of: ":", with: "-")
        var name = safe.isEmpty || [".", ".."].contains(safe) ? "Download" : safe
        if (name as NSString).pathExtension.isEmpty, let mime, let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name += "." + ext
        }
        return name
    }
    private func observeProgress(_ download: WKDownload) -> NSKeyValueObservation {
        download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak download] _, _ in
            Task { @MainActor [weak self, weak download] in
                if let download { self?.updateProgress(download) }
            }
        }
    }
    private func updateProgress(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard var transfer = transfers[key] else { return }
        transfer.record.received = max(0, download.progress.completedUnitCount)
        if download.progress.totalUnitCount > 0 { transfer.record.expected = download.progress.totalUnitCount }
        if Date().timeIntervalSince(transfer.lastWrite) >= 0.5 {
            persist(transfer.record); transfer.lastWrite = Date()
        }
        transfers[key] = transfer
    }
    func downloadDidFinish(_ download: WKDownload) { finish(download, state: .completed) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, state: .failed, error: L10n.string("The download failed. Try again."))
    }
    private func finish(_ download: WKDownload, state: DownloadState, error: String? = nil) {
        guard var transfer = transfers.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let finalState: DownloadState = transfer.cancelled ? .cancelled : state
        transfer.record.state = finalState; transfer.record.error = finalState == .cancelled ? nil : error
        transfer.observation?.invalidate()
        transfer.panel?.cancel(nil)
        transfer.destinationReply?(nil)
        if finalState == .completed, let staged = transfer.stagingURL, let destination = transfer.record.destination {
            do {
                try DownloadQuarantine.enforce(at: staged, downloadURL: transfer.downloadURL, originURL: transfer.originURL)
                try FileManager.default.moveItem(at: staged, to: URL(fileURLWithPath: destination))
            } catch {
                transfer.record.state = .failed
                transfer.record.error = L10n.string("The download failed. Try again.")
            }
        }
        if finalState == .completed && transfer.record.state == .completed {
            Self.verifyCompletion(&transfer.record, downloadURL: transfer.downloadURL, originURL: transfer.originURL)
        }
        transfer.record.received = max(transfer.record.received, download.progress.completedUnitCount)
        if let path = transfer.record.destination, transfer.record.state == .completed {
            transfer.record.bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: .withSecurityScope)
        }
        if let staged = transfer.stagingURL { try? FileManager.default.removeItem(at: staged) }
        persist(transfer.record)
        transfer.accessURL?.stopAccessingSecurityScopedResource()
        download.delegate = nil
        if let message = transfer.record.error { onError?(message) }
    }
    static func verifyCompletion(_ record: inout DownloadRecord, downloadURL: URL?, originURL: URL?) {
        do {
            guard let path = record.destination else { throw DownloadQuarantine.Failure.invalidDestination }
            try DownloadQuarantine.enforce(at: URL(fileURLWithPath: path), downloadURL: downloadURL, originURL: originURL)
            record.state = .completed; record.error = nil
        } catch {
            record.state = .failed
            record.error = DownloadQuarantine.Failure.verificationFailed.localizedDescription
        }
    }
    /// Register an explicit save of already-loaded content without downloading it again.
    /// The caller holds the save panel's security scope until this method returns.
    func recordSavedFile(at url: URL, sourceURL: URL?, profileID: UUID, tabID: UUID?) {
        do {
            try DownloadQuarantine.enforce(at: url, downloadURL: sourceURL, originURL: nil)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            var record = DownloadRecord(profileID: profileID, tabID: tabID,
                                        url: DownloadQuarantine.metadataURL(sourceURL)?.absoluteString ?? "")
            record.filename = url.lastPathComponent
            record.destination = url.path
            record.bookmark = try url.bookmarkData(options: .withSecurityScope)
            record.state = .completed
            record.received = size; record.expected = size
            try repository.save(record)
            startsByProfile[profileID, default: 0] += 1
        } catch {
            onError?("Download metadata could not be saved: \(error.localizedDescription)")
        }
    }
    private func persist(_ record: DownloadRecord) {
        do { try repository.save(record) } catch { onError?("Download metadata could not be saved: \(error.localizedDescription)") }
    }
    static func availableDestination(directory: URL, filename: String, reserved: Set<String> = []) -> URL {
        let safe = (filename as NSString).lastPathComponent
        let base = directory.appendingPathComponent(safe.isEmpty || [".", ".."].contains(safe) ? "Download" : safe)
        var candidate = base; var number = 1
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            let stem = base.deletingPathExtension().lastPathComponent
            let suffix = base.pathExtension.isEmpty ? "" : "." + base.pathExtension
            candidate = directory.appendingPathComponent("\(stem) (\(number))\(suffix)"); number += 1
        }
        return candidate
    }
    func open(_ record: DownloadRecord) throws {
        guard record.state == .completed, let data = record.bookmark else { throw RepositoryError.invalidInput }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw RepositoryError.invalidInput }
        if stale { refreshBookmark(record, url: url) }
        // Older records and files whose metadata was removed also pass the gate before explicit Open.
        try DownloadQuarantine.enforce(at: url, downloadURL: URL(string: record.url), originURL: nil)
        guard NSWorkspace.shared.open(url) else { throw RepositoryError.invalidInput }
    }
    func reveal(_ record: DownloadRecord) throws {
        guard let data = record.bookmark else { throw RepositoryError.invalidInput }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw RepositoryError.invalidInput }
        if stale { refreshBookmark(record, url: url) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    private func refreshBookmark(_ record: DownloadRecord, url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return }
        var refreshed = record
        refreshed.bookmark = bookmark; refreshed.destination = url.path
        persist(refreshed)
    }

}
