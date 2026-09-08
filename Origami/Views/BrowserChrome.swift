import SwiftUI
import AppKit

enum BrowserChromeMetrics {
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...320
    static let contentCornerRadius: CGFloat = 10
    static let contentFrameWidth: CGFloat = 8
    @MainActor static var tabHeight: CGFloat { Personalization.shared.tabHeight }
    static let tabSpacing: CGFloat = 2
    @MainActor static var stripHeight: CGFloat { max(36, Personalization.shared.tabHeight + 10) }
    static let pinnedWidth: CGFloat = 28
    // Six 30-point pins, five 4-point gaps and 10-point side insets fit 220 points.
    static let verticalPinnedWidth: CGFloat = 30
    static let pinnedHeight: CGFloat = 32
    static let horizontalPinnedHeight: CGFloat = 26
    static let minimumTabWidth: CGFloat = 80
    static let maximumTabWidth: CGFloat = 168
}

// One backdrop belongs to the window chrome; tab rows never create their own material layers.
struct BrowserChromeBackground: NSViewRepresentable {
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = Personalization.shared.glass == "Reduced" ? .windowBackground : .sidebar
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { nsView.blendingMode = blendingMode; nsView.material = Personalization.shared.glass == "Reduced" ? .windowBackground : .sidebar }
}

struct ChromeSurface: ViewModifier {
    func body(content: Content) -> some View {
        if Personalization.shared.glass == "Reduced" {
            content.background(.regularMaterial, in: Capsule())
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.thinMaterial, in: Capsule())
        }
    }
}

struct ChromeHairline: View {
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Color(nsColor: .separatorColor).opacity(0.45)
            .frame(height: 1 / displayScale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PageLoadingIndicator: View {
    let progress: Double
    var revealDelay: Duration = .seconds(2)
    var animationDuration: TimeInterval = 0.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    private var clampedProgress: Double { min(max(progress, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            if isVisible {
                Rectangle().fill(.tint)
                    .frame(width: geometry.size.width * clampedProgress)
                    .animation(reduceMotion ? nil : .linear(duration: animationDuration), value: clampedProgress)
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(!isVisible)
        .accessibilityLabel("Loading page")
        .accessibilityValue("\(Int(clampedProgress * 100)) percent")
        .task {
            // Removing the indicator when loading ends cancels the pending reveal.
            do { try await Task.sleep(for: revealDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            isVisible = true
        }
    }
}
