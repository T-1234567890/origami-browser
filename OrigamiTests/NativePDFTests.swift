import Testing
import PDFKit
import CoreText
import WebKit
@testable import Origami

@MainActor struct NativePDFTests {
    static func fixture(pages: Int = 2) throws -> Data {
        let bytes = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil); context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
            context.textPosition = CGPoint(x: 30, y: 200)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Origami PDF fixture", attributes: [.font: NSFont.systemFont(ofSize: 16)])), context)
            context.endPDFPage()
        }
        context.closePDF(); return bytes as Data
    }
    func waitForPDF(_ page: TabPage) async throws -> PDFTabContent {
        for _ in 0..<400 {
            if let pdf = page.pdfContent, !pdf.loading { return pdf }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try #require(page.pdfContent)
    }
    @Test func detectionUsesMIMEWithoutOverridingHTML() {
        func response(_ path: String, _ mime: String?) -> URLResponse {
            URLResponse(url: URL(string: "https://example.invalid/" + path)!, mimeType: mime, expectedContentLength: 0, textEncodingName: nil)
        }
        #expect(PDFTabContent.isPDF(response("download?id=123", "application/pdf")))
        #expect(PDFTabContent.isPDF(response("file.PDF", "application/octet-stream")))
        #expect(PDFTabContent.isPDF(response("file.pdf", nil)))
        #expect(!PDFTabContent.isPDF(response("file.pdf", "text/html")))
        #expect(!PDFTabContent.isPDF(response("download", "application/octet-stream")))
    }
    @Test(.timeLimit(.minutes(1))) func responseHandoffSaveHistoryAndCleanup() async throws {
        let services = try BrowserServices(database: DatabaseManager())
        let page = TabPage(services: services)
        defer { page.dispose() }
        let data = try Self.fixture()
        let url = try #require(URL(string: "data:application/pdf;base64," + data.base64EncodedString()))
        page.load(url)
        let pdf = try await waitForPDF(page)
        #expect(pdf.document?.pageCount == 2)
        #expect(pdf.error == nil)
        #expect(page.currentURL == url)
        #expect(try services.downloadRepository.list(profileID: BrowserProfile.defaultID).isEmpty)
        let source = try #require(pdf.fileURL)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("saved.pdf")
        try Data("old".utf8).write(to: saved)
        let currentPage = try #require(pdf.view.currentPage)
        let originalRotation = currentPage.rotation
        pdf.rotate(90)
        pdf.fitPage()
        pdf.resetView()
        #expect(currentPage.rotation == originalRotation)
        #expect(pdf.view.displayMode == .singlePageContinuous)
        #expect(pdf.view.autoScales)
        #expect(!pdf.view.fitsWidth)
        try pdf.saveOriginal(to: saved)
        #expect(try Data(contentsOf: saved) == data)
        let records = try services.downloadRepository.list(profileID: BrowserProfile.defaultID)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.state == .completed)
        #expect(record.filename == "saved.pdf")
        #expect(record.destination == saved.path)
        #expect(record.tabID == page.tabID)
        #expect(record.received == Int64(data.count))
        #expect(record.expected == record.received)
        #expect(record.bookmark != nil)
        #expect(services.downloads.startsByProfile[BrowserProfile.defaultID] == 1)
        do {
            try pdf.saveOriginal(to: folder.appendingPathComponent("missing/failure.pdf"))
            Issue.record("Saving to a missing directory should fail")
        } catch { }
        #expect(try services.downloadRepository.list(profileID: BrowserProfile.defaultID).count == 1)
        #expect(services.downloads.startsByProfile[BrowserProfile.defaultID] == 1)
        page.load(InternalPage.newtab.url)
        #expect(page.pdfContent == nil)
        page.goBack()
        #expect(page.pdfContent === pdf)
        page.goForward()
        #expect(page.nativePage == .newtab)
        page.dispose()
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: saved) == data)
    }
    @Test(.timeLimit(.minutes(1))) func malformedPDFHasNativeError() async throws {
        let page = TabPage(); defer { page.dispose() }
        page.load(URL(string: "data:application/pdf;base64,SGVsbG8=")!)
        let pdf = try await waitForPDF(page)
        #expect(pdf.document == nil)
        #expect(pdf.error != nil)
        #expect(!pdf.loading)
    }
    @Test(.timeLimit(.minutes(1))) func multiPagePDFAndAbandonedForwardEntry() async throws {
        let page = TabPage(); defer { page.dispose() }
        page.load(InternalPage.newtab.url)
        page.load(URL(string: "data:application/pdf;base64," + (try Self.fixture(pages: 200)).base64EncodedString())!)
        let pdf = try await waitForPDF(page)
        #expect(pdf.document?.pageCount == 200)
        pdf.query = "unmatched old query"
        pdf.query = "Origami"
        for _ in 0..<300 {
            if pdf.matches.count == 200 && pdf.document?.isFinding == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pdf.matches.count == 200)
        #expect(pdf.view.currentSelection == nil)
        let highlights = try #require(pdf.view.highlightedSelections)
        #expect(!highlights.isEmpty)
        #expect(highlights.allSatisfy { $0.string == "Origami" })
        pdf.nextMatch(1); #expect(pdf.matchIndex == 1)
        pdf.query = ""; #expect(pdf.matches.isEmpty)
        #expect(pdf.view.highlightedSelections?.isEmpty != false)
        let file = try #require(pdf.fileURL)
        page.goBack()
        page.load(InternalPage.settings.url)
        #expect(!page.canGoForward)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test(.timeLimit(.minutes(1))) func privatePDFCleanupAndPrintRouting() async throws {
        let services = try BrowserServices(database: DatabaseManager(), privateProfile: BrowserProfile(id: BrowserProfile.defaultID, name: "Private", createdAt: Date(), websiteStoreID: nil))
        let store = BrowserStore(services: services)
        defer { store.pages.values.forEach { $0.dispose() } }
        store.newTab(url: URL(string: "data:application/pdf;base64," + (try Self.fixture()).base64EncodedString())!)
        let page = try #require(store.selectedPage)
        let pdf = try await waitForPDF(page)
        #expect(pdf.isPrivate)
        #expect(store.canPrintPage)
        #expect(!store.canUsePageFileCommands)
        #expect(try services.history.list(profileID: BrowserProfile.defaultID).isEmpty)
        #expect(try services.downloadRepository.list(profileID: BrowserProfile.defaultID).isEmpty)
        let file = try #require(pdf.fileURL)
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: saved) }
        try pdf.saveOriginal(to: saved)
        let privateRecord = try #require(services.downloadRepository.list(profileID: BrowserProfile.defaultID).first)
        #expect(privateRecord.state == .completed)
        #expect(privateRecord.url.isEmpty)
        #expect(try services.history.list(profileID: BrowserProfile.defaultID).isEmpty)
        store.duplicate(page.tabID)
        let duplicatePage = try #require(store.selectedPage)
        let duplicate = try await waitForPDF(duplicatePage)
        #expect(duplicatePage !== page)
        let duplicateFile = try #require(duplicate.fileURL)
        #expect(duplicateFile != file)
        #expect(try Data(contentsOf: duplicateFile) == Data(contentsOf: file))
        store.close(page.tabID)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: duplicateFile.path))
        store.close(duplicatePage.tabID)
        #expect(!FileManager.default.fileExists(atPath: duplicateFile.path))
    }
    @Test(.timeLimit(.minutes(1))) func encryptedPDFRequiresCorrectPassword() async throws {
        let original = try #require(PDFDocument(data: Self.fixture()))
        let encrypted = try #require(original.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "fixture-password", PDFDocumentWriteOption.ownerPasswordOption: "fixture-owner"]))
        let page = TabPage(); defer { page.dispose() }
        page.load(URL(string: "data:application/pdf;base64," + encrypted.base64EncodedString())!)
        let pdf = try await waitForPDF(page)
        #expect(pdf.locked)
        #expect(!pdf.unlock("wrong"))
        #expect(pdf.unlock("fixture-password"))
        #expect(!pdf.locked)
    }
    @Test func PDFNamesAreSafeAndRecognizable() {
        #expect(PDFTabContent.pdfFilename("../report") == "report.pdf")
        #expect(PDFTabContent.pdfFilename("download.php") == "download.php.pdf")
        #expect(PDFTabContent.pdfFilename("Annual Report.PDF") == "Annual Report.PDF")
        #expect(PDFTabContent.pdfFilename(String(repeating: "a", count: 500)).utf8.count < 255)
    }
    @Test func onlyWebLinksLeavePDF() {
        let view = BrowserPDFView()
        var opened: [URL] = []
        view.openLink = { opened.append($0) }
        view.perform(PDFActionURL(url: URL(string: "file:///etc/passwd")!))
        view.perform(PDFActionURL(url: URL(string: "javascript:alert(1)")!))
        view.perform(PDFActionURL(url: URL(string: "https://example.com")!))
        #expect(opened == [URL(string: "https://example.com")!])
    }
}
