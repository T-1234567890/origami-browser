import AppKit
import Observation
import PDFKit
import WebKit
import UniformTypeIdentifiers

/// A viewing transfer, not a user download. WebKit supplies the original response body,
/// including cookies, redirects and POST results; this class never refetches its URL.
@MainActor @Observable final class PDFTabContent: NSObject, WKDownloadDelegate, PDFDocumentDelegate, PDFViewDelegate {
    let sourceURL: URL
    let isPrivate: Bool
    var requiresResubmission = false
    private(set) var filename: String
    private(set) var document: PDFDocument?
    private(set) var loading = true
    var error: String?
    var sidebarVisible = false
    var searchVisible = false
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    var matches: [PDFSelection] = []
    var matchIndex = 0
    var pageNumber = 1
    var locked = false
    @ObservationIgnored let view = BrowserPDFView()
    @ObservationIgnored private var download: WKDownload?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private(set) var fileURL: URL?
    @ObservationIgnored var changed: (() -> Void)?
    @ObservationIgnored var didSave: ((URL) -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var disposed = false
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var sharingPicker: NSSharingServicePicker?
    @ObservationIgnored private var originalRotations: [Int: Int] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchedQuery = ""

    static func isPDF(_ response: URLResponse) -> Bool {
        let mime = response.mimeType?.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if mime == "application/pdf" || mime == "application/x-pdf" { return true }
        // Never override an explicit HTML/error response just because its URL ends in .pdf.
        return (mime.isEmpty || mime == "application/octet-stream") && response.url?.pathExtension.lowercased() == "pdf"
    }

    static func pdfFilename(_ suggested: String) -> String {
        var name = DownloadService.filename(suggested, mime: "application/pdf")
        if name.utf8.count > 220 { name = String(name.prefix(70)) }
        if (name as NSString).pathExtension.lowercased() != "pdf" { name += ".pdf" }
        return name
    }

    init(response: URLResponse, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        sourceURL = response.url ?? URL(string: "about:blank")!
        filename = Self.pdfFilename(response.suggestedFilename ?? "Document.pdf")
        super.init()
        view.delegate = self
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let page = self.view.currentPage, let document = self.document else { return }
                self.pageNumber = document.index(for: page) + 1
            }
        }
    }
    func duplicate() throws -> PDFTabContent {
        guard let fileURL, document != nil else { throw CocoaError(.fileReadUnknown) }
        let copy = PDFTabContent(response: URLResponse(url: sourceURL, mimeType: "application/pdf", expectedContentLength: 0, textEncodingName: nil), isPrivate: isPrivate)
        copy.filename = filename; copy.requiresResubmission = requiresResubmission
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Origami-PDF-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        copy.directory = folder
        let file = folder.appendingPathComponent(filename)
        do { try FileManager.default.copyItem(at: fileURL, to: file) }
        catch { copy.dispose(); throw error }
        copy.fileURL = file; copy.open(file)
        return copy
    }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { view.openLink?(url) }
    }
    func accept(_ download: WKDownload) {
        guard !disposed else { download.cancel { _ in }; return }
        self.download = download
        download.delegate = self
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !disposed else { completionHandler(nil); return }
        do {
            filename = Self.pdfFilename(suggestedFilename)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Origami-PDF-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = folder
            let file = folder.appendingPathComponent(filename)
            fileURL = file
            completionHandler(file)
        } catch { fail(); completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        self.download = nil
        guard !disposed, let fileURL else { return }
        open(fileURL)
    }
    private func open(_ url: URL) {
        openTask = Task { [weak self] in
            // Transfer ownership once: PDFKit parsing happens off the UI thread, and
            // the returned document is subsequently used only on the main actor.
            let loaded = await Task.detached(priority: .userInitiated) { LoadedPDF(document: PDFDocument(url: url)) }.value
            guard let self, !self.disposed, !Task.isCancelled else { return }
            guard let pdf = loaded.document, pdf.isLocked || pdf.pageCount > 0 else { self.fail(); return }
            self.document = pdf; pdf.delegate = self; self.locked = pdf.isLocked; self.loading = false
            self.view.document = pdf
            self.changed?()
        }
    }
    func unlock(_ password: String) -> Bool {
        guard let document, document.unlock(withPassword: password) else { return false }
        locked = false; view.document = document; view.autoScales = true
        return true
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { self.download = nil; fail() }
    private func fail() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; fileURL = nil
        loading = false
        error = L10n.string("The PDF could not be opened. It may be damaged or the download failed.")
        changed?()
    }
    func dispose() {
        disposed = true
        openTask?.cancel(); openTask = nil
        searchTask?.cancel(); searchTask = nil
        changed = nil
        didSave = nil
        view.openLink = nil
        sharingPicker = nil
        document?.cancelFindString()
        matches = []; view.document = nil; document = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        let folder = directory
        directory = nil; fileURL = nil
        if let download {
            self.download = nil
            download.cancel { _ in if let folder { try? FileManager.default.removeItem(at: folder) } }
        } else if let folder { try? FileManager.default.removeItem(at: folder) }
    }
    func zoom(_ increasing: Bool) { view.fitsWidth = false; if increasing { view.zoomIn(nil) } else { view.zoomOut(nil) } }
    func fitPage() { view.fitsWidth = false; view.displayMode = .singlePage; view.autoScales = true }
    func fitWidth() {
        view.displayMode = .singlePageContinuous
        view.autoScales = false; view.fitsWidth = true; view.fitCurrentWidth()
    }
    func search() {
        searchTask?.cancel(); searchTask = nil
        clearSearch()
        searchedQuery = query
        if !query.isEmpty { document?.beginFindString(query, withOptions: .caseInsensitive) }
    }
    private func clearSearch() {
        searchedQuery = ""
        document?.cancelFindString()
        matches = []; matchIndex = 0; view.clearSelection()
        view.highlightedSelections = nil
    }
    private func scheduleSearch() {
        searchTask?.cancel()
        clearSearch()
        guard !query.isEmpty, !disposed else { return }
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }
    func didMatchString(_ instance: PDFSelection) {
        guard !searchedQuery.isEmpty, searchedQuery == query,
              let selection = instance.copy() as? PDFSelection else { return }
        matches.append(selection)
        if matches.count == 1 { selectMatch() }
    }
    func nextMatch(_ offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count; selectMatch()
    }
    private func selectMatch() {
        guard matches.indices.contains(matchIndex) else { view.clearSelection(); return }
        let selection = matches[matchIndex]
        // Keep search highlighting separate from the editable text selection. Draw
        // each matching line, rather than animating a single enclosing rectangle.
        let lines = selection.selectionsByLine()
        for line in lines { line.color = .findHighlightColor }
        view.clearSelection()
        view.highlightedSelections = lines
        view.go(to: selection)
    }
    func rotate(_ amount: Int) {
        guard let page = view.currentPage, let document else { return }
        let index = document.index(for: page)
        if originalRotations[index] == nil { originalRotations[index] = page.rotation }
        page.rotation = (page.rotation + amount + 360) % 360
        view.layoutDocumentView()
    }
    func resetView() {
        for (index, rotation) in originalRotations { document?.page(at: index)?.rotation = rotation }
        originalRotations.removeAll()
        view.fitsWidth = false
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.layoutDocumentView()
    }
    /// Copy the original bytes, never PDFDocument.write (which serializes edits).
    func saveOriginal(to destination: URL) throws {
        guard let fileURL, !loading, document != nil else { throw CocoaError(.fileReadUnknown) }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        // Ask Foundation for a writable replacement directory on the target volume.
        // A save-panel grant to one file does not grant arbitrary sibling-file access.
        let replacement = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        let staging = replacement.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: replacement) }
        try FileManager.default.copyItem(at: fileURL, to: staging)
        try DownloadQuarantine.enforce(at: staging, downloadURL: isPrivate ? nil : sourceURL, originURL: nil)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging, options: .usingNewMetadataOnly)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        didSave?(destination)
    }
    func save() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = filename
        let completion: (NSApplication.ModalResponse) -> Void = { [self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try saveOriginal(to: url) } catch { self.error = L10n.string("The PDF could not be saved. Please try again.") }
        }
        if let window = view.window, window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    func printDocument() {
        guard !locked, let document, document.allowsPrinting else { return }
        view.print(with: NSPrintInfo.shared.copy() as! NSPrintInfo, autoRotate: true)
    }
    func openInPreview() {
        guard let fileURL, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        do {
            try DownloadQuarantine.enforce(at: fileURL, downloadURL: isPrivate ? nil : sourceURL, originURL: nil)
            NSWorkspace.shared.open([fileURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } catch { self.error = L10n.string("The PDF could not be opened externally.") }
    }
    func share() {
        guard let fileURL else { return }
        do {
            try DownloadQuarantine.enforce(at: fileURL, downloadURL: isPrivate ? nil : sourceURL, originURL: nil)
            let picker = NSSharingServicePicker(items: [fileURL])
            sharingPicker = picker
            picker.show(relativeTo: NSRect(x: view.bounds.maxX - 40, y: view.bounds.maxY - 30, width: 1, height: 1), of: view, preferredEdge: .minY)
        } catch { self.error = L10n.string("The PDF could not be opened externally.") }
    }
}

/// Only internal page destinations and web links are actionable. Never launch a local
/// file, external PDF, JavaScript action, or arbitrary URL scheme from an untrusted PDF.
private struct LoadedPDF: @unchecked Sendable { let document: PDFDocument? }

@MainActor final class BrowserPDFView: PDFView {
    var openLink: ((URL) -> Void)?
    var fitsWidth = false
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitsWidth { fitCurrentWidth() }
    }
    func fitCurrentWidth() {
        guard let page = currentPage else { return }
        let bounds = page.bounds(for: displayBox)
        let width = page.rotation % 180 == 0 ? bounds.width : bounds.height
        let scale = max(0.1, (self.bounds.width - 24) / max(1, width))
        if abs(scaleFactor - scale) > 0.001 { scaleFactor = scale }
    }
    override func perform(_ action: PDFAction) {
        if let link = action as? PDFActionURL {
            if let url = link.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { openLink?(url) }
        } else if action is PDFActionGoTo { super.perform(action) }
    }
}
