import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Persist a bounded raster, not a lazily decoded original or a file reference.
enum TitleImageLoader {
    enum Failure: Error { case invalid, oversized }
    static let maximumBytes = 4_000_000
    static func read(_ url: URL) throws -> Data {
        do { return try SelectedImageFile.read(url, maximumBytes: maximumBytes) }
        catch SelectedImageFile.Failure.oversized { throw Failure.oversized }
    }
    @MainActor static func normalized(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.oversized }
        let image: CGImage
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetType(source) as String? == UTType.png.identifier {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue <= 65536, height.doubleValue <= 65536,
                  width.doubleValue * height.doubleValue <= 100_000_000 else { throw Failure.oversized }
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw Failure.invalid }
            image = thumbnail
        } else {
            // SVG is rendered once into a bounded bitmap before reaching SwiftUI.
            guard let text = String(data: data, encoding: .utf8), text.contains("<svg"),
                  !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
                  !text.localizedCaseInsensitiveContains("<!ENTITY"),
                  let vector = NSImage(data: data), vector.size.width.isFinite, vector.size.height.isFinite,
                  vector.size.width > 0, vector.size.height > 0,
                  vector.size.width <= 16384, vector.size.height <= 16384 else { throw Failure.invalid }
            let scale = min(1, 1024 / max(vector.size.width, vector.size.height))
            let size = CGSize(width: max(1, (vector.size.width * scale).rounded()), height: max(1, (vector.size.height * scale).rounded()))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure.invalid }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            vector.draw(in: CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let raster = bitmap.cgImage else { throw Failure.invalid }
            image = raster
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let result = bitmap.representation(using: .png, properties: [:]) else { throw Failure.invalid }
        return result
    }
}
