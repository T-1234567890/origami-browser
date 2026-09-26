import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

extension BrowserStore {
    var canPrintPage: Bool {
        if let pdf = visiblePage?.pdfContent { return pdf.document?.allowsPrinting == true && !pdf.locked }
        return canUsePageFileCommands
    }
    var canUsePageFileCommands: Bool {
        guard let page = visiblePage, page.nativePage == nil, page.pdfContent == nil, page.errorMessage == nil, !page.isLoading,
              let scheme = page.webView.url?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    func printCurrentPage() {
        if let pdf = visiblePage?.pdfContent { pdf.printDocument(); return }
        guard canUsePageFileCommands, let page = visiblePage else { return }
        guard let window = page.webView.window, window.attachedSheet == nil,
              pagePrintSession == nil else { return }
        page.webView.layoutSubtreeIfNeeded()
        let session = PagePrintSession(webView: page.webView) { [weak self] in self?.pagePrintSession = nil }
        pagePrintSession = session
        session.run(in: window)
    }

    func saveCurrentPage() {
        guard canUsePageFileCommands, let page = visiblePage else { return }
        // Capture the active page now so switching tabs cannot save a different document.
        let webView = page.webView
        let window = webView.window
        let generation = page.documentGeneration
        Task { @MainActor [weak self] in
            do {
                guard let html = try await webView.callAsyncJavaScript(PageHTMLExport.script, arguments: [:], in: nil, contentWorld: .defaultClient) as? String else {
                    throw RepositoryError.invalidInput
                }
                let archive: Data = try await withCheckedThrowingContinuation { continuation in
                    webView.createWebArchiveData { continuation.resume(with: $0) }
                }
                let completedExport = try await PageFolderExport.capture(in: webView, html: html, archive: archive)
                guard page.documentGeneration == generation else { throw RepositoryError.invalidInput }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = L10n.string("Save Page…")
                panel.message = L10n.string("Choose where to save the webpage folder. Open index.html inside it to view the saved page.")
                let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    guard response == .OK, let url = panel.url else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let destination = try completedExport.write(to: url)
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                        if !completedExport.missing.isEmpty {
                            self?.persistenceError = L10n.string("The page was saved, but some resources were unavailable. Parts of the saved page may be missing.")
                        }
                    } catch { self?.persistenceError = L10n.string("The webpage could not be saved. Please try again.") }
                }
                if let window, window.isVisible, window.attachedSheet == nil {
                    panel.beginSheetModal(for: window, completionHandler: save)
                } else {
                    panel.begin(completionHandler: save)
                }
            } catch {
                self?.persistenceError = L10n.string("The webpage could not be saved. Please try again.")
            }
        }
    }
}

/// Own the source and operation until AppKit finishes the sheet (including cancellation).
@MainActor final class PagePrintSession: NSObject {
    let webView: WKWebView
    let operation: NSPrintOperation
    private let completion: () -> Void
    init(webView: WKWebView, completion: @escaping () -> Void) {
        self.webView = webView
        self.completion = completion
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        operation = webView.printOperation(with: info)
        super.init()
        // WebKit computes pagination asynchronously. AppKit checks the initial frame
        // before that reply arrives, so seed its public print view with a valid page.
        if let view = operation.view, view.frame.isEmpty {
            let size = info.paperSize
            view.frame = NSRect(x: 0, y: 0, width: max(1, size.width), height: max(1, size.height))
        }
        operation.canSpawnSeparateThread = true
    }
    func run(in window: NSWindow) {
        operation.runModal(for: window, delegate: self,
            didRun: #selector(finished(_:success:context:)), contextInfo: nil)
    }
    @objc private func finished(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        completion()
    }
}

enum PageHTMLExport {
    // Serialize a clone, never mutate the live page or include current form values.
    // Base URL preserves relative links and remotely hosted resources in the saved file.
    static let script = PageSnapshot.script
}
