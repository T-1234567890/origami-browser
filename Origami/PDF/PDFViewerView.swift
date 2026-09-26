import SwiftUI
import PDFKit

struct PDFViewerView: View {
    @Environment(\.profileAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var content: PDFTabContent
    let retry: () -> Void
    @State private var viewOptionsPresented = false
    @State private var documentActionsPresented = false
    @State private var password = ""
    @State private var passwordFailed = false
    var body: some View {
        VStack(spacing: 0) {
            if content.loading {
                ProgressView("Loading PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if content.document == nil {
                ContentUnavailableView {
                    Label("Unable to Open PDF", systemImage: "doc.badge.ellipsis")
                } description: { Text(content.error ?? "") } actions: { Button("Try Again", action: retry) }
            } else if content.locked {
                VStack(spacing: 12) {
                    Image(systemName: "lock.doc").font(.largeTitle)
                    Text("This PDF is password protected.")
                    SecureField("Password", text: $password).frame(width: 240).onSubmit(unlock)
                    if passwordFailed { Text("The password is incorrect.").foregroundStyle(.secondary) }
                    Button("Unlock PDF", action: unlock)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    if content.sidebarVisible {
                        PDFThumbnails(content: content)
                            .frame(width: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .background { sidebarBackground }
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
                            .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                            .padding(8)
                            .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                    }
                    PDFCanvas(content: content)
                        .overlay(alignment: .bottom) { floatingTools }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: content.sidebarVisible)
                if let error = content.error { Text(error).font(.caption).padding(8) }
            }
        }.onDisappear { password = "" }
    }
    private var floatingTools: some View {
        VStack(spacing: 8) {
            if content.searchVisible {
                HStack(spacing: 8) {
                    FindQueryField(title: "Find in PDF", text: $content.query,
                                   submit: { content.nextMatch(1) }, close: { content.searchVisible = false })
                    Text("\(content.matches.isEmpty ? 0 : content.matchIndex + 1) / \(content.matches.count)")
                        .font(.caption).monospacedDigit().fixedSize()
                    tool("Previous match", "chevron.up") { content.nextMatch(-1) }.disabled(content.matches.isEmpty)
                    tool("Next match", "chevron.down") { content.nextMatch(1) }.disabled(content.matches.isEmpty)
                    tool("Close Find", "xmark") { content.searchVisible = false }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: 340)
                .background { toolBackground }
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            toolbar.frame(maxWidth: 300)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: content.searchVisible)
        .foregroundStyle(.primary).tint(.primary)
        .font(.system(size: 13))
        .padding(12)
    }
    private var toolbar: some View {
        HStack(spacing: 6) {
            tool("Thumbnails", "sidebar.left") { content.sidebarVisible.toggle() }
                .background(content.sidebarVisible ? Color.primary.opacity(0.1) : .clear, in: Circle())
                .accessibilityAddTraits(content.sidebarVisible ? .isSelected : [])
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    tool("Previous Page", "chevron.left") { content.view.goToPreviousPage(nil) }.disabled(content.pageNumber <= 1)
                    pageCount
                    tool("Next Page", "chevron.right") { content.view.goToNextPage(nil) }.disabled(content.pageNumber >= (content.document?.pageCount ?? 0))
                }.fixedSize()
                pageCount
            }.fixedSize(horizontal: false, vertical: true)
            Divider().frame(height: 16).padding(.horizontal, 2)
            tool("PDF View Options", "slider.horizontal.3") { viewOptionsPresented.toggle() }
                .popover(isPresented: $viewOptionsPresented, arrowEdge: .top) { viewOptions }
            tool("Find", "magnifyingglass") { content.searchVisible.toggle() }
                .background(content.searchVisible ? Color.primary.opacity(0.1) : .clear, in: Circle())
            tool("PDF Document Actions", "doc") { documentActionsPresented.toggle() }
                .popover(isPresented: $documentActionsPresented, arrowEdge: .top) { documentActions }
        }
        .foregroundStyle(.primary).tint(.primary)
        .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
        .background { toolBackground }
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .accessibilityElement(children: .contain).accessibilityLabel("PDF tools")
    }
    private var pageCount: some View {
        Text("\(content.pageNumber) / \(content.document?.pageCount ?? 0)")
            .monospacedDigit().font(.caption).fixedSize().padding(.horizontal, 2)
    }
    private var viewOptions: some View {
        VStack(spacing: 10) {
            HStack {
                tool("Previous Page", "chevron.left") { content.view.goToPreviousPage(nil) }.disabled(content.pageNumber <= 1)
                Spacer(); pageCount; Spacer()
                tool("Next Page", "chevron.right") { content.view.goToNextPage(nil) }.disabled(content.pageNumber >= (content.document?.pageCount ?? 0))
            }
            Divider()
            HStack {
                popoverAction("Zoom Out", "minus.magnifyingglass") { content.zoom(false) }
                popoverAction("Zoom In", "plus.magnifyingglass") { content.zoom(true) }
            }
            HStack {
                popoverAction("Fit Width", "arrow.left.and.right") { content.fitWidth() }
                popoverAction("Fit Page", "arrow.up.left.and.arrow.down.right") { content.fitPage() }
            }
            Divider()
            HStack {
                popoverAction("Rotate Left", "rotate.left") { content.rotate(-90) }
                popoverAction("Rotate Right", "rotate.right") { content.rotate(90) }
            }
            Divider()
            popoverAction("Reset View", "arrow.counterclockwise") { content.resetView() }
        }
        .padding(14).frame(width: 260).foregroundStyle(.primary).tint(.primary)
    }
    private var documentActions: some View {
        VStack(spacing: 10) {
            popoverAction("Save PDF…", "square.and.arrow.down") { performDocumentAction { content.save() } }
            popoverAction("Print…", "printer") { performDocumentAction { content.printDocument() } }
                .disabled(content.document?.allowsPrinting != true)
            popoverAction("Share", "square.and.arrow.up") { performDocumentAction { content.share() } }
            Divider()
            popoverAction("Open in Preview", "arrow.up.forward.app") { performDocumentAction { content.openInPreview() } }
        }
        .padding(14).frame(width: 220).foregroundStyle(.primary).tint(.primary)
    }
    private func performDocumentAction(_ action: @escaping () -> Void) {
        documentActionsPresented = false
        // Let the popover close before presenting another native panel or picker.
        DispatchQueue.main.async(execute: action)
    }
    private func popoverAction(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.string(title), systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private var toolBackground: some View {
        if reduceTransparency { Capsule().fill(Color(nsColor: .windowBackgroundColor)) }
        else if #available(macOS 26, *), appearance.glass != "Reduced" {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else { Capsule().fill(.regularMaterial) }
    }
    @ViewBuilder private var sidebarBackground: some View {
        if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .windowBackgroundColor)) }
        else if #available(macOS 26, *), appearance.glass != "Reduced" {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) }
    }
    private func unlock() { passwordFailed = !content.unlock(password); password = "" }
    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 26).contentShape(Circle()) }
            .buttonStyle(.plain).help(L10n.string(title)).accessibilityLabel(L10n.string(title))
    }
}
private struct PDFCanvas: NSViewRepresentable {
    let content: PDFTabContent
    func makeNSView(context: Context) -> PDFView { content.view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
private struct PDFThumbnails: NSViewRepresentable {
    let content: PDFTabContent
    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView(); view.pdfView = content.view
        view.backgroundColor = .clear
        view.maximumNumberOfColumns = 1
        view.thumbnailSize = NSSize(width: 90, height: 120)
        return view
    }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) { nsView.pdfView = content.view }
}
