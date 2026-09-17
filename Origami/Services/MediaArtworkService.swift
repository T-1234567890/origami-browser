import AppKit
import ImageIO

/// Memory-only, scoped to BrowserServices (including its private-session lifetime).
@MainActor
final class MediaArtworkService {
    typealias Loader = @MainActor (URL) async -> NSImage?
    private let cache = NSCache<NSURL, NSImage>()
    private var requests: [URL: Task<NSImage?, Never>] = [:]
    private var failures: [URL: Date] = [:]
    private let loader: Loader

    init(loader: Loader? = nil) {
        self.loader = loader ?? Self.fetch
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1024 * 1024
    }
    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func prefetch(_ url: URL) {
        guard requests.count < 4, requests[url] == nil, cached(url) == nil else { return }
        Task { _ = await load(url) }
    }
    func load(_ url: URL) async -> NSImage? {
        guard ["https", "http"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        if let image = cached(url) { return image }
        if let request = requests[url] { return await request.value }
        if let failed = failures[url], Date().timeIntervalSince(failed) < 30 { return nil }
        // Bound concurrent decodes and downloads without treating a busy queue as failure.
        while requests.count >= 4 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        if Task.isCancelled { return nil }
        if let image = cached(url) { return image }
        if let request = requests[url] { return await request.value }
        let loader = loader
        let request = Task { await loader(url) }
        requests[url] = request
        // A cancelled popover waiter must not cancel a shared download.
        let image = await request.value
        requests[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height) * 4)
            failures[url] = nil
        } else {
            if failures.count >= 64 { failures.removeAll() }
            failures[url] = Date()
        }
        return image
    }
    private static func fetch(_ url: URL) async -> NSImage? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 8))
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let final = response.url, ["http", "https"].contains(final.scheme),
                  final.user == nil, final.password == nil, response.expectedContentLength <= 4_194_304 else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4_194_304 else { return nil }
                data.append(byte)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        } catch { return nil }
    }
}

enum MediaImagePresentation {
    enum Phase { case loading, artwork, fallback }
    static func phase(hasArtworkURL: Bool, hasImage: Bool, failed: Bool) -> Phase {
        hasArtworkURL ? (hasImage ? .artwork : (failed ? .fallback : .loading)) : .fallback
    }
    static func fitted(_ size: CGSize, in bounds: CGSize = CGSize(width: 112, height: 64)) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    static func faviconSize(_ image: NSImage, scale: CGFloat) -> CGSize {
        let vector = image.representations.contains { $0 is NSPDFImageRep || $0 is NSEPSImageRep }
        let pixels = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .max { $0.width < $1.width } ?? image.size
        let limit: CGFloat = vector ? 32 : min(28, max(12, max(pixels.width, pixels.height) / max(1, scale)))
        return fitted(pixels, in: CGSize(width: limit, height: limit))
    }
}
