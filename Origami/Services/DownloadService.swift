import AppKit
import WebKit
import Observation

@MainActor @Observable
final class DownloadService: NSObject, WKDownloadDelegate {
    private struct Transfer {
        let download: WKDownload
        var record: DownloadRecord
        var observation: NSKeyValueObservation?
        var lastWrite = Date.distantPast
        var originURL: URL?
        var downloadURL: URL?
        var accessURL: URL?
    }
    private let preferences: BrowserPreferences?
    private let repository: DownloadRepository
    @ObservationIgnored private var transfers: [ObjectIdentifier: Transfer] = [:] {
        didSet {
            let profiles = Set(transfers.values.filter { $0.record.state == .running }.map { $0.record.profileID })
            if profiles != runningProfiles { runningProfiles = profiles }
        }
    }
    private(set) var runningProfiles: Set<UUID> = []
    var onError: ((String) -> Void)?
    var windowForTab: ((UUID) -> NSWindow?)?
    init(repository: DownloadRepository, preferences: BrowserPreferences? = nil) { self.repository = repository; self.preferences = preferences }
    func accept(_ download: WKDownload, profileID: UUID, tabID: UUID) {
        let record = DownloadRecord(profileID: profileID, tabID: tabID, url: DownloadQuarantine.metadataURL(download.originalRequest?.url)?.absoluteString ?? "")
        transfers[ObjectIdentifier(download)] = Transfer(download: download, record: record, originURL: DownloadQuarantine.metadataURL(download.webView?.url), downloadURL: DownloadQuarantine.metadataURL(download.originalRequest?.url))
        download.delegate = self
        persist(record)
    }
    func hasActiveDownload(tabID: UUID) -> Bool { transfers.values.contains { $0.record.tabID == tabID } }
    func cancel(profileID: UUID) {
        let ids = transfers.filter { $0.value.record.profileID == profileID }.map(\.key)
        for id in ids {
            guard let transfer = transfers.removeValue(forKey: id) else { continue }
            transfer.download.delegate = nil
            transfer.download.cancel { _ in }
            transfer.accessURL?.stopAccessingSecurityScopedResource()
        }
    }
    func cancelAll() {
        for transfer in transfers.values {
            transfer.download.delegate = nil
            transfer.download.cancel { _ in }
            transfer.accessURL?.stopAccessingSecurityScopedResource()
        }
        transfers.removeAll()
    }
    func cancel(_ id: UUID) {
        guard let transfer = transfers.values.first(where: { $0.record.id == id }) else { return }
        transfer.download.cancel { [weak self] _ in self?.finish(transfer.download, state: .cancelled) }
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard var transfer = transfers[ObjectIdentifier(download)], let window = download.webView?.window ?? transfer.record.tabID.flatMap({ windowForTab?($0) }) else {
            completionHandler(nil); finish(download, state: .cancelled); return
        }
        let filename = (suggestedFilename as NSString).lastPathComponent
        transfer.record.filename = filename.isEmpty || [".", ".."].contains(filename) ? "Download" : filename
        transfer.downloadURL = DownloadQuarantine.metadataURL(response.url) ?? transfer.downloadURL
        transfer.record.expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        transfers[ObjectIdentifier(download)] = transfer
        if preferences?.askDownloadDestination == false, let data = preferences?.downloadDirectoryBookmark {
            do {
                var stale = false
                let directory = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                guard !stale, directory.startAccessingSecurityScopedResource() else { throw RepositoryError.invalidInput }
                transfer.accessURL = directory
                let reserved = Set(transfers.values.compactMap { $0.record.destination })
                let url = Self.availableDestination(directory: directory, filename: transfer.record.filename, reserved: reserved)
                transfer.record.destination = url.path; transfer.record.state = .running
                transfer.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak download] _, _ in
                    Task { @MainActor [weak self, weak download] in if let download { self?.updateProgress(download) } }
                }
                transfers[ObjectIdentifier(download)] = transfer; persist(transfer.record); completionHandler(url); return
            } catch { onError?("Choose a download folder again to allow access.") }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = transfer.record.filename
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self else { completionHandler(nil); return }
            guard result == .OK, let url = panel.url, var transfer = self.transfers[ObjectIdentifier(download)] else {
                completionHandler(nil); self.finish(download, state: .cancelled); return
            }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                completionHandler(nil); self.finish(download, state: .failed, error: "Choose a filename that does not already exist."); return
            }
            if url.startAccessingSecurityScopedResource() { transfer.accessURL = url }
            transfer.record.destination = url.path
            transfer.record.bookmark = try? url.bookmarkData(options: .withSecurityScope)
            transfer.record.state = .running
            transfer.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak download] _, _ in
                Task { @MainActor [weak self, weak download] in if let download { self?.updateProgress(download) } }
            }
            self.transfers[ObjectIdentifier(download)] = transfer
            self.persist(transfer.record)
            completionHandler(url)
        }
    }
    private func updateProgress(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard var transfer = transfers[key] else { return }
        transfer.record.received = download.progress.completedUnitCount
        if download.progress.totalUnitCount > 0 { transfer.record.expected = download.progress.totalUnitCount }
        if Date().timeIntervalSince(transfer.lastWrite) >= 0.5 {
            persist(transfer.record); transfer.lastWrite = Date()
        }
        transfers[key] = transfer
    }
    func downloadDidFinish(_ download: WKDownload) { finish(download, state: .completed) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, state: .failed, error: "The download failed. Try again.")
    }
    private func finish(_ download: WKDownload, state: DownloadState, error: String? = nil) {
        guard var transfer = transfers.removeValue(forKey: ObjectIdentifier(download)) else { return }
        transfer.record.state = state; transfer.record.error = error
        if state == .completed {
            Self.verifyCompletion(&transfer.record, downloadURL: transfer.downloadURL, originURL: transfer.originURL)
        }
        transfer.record.received = max(transfer.record.received, download.progress.completedUnitCount)
        if let path = transfer.record.destination, transfer.record.state == .completed {
            transfer.record.bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: .withSecurityScope)
        }
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
        guard !stale else { throw RepositoryError.invalidInput }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Older records and files whose metadata was removed also pass the gate before explicit Open.
        try DownloadQuarantine.enforce(at: url, downloadURL: URL(string: record.url), originURL: nil)
        NSWorkspace.shared.open(url)
    }
    func reveal(_ record: DownloadRecord) throws {
        guard let data = record.bookmark else { throw RepositoryError.invalidInput }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        guard !stale, url.startAccessingSecurityScopedResource() else { throw RepositoryError.invalidInput }
        defer { url.stopAccessingSecurityScopedResource() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
