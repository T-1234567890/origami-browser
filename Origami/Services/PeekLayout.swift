import Foundation
import CoreGraphics

/// Keep the source viewport's proportions and never clamp a preview across its anchor.
enum PeekLayout {
    static func size(viewport: CGSize) -> CGSize {
        let width = max(1, viewport.width), height = max(1, viewport.height)
        let scale = min(280 / width, 200 / height)
        return CGSize(width: width * scale, height: height * scale)
    }
    static func frame(viewport: CGSize, link: CGRect, container: CGSize) -> CGRect? {
        let size = size(viewport: viewport)
        let bounds = CGRect(origin: .zero, size: container).insetBy(dx: 12, dy: 12)
        guard bounds.width >= size.width, bounds.height >= size.height else { return nil }
        let x = max(bounds.minX, min(link.minX, bounds.maxX - size.width))
        let y = max(bounds.minY, min(link.minY, bounds.maxY - size.height))
        let candidates = [CGRect(x: x, y: link.maxY + 18, width: size.width, height: size.height),
                          CGRect(x: x, y: link.minY - size.height - 18, width: size.width, height: size.height),
                          CGRect(x: link.maxX + 18, y: y, width: size.width, height: size.height),
                          CGRect(x: link.minX - size.width - 18, y: y, width: size.width, height: size.height)]
        return candidates.first { bounds.contains($0) && !$0.intersects(link.insetBy(dx: -12, dy: -12)) }
    }
}
