import SwiftUI
import AppKit

/// Owns a website dialog until it resolves, including cancellation on tab removal.
@MainActor
final class PageDialog: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var completion: ((String?) -> Void)?

    func show(relativeTo view: NSView, title: String, message: String, accept: String = "OK",
              allowsCancel: Bool = true, input: String? = nil, completion: @escaping (String?) -> Void) {
        cancel()
        guard view.window != nil else { completion(nil); return }
        self.completion = completion
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PageDialogContent(
            title: title, message: message, accept: accept, allowsCancel: allowsCancel,
            hasInput: input != nil, text: input ?? "", resolve: { [weak self] in self?.resolve($0) }))
        let anchor = NSRect(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY,
                            width: 1, height: 1)
        popover.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    func choices(relativeTo view: NSView, title: String, message: String, completion: @escaping (String?) -> Void) {
        cancel()
        guard view.window != nil else { completion(nil); return }
        self.completion = completion; popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            PopoverMessage(message: message)
            ForEach(["Open Once", "Always Open", "Stay in Browser", "Block"], id: \.self) { choice in
                Button(choice) { [weak self] in self?.resolve(choice) }
            }
        }.padding(20).frame(width: 300))
        popover.show(relativeTo: NSRect(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY, width: 1, height: 1), of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
    func cancel() { resolve(nil) }

    private func resolve(_ value: String?) {
        let callback = completion
        completion = nil
        popover.close()
        callback?(value)
    }

    func popoverDidClose(_ notification: Notification) {
        let callback = completion
        completion = nil
        callback?(nil)
    }
}

private struct PageDialogContent: View {
    let title: String
    let message: String
    let accept: String
    let allowsCancel: Bool
    let hasInput: Bool
    @State var text: String
    let resolve: (String?) -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).lineLimit(2)
            PopoverMessage(message: message)
            if hasInput {
                TextField("Response", text: $text).focused($inputFocused)
                    .onSubmit { resolve(text) }
            }
            HStack {
                Spacer()
                if allowsCancel {
                    Button("Cancel") { resolve(nil) }.keyboardShortcut(.cancelAction)
                }
                Button(accept) { resolve(text) }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 300)
            .onAppear { inputFocused = hasInput }
    }
}

private struct PopoverMessage: View {
    let message: String
    private var height: CGFloat {
        let bounds = (message as NSString).boundingRect(with: NSSize(width: 264, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(180, max(20, ceil(bounds.height) + 4))
    }
    var body: some View {
        ScrollView { Text(message).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true) }
            .frame(height: height)
    }
}
