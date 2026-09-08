import SwiftUI

extension TabGroupColor {
    var title: String { self == .accent ? "Default" : rawValue.capitalized }
    var tint: Color {
        switch self {
        case .accent: .accentColor
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        }
    }
}
extension TabGroup {
    var tint: Color { (color ?? .purple).permitted.tint }
}

extension TabGroupColor {
    // AppKit menus ignore SwiftUI foregroundStyle on template symbols.
    @MainActor var menuSwatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(tint).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
