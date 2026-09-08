import AppKit
import ImageIO
import Observation

@MainActor @Observable
final class FaviconService {
    private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var requests: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var attempted = Set<String>()
    static func origin(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme), let host = url.host else { return nil }
        return "\(url.scheme!)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
    private func key(_ url: URL, _ profile: UUID) -> String? { Self.origin(url).map { profile.uuidString + $0 } }
    func cached(_ url: URL, profile: UUID) -> NSImage? { key(url, profile).flatMap { icons[$0] } }
    func remember(_ image: NSImage, for url: URL, profile: UUID) {
        guard let key = key(url, profile) else { return }
        if icons.count >= 256 { icons.removeAll() }
        icons[key] = image
    }
    func load(_ url: URL, profile: UUID) async -> NSImage? {
        guard let key = key(url, profile), let origin = Self.origin(url), let iconURL = URL(string: origin + "/favicon.ico") else { return nil }
        if let cached = icons[key] { return cached }
        if let request = requests[key] { return await request.value }
        guard attempted.insert(key).inserted else { return nil }
        if attempted.count > 512 { attempted = [key] }
        let request = Task { await Self.fetch(iconURL) }
        requests[key] = request
        let image = await request.value
        requests[key] = nil
        if let image, icons[key] == nil { remember(image, for: url, profile: profile) }
        return icons[key]
    }
    static func fetch(_ url: URL, maximumPixelSize: Int = 48) async -> NSImage? {
        guard ["http", "https"].contains(url.scheme) else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 8))
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.expectedContentLength <= 1_048_576 else { return nil }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { return nil }
                data.append(byte)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize] as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: NSSize(width: 16, height: 16))
        } catch { return nil }
    }
}
