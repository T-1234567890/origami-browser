import SwiftUI
import MarkdownUI

struct AskMarkdown: View {
    let text: String
    let store: BrowserStore
    var body: some View {
        Markdown(text)
            .markdownTheme(.basic)
            .markdownTextStyle { FontFamily(.system(.serif)); FontSize(17); ForegroundColor(.primary) }
            .markdownTextStyle(\.link) { ForegroundColor(Personalization.shared.accent) }
            .markdownImageProvider(AnswerImageProvider(store: store))
            .markdownInlineImageProvider(AnswerInlineImageProvider())
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard let safe = AISource.safeURL(url.absoluteString) else { return .discarded }
                store.newTab(url: safe); return .handled
            })
    }
}
// Images are explicit navigations, never automatic requests from untrusted answer text.
private struct AnswerImageProvider: ImageProvider {
    let store: BrowserStore
    func makeImage(url: URL?) -> some View {
        if let url, let safe = AISource.safeURL(url.absoluteString) {
            Button { store.newTab(url: safe) } label: { Label("Open image", systemImage: "photo") }.buttonStyle(.plain)
        }
    }
}
private struct AnswerInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}
struct BreathingCircle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    var body: some View {
        Circle().fill(Personalization.shared.accent).frame(width: 10, height: 10)
            .scaleEffect(expanded ? 1 : 0.65).opacity(expanded ? 0.9 : 0.35)
            .onAppear { if reduceMotion { expanded = true } else { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { expanded = true } } }
            .accessibilityLabel("Generating response")
    }
}
